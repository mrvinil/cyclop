import AppKit
import Combine
import Foundation

enum DownloadManagerError: Error, Equatable {
    case persistenceFailed
}

struct OwnDownloadCompletion: Equatable {
    let fileURL: URL
    let occurredAt: Date
}

struct DownloadFileOperations {
    let createDirectory: (URL) throws -> Void
    let fileExists: (String) -> Bool
    let moveItem: (URL, URL) throws -> Void

    static func live(fileManager: FileManager = .default) -> Self {
        Self(
            createDirectory: { url in
                try fileManager.createDirectory(
                    at: url,
                    withIntermediateDirectories: true
                )
            },
            fileExists: fileManager.fileExists(atPath:),
            moveItem: fileManager.moveItem(at:to:)
        )
    }
}

@MainActor
final class DownloadManager: ObservableObject {
    @Published private(set) var downloads: [CyclopDownload] = []
    @Published private(set) var health: ActivitySourceHealth = .available

    var ownCompletionPublisher: AnyPublisher<OwnDownloadCompletion, Never> {
        ownCompletionSubject.eraseToAnyPublisher()
    }

    private struct PendingFinalization {
        let record: CyclopDownload
        let completion: OwnDownloadCompletion
    }

    private static let progressPersistenceInterval: TimeInterval = 2
    private static let loadFailureMessage = "Не удалось загрузить список загрузок"
    private static let saveFailureMessage = "Не удалось сохранить список загрузок"
    private static let destinationFailureMessage =
        "Не удалось сохранить файл в папку загрузок"

    private let clock: ActivityClock
    private let persistence: DownloadPersisting
    private let transport: DownloadTransport
    private let settings: ActivitySettings
    private let concurrencyLimit: Int
    private let fileOperations: DownloadFileOperations
    private let openHandler: (URL) -> Void
    private let revealHandler: (URL) -> Void
    private let ownCompletionSubject = PassthroughSubject<OwnDownloadCompletion, Never>()

    private var isStarted = false
    private var writesAllowed = false
    private var isDraining = false
    private var drainRequested = false
    private var pendingPauseIDs: Set<UUID> = []
    private var pendingFinalizations: [UUID: PendingFinalization] = [:]
    private var lastGlobalProgressSaveAt: Date?
    private var lastProgressSaveAtByID: [UUID: Date] = [:]

    init(
        clock: ActivityClock,
        persistence: DownloadPersisting,
        transport: DownloadTransport,
        settings: ActivitySettings,
        maxConcurrent: Int = 3,
        fileOperations: DownloadFileOperations = .live(),
        openHandler: @escaping (URL) -> Void = { NSWorkspace.shared.open($0) },
        revealHandler: @escaping (URL) -> Void = {
            NSWorkspace.shared.activateFileViewerSelecting([$0])
        }
    ) {
        self.clock = clock
        self.persistence = persistence
        self.transport = transport
        self.settings = settings
        concurrencyLimit = min(max(0, maxConcurrent), 3)
        self.fileOperations = fileOperations
        self.openHandler = openHandler
        self.revealHandler = revealHandler
    }

    func start() throws {
        guard !isStarted else { return }

        transport.eventHandler = nil
        writesAllowed = false
        pendingPauseIDs.removeAll()
        pendingFinalizations.removeAll()
        lastGlobalProgressSaveAt = nil
        lastProgressSaveAtByID.removeAll()

        let loaded: [CyclopDownload]
        do {
            loaded = try persistence.load()
        } catch {
            health = .unavailable(message: Self.loadFailureMessage)
            throw DownloadManagerError.persistenceFailed
        }

        let recovered = loaded.filter { $0.phase != .cancelled }
        if recovered != loaded {
            do {
                try persistence.save(recovered)
            } catch {
                downloads = loaded
                health = .unavailable(message: Self.saveFailureMessage)
                throw DownloadManagerError.persistenceFailed
            }
        }

        downloads = recovered
        writesAllowed = true
        isStarted = true
        health = .available
        transport.eventHandler = { [weak self] event in
            self?.handle(event)
        }

        transport.restore(records: recovered.filter { $0.phase == .downloading })
        drainQueue()
        guard health == .available else {
            throw DownloadManagerError.persistenceFailed
        }
    }

    func stop() {
        guard isStarted else {
            transport.eventHandler = nil
            writesAllowed = false
            return
        }

        transport.eventHandler = nil
        isStarted = false
        let finalizations = pendingFinalizations.sorted {
            $0.key.uuidString < $1.key.uuidString
        }
        if finalizations.isEmpty {
            _ = persistCurrentState()
        } else {
            for (id, pending) in finalizations {
                guard finalize(id: id, pending: pending) else { break }
            }
        }
        writesAllowed = false
        pendingPauseIDs.removeAll()
        isDraining = false
        drainRequested = false
    }

    @discardableResult
    func enqueue(_ rawURL: String) throws -> UUID {
        let url = try DownloadRequestParser.parse(rawURL)
        guard isStarted, writesAllowed else {
            throw DownloadManagerError.persistenceFailed
        }

        let now = clock.now
        let id = UUID()
        let displayName = url.lastPathComponent.isEmpty ? "Загрузка" : url.lastPathComponent
        let record = CyclopDownload(
            id: id,
            remoteURL: url,
            phase: .queued,
            displayName: displayName,
            destinationURL: nil,
            taskIdentifier: nil,
            resumeData: nil,
            bytesReceived: 0,
            totalBytes: nil,
            createdAt: now,
            completedAt: nil,
            failure: nil
        )

        var updated = downloads
        updated.append(record)
        try persistAndPublish(updated)
        drainQueue()
        return id
    }

    func pause(_ id: UUID) {
        guard isStarted,
              let record = download(id),
              record.phase == .downloading,
              pendingFinalizations[id] == nil,
              !pendingPauseIDs.contains(id),
              persistCurrentState() else {
            return
        }

        pendingPauseIDs.insert(id)
        transport.pause(id: id)
    }

    func resume(_ id: UUID) {
        guard let index = downloads.firstIndex(where: { $0.id == id }),
              downloads[index].phase == .paused else {
            return
        }

        var updated = downloads
        updated[index].phase = .queued
        updated[index].taskIdentifier = nil
        updated[index].failure = nil
        updated[index].completedAt = nil
        guard persistAndPublishWithoutThrow(updated) else { return }
        drainQueue()
    }

    func cancel(_ id: UUID) {
        guard let index = downloads.firstIndex(where: { $0.id == id }),
              [.queued, .downloading, .paused, .failed].contains(downloads[index].phase),
              pendingFinalizations[id] == nil else {
            return
        }

        var updated = downloads
        updated[index].phase = .cancelled
        guard persistAndPublishWithoutThrow(updated) else { return }
        pendingPauseIDs.remove(id)
        transport.cancel(id: id)
    }

    func retry(_ id: UUID) {
        guard let index = downloads.firstIndex(where: { $0.id == id }),
              downloads[index].phase == .failed else {
            return
        }

        var updated = downloads
        updated[index].phase = .queued
        updated[index].destinationURL = nil
        updated[index].taskIdentifier = nil
        updated[index].resumeData = usableResumeData(updated[index].resumeData)
        updated[index].bytesReceived = 0
        updated[index].totalBytes = nil
        updated[index].completedAt = nil
        updated[index].failure = nil
        guard persistAndPublishWithoutThrow(updated) else { return }
        drainQueue()
    }

    func dismiss(_ id: UUID) {
        guard let index = downloads.firstIndex(where: { $0.id == id }),
              downloads[index].phase == .completed else {
            return
        }

        var updated = downloads
        updated.remove(at: index)
        _ = persistAndPublishWithoutThrow(updated)
    }

    func open(_ id: UUID) {
        guard isStarted,
              let record = download(id),
              record.phase == .completed,
              let destinationURL = record.destinationURL else {
            return
        }
        openHandler(destinationURL)
    }

    func reveal(_ id: UUID) {
        guard isStarted,
              let record = download(id),
              record.phase == .completed,
              let destinationURL = record.destinationURL else {
            return
        }
        revealHandler(destinationURL)
    }

    private func download(_ id: UUID) -> CyclopDownload? {
        downloads.first { $0.id == id }
    }

    private func handle(_ event: DownloadTransportEvent) {
        guard isStarted else { return }

        switch event {
        case let .started(id, taskIdentifier):
            handleStarted(id: id, taskIdentifier: taskIdentifier)
        case let .progress(id, received, expected):
            handleProgress(id: id, received: received, expected: expected)
        case let .paused(id, resumeData):
            handlePaused(id: id, resumeData: resumeData)
        case let .cancelled(id):
            handleCancelled(id: id)
        case let .finished(id, temporaryURL, suggestedFilename):
            handleFinished(
                id: id,
                temporaryURL: temporaryURL,
                suggestedFilename: suggestedFilename
            )
        case let .failed(id, code, message, resumeData):
            handleFailed(id: id, code: code, message: message, resumeData: resumeData)
        }
    }

    private func handleStarted(id: UUID, taskIdentifier: Int) {
        guard let index = downloads.firstIndex(where: { $0.id == id }),
              downloads[index].phase == .downloading,
              pendingFinalizations[id] == nil,
              downloads[index].taskIdentifier == nil else {
            return
        }

        var updated = downloads
        updated[index].taskIdentifier = taskIdentifier
        updated[index].resumeData = nil
        _ = persistAndPublishWithoutThrow(updated)
    }

    private func handleProgress(id: UUID, received: Int64, expected: Int64?) {
        guard let index = downloads.firstIndex(where: { $0.id == id }),
              downloads[index].phase == .downloading,
              pendingFinalizations[id] == nil else {
            return
        }

        var updated = downloads
        updated[index].bytesReceived = max(0, received)
        updated[index].totalBytes = expected.flatMap { $0 > 0 ? $0 : nil }
        downloads = updated

        let now = clock.now
        guard shouldPersistProgress(id: id, now: now) else { return }

        do {
            try persistence.save(updated)
            lastGlobalProgressSaveAt = now
            lastProgressSaveAtByID[id] = now
            health = .available
        } catch {
            health = .unavailable(message: Self.saveFailureMessage)
        }
    }

    private func handlePaused(id: UUID, resumeData: Data?) {
        guard pendingPauseIDs.contains(id),
              let index = downloads.firstIndex(where: { $0.id == id }),
              downloads[index].phase == .downloading else {
            return
        }

        var updated = downloads
        updated[index].phase = .paused
        updated[index].taskIdentifier = nil
        updated[index].resumeData = usableResumeData(resumeData)
        guard persistAndPublishWithoutThrow(updated) else { return }
        pendingPauseIDs.remove(id)
        drainQueue()
    }

    private func handleCancelled(id: UUID) {
        guard let index = downloads.firstIndex(where: { $0.id == id }),
              downloads[index].phase == .cancelled else {
            return
        }

        var updated = downloads
        updated.remove(at: index)
        guard persistAndPublishWithoutThrow(updated) else { return }
        pendingPauseIDs.remove(id)
        pendingFinalizations.removeValue(forKey: id)
        drainQueue()
    }

    private func handleFailed(
        id: UUID,
        code: String,
        message: String,
        resumeData: Data?
    ) {
        guard pendingFinalizations[id] == nil,
              let index = downloads.firstIndex(where: { $0.id == id }),
              downloads[index].phase == .downloading else {
            return
        }

        var updated = downloads
        updated[index].phase = .failed
        updated[index].taskIdentifier = nil
        updated[index].resumeData = usableResumeData(resumeData)
        updated[index].completedAt = nil
        updated[index].failure = DownloadFailure(
            code: code,
            message: message.isEmpty ? "Не удалось скачать файл" : message
        )
        guard persistAndPublishWithoutThrow(updated) else { return }
        pendingPauseIDs.remove(id)
        drainQueue()
    }

    private func handleFinished(
        id: UUID,
        temporaryURL: URL,
        suggestedFilename: String?
    ) {
        if let pending = pendingFinalizations[id] {
            _ = finalize(id: id, pending: pending)
            return
        }

        guard let index = downloads.firstIndex(where: { $0.id == id }),
              downloads[index].phase == .downloading else {
            return
        }

        let record = downloads[index]
        let destinationFolder = settings.downloadsFolder
        let destinationURL: URL
        do {
            try fileOperations.createDirectory(destinationFolder)
            destinationURL = DownloadNaming.destination(
                folder: destinationFolder,
                responseFilename: suggestedFilename,
                remoteURL: record.remoteURL,
                fileExists: fileOperations.fileExists
            )
            try fileOperations.moveItem(temporaryURL, destinationURL)
        } catch {
            var updated = downloads
            updated[index].phase = .failed
            updated[index].taskIdentifier = nil
            updated[index].completedAt = nil
            updated[index].failure = DownloadFailure(
                code: "destination-write",
                message: Self.destinationFailureMessage
            )
            if persistAndPublishWithoutThrow(updated) {
                pendingPauseIDs.remove(id)
                drainQueue()
            }
            return
        }

        let completedAt = clock.now
        var completed = record
        completed.phase = .completed
        completed.displayName = destinationURL.lastPathComponent
        completed.destinationURL = destinationURL
        completed.taskIdentifier = nil
        completed.resumeData = nil
        completed.completedAt = completedAt
        completed.failure = nil
        let pending = PendingFinalization(
            record: completed,
            completion: OwnDownloadCompletion(
                fileURL: destinationURL,
                occurredAt: completedAt
            )
        )
        pendingFinalizations[id] = pending
        _ = finalize(id: id, pending: pending)
    }

    @discardableResult
    private func finalize(id: UUID, pending: PendingFinalization) -> Bool {
        guard let index = downloads.firstIndex(where: { $0.id == id }),
              downloads[index].phase == .downloading else {
            return false
        }

        var updated = downloads
        updated[index] = pending.record
        guard persistAndPublishWithoutThrow(updated) else { return false }
        pendingFinalizations.removeValue(forKey: id)
        pendingPauseIDs.remove(id)
        ownCompletionSubject.send(pending.completion)
        drainQueue()
        return true
    }

    private func drainQueue() {
        guard isStarted, writesAllowed, concurrencyLimit > 0 else { return }
        if isDraining {
            drainRequested = true
            return
        }

        isDraining = true
        repeat {
            drainRequested = false
            let activeCount = downloads.reduce(into: 0) { count, record in
                if record.phase == .downloading {
                    count += 1
                }
            }
            let availableSlots = max(0, concurrencyLimit - activeCount)
            guard availableSlots > 0 else { break }

            let candidates = downloads.enumerated()
                .filter { $0.element.phase == .queued }
                .sorted { lhs, rhs in
                    if lhs.element.createdAt != rhs.element.createdAt {
                        return lhs.element.createdAt < rhs.element.createdAt
                    }
                    if lhs.offset != rhs.offset {
                        return lhs.offset < rhs.offset
                    }
                    return lhs.element.id.uuidString < rhs.element.id.uuidString
                }
                .prefix(availableSlots)
            guard !candidates.isEmpty else { break }

            var updated = downloads
            let startRecords: [CyclopDownload] = candidates.map { candidate in
                updated[candidate.offset].phase = .downloading
                updated[candidate.offset].taskIdentifier = nil
                updated[candidate.offset].failure = nil
                updated[candidate.offset].completedAt = nil
                return updated[candidate.offset]
            }
            guard persistAndPublishWithoutThrow(updated) else { break }

            for record in startRecords {
                transport.start(
                    id: record.id,
                    url: record.remoteURL,
                    resumeData: usableResumeData(record.resumeData)
                )
            }
        } while drainRequested
        isDraining = false
    }

    private func shouldPersistProgress(id: UUID, now: Date) -> Bool {
        if let lastGlobalProgressSaveAt,
           now.timeIntervalSince(lastGlobalProgressSaveAt) < Self.progressPersistenceInterval {
            return false
        }
        if let lastRecordSave = lastProgressSaveAtByID[id],
           now.timeIntervalSince(lastRecordSave) < Self.progressPersistenceInterval {
            return false
        }
        return true
    }

    private func persistCurrentState() -> Bool {
        guard writesAllowed else {
            return false
        }
        do {
            try persistence.save(downloads)
            health = .available
            return true
        } catch {
            health = .unavailable(message: Self.saveFailureMessage)
            return false
        }
    }

    private func persistAndPublish(_ updated: [CyclopDownload]) throws {
        guard writesAllowed else {
            throw DownloadManagerError.persistenceFailed
        }
        do {
            try persistence.save(updated)
        } catch {
            health = .unavailable(message: Self.saveFailureMessage)
            throw DownloadManagerError.persistenceFailed
        }

        downloads = updated
        health = .available
    }

    private func persistAndPublishWithoutThrow(_ updated: [CyclopDownload]) -> Bool {
        do {
            try persistAndPublish(updated)
            return true
        } catch {
            return false
        }
    }

    private func usableResumeData(_ data: Data?) -> Data? {
        guard let data, !data.isEmpty else { return nil }
        return data
    }
}
