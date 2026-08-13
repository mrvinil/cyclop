import Combine
import Foundation

enum DownloadManagerError: Error, Equatable {
    case persistenceFailed
}

struct OwnDownloadCompletion: Equatable {
    let fileURL: URL
    let occurredAt: Date
}

struct OwnDownloadFileMove: Equatable {
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

    var ownFileMovePublisher: AnyPublisher<OwnDownloadFileMove, Never> {
        ownFileMoveSubject.eraseToAnyPublisher()
    }

    var downloadsStatePublisher: AnyPublisher<[CyclopDownload], Never> {
        downloadsStateSubject.publisher
    }

    private struct PendingFinalization {
        let expectedPhase: DownloadPhase
        let record: CyclopDownload
        let completion: OwnDownloadCompletion
    }

    private struct PendingTerminalTransition {
        let expectedPhase: DownloadPhase
        let record: CyclopDownload?
    }

    private struct PendingProgress {
        let bytesReceived: Int64
        let totalBytes: Int64?
    }

    private struct PendingNonterminalUpdate {
        var taskIdentifier: Int?
        var clearsResumeData = false
        var progress: PendingProgress?
    }

    private enum StartStage {
        case stopped
        case metadataBeforeRestore
        case restore
        case waitingForRestore
        case metadataBeforeDrain
        case drain
        case complete
    }

    private static let progressPersistenceInterval: TimeInterval = 2
    private static let metadataPersistenceRetryInterval: TimeInterval = 2
    private static let loadFailureMessage = "Не удалось загрузить список загрузок"
    private static let saveFailureMessage = "Не удалось сохранить список загрузок"
    private static let destinationFailureMessage =
        "Не удалось сохранить файл в папку загрузок"
    private static let stagingFailureMessage =
        "Не удалось сохранить временный файл загрузки"
    private static let finalizationRecoveryFailureMessage =
        "Не удалось восстановить сохранение загрузки"

    private let clock: ActivityClock
    private let scheduler: ActivityScheduling
    private let persistence: DownloadPersisting
    private let transport: DownloadTransport
    private let settings: ActivitySettings
    private let concurrencyLimit: Int
    private let fileOperations: DownloadFileOperations
    private let finalizationStore: DownloadFinalizationStoring
    private let fileActions: DownloadFileActions
    private let ownCompletionSubject = PassthroughSubject<OwnDownloadCompletion, Never>()
    private let ownFileMoveSubject = PassthroughSubject<OwnDownloadFileMove, Never>()
    private let downloadsStateSubject = NonReentrantCurrentValueSubject<[CyclopDownload]>([])

    private var isStarted = false
    private var startStage = StartStage.stopped
    private var writesAllowed = false
    private var isDraining = false
    private var drainRequested = false
    private var pendingPauseIDs: Set<UUID> = []
    private var pendingFinalizations: [UUID: PendingFinalization] = [:]
    private var pendingTerminalTransitions: [UUID: PendingTerminalTransition] = [:]
    private var pendingNonterminalUpdates: [UUID: PendingNonterminalUpdate] = [:]
    private var pendingAbandonmentIDs: Set<UUID> = []
    private var scheduledMetadataRetry: ActivityCancellation?
    private var metadataRetryGeneration: UInt = 0
    private var lastGlobalProgressSaveAt: Date?
    private var lastProgressSaveAtByID: [UUID: Date] = [:]
    private var lifecycleGeneration: UInt = 0

    init(
        clock: ActivityClock,
        scheduler: ActivityScheduling,
        persistence: DownloadPersisting,
        transport: DownloadTransport,
        settings: ActivitySettings,
        maxConcurrent: Int = 3,
        fileOperations: DownloadFileOperations = .live(),
        finalizationStore: DownloadFinalizationStoring = DownloadFinalizationStore.live(),
        fileActions: DownloadFileActions = .live()
    ) {
        self.clock = clock
        self.scheduler = scheduler
        self.persistence = persistence
        self.transport = transport
        self.settings = settings
        concurrencyLimit = min(max(0, maxConcurrent), 3)
        self.fileOperations = fileOperations
        self.finalizationStore = finalizationStore
        self.fileActions = fileActions
    }

    func start() throws {
        if isStarted {
            guard startStage != .complete else { return }
            try continueStart()
            return
        }

        lifecycleGeneration &+= 1
        cancelScheduledMetadataRetry()
        writesAllowed = false
        pendingPauseIDs.removeAll()
        lastGlobalProgressSaveAt = nil
        lastProgressSaveAtByID.removeAll()

        let loaded: [CyclopDownload]
        do {
            loaded = try persistence.load()
        } catch {
            health = .unavailable(message: Self.loadFailureMessage)
            throw DownloadManagerError.persistenceFailed
        }

        do {
            try DownloadRecordValidator.validate(loaded)
        } catch {
            health = .unavailable(message: Self.loadFailureMessage)
            throw DownloadManagerError.persistenceFailed
        }

        let abandonedIDs: Set<UUID>
        do {
            abandonedIDs = try finalizationStore.abandonedDownloadIDs()
        } catch {
            health = .unavailable(message: Self.finalizationRecoveryFailureMessage)
            throw DownloadManagerError.persistenceFailed
        }

        let recovered = loaded.filter {
            $0.phase != .cancelled && !abandonedIDs.contains($0.id)
        }
        if recovered != loaded {
            do {
                try persistence.save(recovered)
            } catch {
                setDownloads(loaded)
                health = .unavailable(message: Self.saveFailureMessage)
                throw DownloadManagerError.persistenceFailed
            }
        }

        do {
            for id in abandonedIDs.sorted(by: { $0.uuidString < $1.uuidString }) {
                try finalizationStore.abandon(downloadID: id)
                pendingAbandonmentIDs.remove(id)
            }
        } catch {
            setDownloads(recovered)
            health = .unavailable(message: Self.finalizationRecoveryFailureMessage)
            throw DownloadManagerError.persistenceFailed
        }

        let durableRecoveries: [DownloadFinalizationRecovery]
        do {
            durableRecoveries = try finalizationStore.recoveries()
        } catch {
            setDownloads(recovered)
            health = .unavailable(message: Self.finalizationRecoveryFailureMessage)
            throw DownloadManagerError.persistenceFailed
        }

        setDownloads(recovered)
        downloadsStateSubject.send(recovered)
        writesAllowed = true
        isStarted = true
        startStage = .metadataBeforeRestore
        health = .available
        do {
            try reconcileDurableFinalizations(durableRecoveries)
        } catch {
            isStarted = false
            writesAllowed = false
            startStage = .stopped
            health = .unavailable(message: Self.finalizationRecoveryFailureMessage)
            throw DownloadManagerError.persistenceFailed
        }
        transport.eventHandler = { [weak self] event in
            self?.handle(event)
        }

        try continueStart()
    }

    func stop() {
        guard isStarted else {
            return
        }

        lifecycleGeneration &+= 1
        isStarted = false
        startStage = .stopped
        cancelScheduledMetadataRetry()
        let hadPendingMetadata = hasPendingMetadata
        if persistPendingMetadata(), !hadPendingMetadata {
            _ = persistCurrentState()
        }
        scheduleMetadataRetryIfNeeded()
        // Активные URLSession-задачи продолжают жить: handler остаётся terminal event sink.
        // Публичные действия и drain при этом заблокированы через isStarted/startStage.
        isDraining = false
        drainRequested = false
    }

    private func continueStart() throws {
        while isStarted {
            switch startStage {
            case .stopped, .waitingForRestore, .complete:
                return
            case .metadataBeforeRestore:
                guard persistPendingMetadata(drainAfterSuccess: false) else {
                    throw DownloadManagerError.persistenceFailed
                }
                startStage = .restore
            case .restore:
                let generation = lifecycleGeneration
                startStage = .waitingForRestore
                transport.restore(
                    records: downloads.filter { $0.phase == .downloading }
                ) { [weak self] in
                    self?.completeRestore(generation: generation)
                }
                guard startStage == .waitingForRestore || health == .available else {
                    throw DownloadManagerError.persistenceFailed
                }
                return
            case .metadataBeforeDrain:
                guard persistPendingMetadata(drainAfterSuccess: false) else {
                    throw DownloadManagerError.persistenceFailed
                }
                startStage = .drain
            case .drain:
                drainQueue()
                guard health == .available else {
                    startStage = .metadataBeforeDrain
                    throw DownloadManagerError.persistenceFailed
                }
                startStage = .complete
                if !needsScheduledRecovery {
                    cancelScheduledMetadataRetry()
                }
            }
        }
    }

    private func completeRestore(generation: UInt) {
        guard isStarted,
              generation == lifecycleGeneration,
              startStage == .waitingForRestore else {
            return
        }

        startStage = .metadataBeforeDrain
        do {
            try continueStart()
        } catch {
            scheduleMetadataRetryIfNeeded()
        }
    }

    @discardableResult
    func enqueue(_ rawURL: String) throws -> UUID {
        guard isPubliclyReady else {
            throw DownloadManagerError.persistenceFailed
        }
        let url = try DownloadRequestParser.parse(rawURL)

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
        guard isPubliclyReady,
              let record = download(id),
              record.phase == .downloading,
              pendingFinalizations[id] == nil,
              pendingTerminalTransitions[id] == nil,
              !pendingPauseIDs.contains(id),
              persistCurrentState() else {
            return
        }

        pendingPauseIDs.insert(id)
        transport.pause(id: id)
    }

    func resume(_ id: UUID) {
        guard isPubliclyReady,
              let index = downloads.firstIndex(where: { $0.id == id }),
              downloads[index].phase == .paused,
              usableResumeData(downloads[index].resumeData) != nil else {
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

    func restart(_ id: UUID) {
        guard isPubliclyReady,
              let index = downloads.firstIndex(where: { $0.id == id }),
              downloads[index].phase == .paused,
              usableResumeData(downloads[index].resumeData) == nil else {
            return
        }

        var updated = downloads
        updated[index].phase = .queued
        updated[index].taskIdentifier = nil
        updated[index].resumeData = nil
        updated[index].bytesReceived = 0
        updated[index].totalBytes = nil
        updated[index].failure = nil
        updated[index].completedAt = nil
        guard persistAndPublishWithoutThrow(updated) else { return }
        drainQueue()
    }

    func cancel(_ id: UUID) {
        guard isPubliclyReady,
              let index = downloads.firstIndex(where: { $0.id == id }),
              [.queued, .downloading, .paused, .failed].contains(downloads[index].phase),
              pendingFinalizations[id] == nil else {
            return
        }

        if downloads[index].failure?.code == "destination-write" {
            do {
                try finalizationStore.markAbandoned(downloadID: id)
                pendingAbandonmentIDs.insert(id)
            } catch {
                health = .unavailable(message: Self.finalizationRecoveryFailureMessage)
                return
            }
        }

        var updated = downloads
        updated[index].phase = .cancelled
        guard persistAndPublishWithoutThrow(updated) else { return }
        pendingNonterminalUpdates.removeValue(forKey: id)
        discardPendingTerminalTransition(id: id)
        pendingPauseIDs.remove(id)
        transport.cancel(id: id)
    }

    func retry(_ id: UUID) {
        guard isPubliclyReady,
              !pendingAbandonmentIDs.contains(id),
              let index = downloads.firstIndex(where: { $0.id == id }),
              downloads[index].phase == .failed else {
            return
        }

        if downloads[index].failure?.code == "destination-write" {
            retryDurableFinalization(id: id)
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
        guard isPubliclyReady,
              let index = downloads.firstIndex(where: { $0.id == id }),
              downloads[index].phase == .completed else {
            return
        }

        var updated = downloads
        updated.remove(at: index)
        _ = persistAndPublishWithoutThrow(updated)
    }

    @discardableResult
    func open(_ id: UUID) -> Result<Void, DownloadFileActionError> {
        guard isPubliclyReady,
              let record = download(id),
              record.phase == .completed,
              let destinationURL = record.destinationURL else {
            return .failure(.missingFile)
        }
        return fileActions.open(destinationURL)
    }

    @discardableResult
    func reveal(_ id: UUID) -> Result<Void, DownloadFileActionError> {
        guard isPubliclyReady,
              let record = download(id),
              record.phase == .completed,
              let destinationURL = record.destinationURL else {
            return .failure(.missingFile)
        }
        return fileActions.reveal(destinationURL)
    }

    private func download(_ id: UUID) -> CyclopDownload? {
        downloads.first { $0.id == id }
    }

    private var isPubliclyReady: Bool {
        isStarted && writesAllowed && startStage == .complete
    }

    private func handle(_ event: DownloadTransportEvent) {
        guard writesAllowed else { return }

        if !isStarted {
            switch event {
            case .paused, .cancelled, .finished, .failed:
                break
            case .started, .progress:
                return
            }
        }

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
              pendingTerminalTransitions[id] == nil,
              pendingNonterminalUpdates[id]?.taskIdentifier == nil,
              downloads[index].taskIdentifier != taskIdentifier,
              downloads[index].taskIdentifier == nil
                || startStage == .waitingForRestore else {
            return
        }

        var update = pendingNonterminalUpdates[id] ?? PendingNonterminalUpdate()
        update.taskIdentifier = taskIdentifier
        update.clearsResumeData = true
        registerNonterminalUpdate(id: id, update: update)
    }

    private func handleProgress(id: UUID, received: Int64, expected: Int64?) {
        guard let index = downloads.firstIndex(where: { $0.id == id }),
              downloads[index].phase == .downloading,
              pendingFinalizations[id] == nil,
              pendingTerminalTransitions[id] == nil else {
            return
        }

        var updated = downloads
        updated[index].bytesReceived = max(0, received)
        updated[index].totalBytes = expected.flatMap { $0 > 0 ? $0 : nil }
        setDownloads(updated)

        if var update = pendingNonterminalUpdates[id] {
            update.progress = PendingProgress(
                bytesReceived: updated[index].bytesReceived,
                totalBytes: updated[index].totalBytes
            )
            pendingNonterminalUpdates[id] = update
        }

        let now = clock.now
        guard shouldPersistProgress(id: id, now: now) else { return }
        lastGlobalProgressSaveAt = now
        lastProgressSaveAtByID[id] = now
        var update = pendingNonterminalUpdates[id] ?? PendingNonterminalUpdate()
        update.progress = PendingProgress(
            bytesReceived: updated[index].bytesReceived,
            totalBytes: updated[index].totalBytes
        )
        registerNonterminalUpdate(id: id, update: update)
    }

    private func handlePaused(id: UUID, resumeData: Data?) {
        guard pendingFinalizations[id] == nil,
              pendingTerminalTransitions[id] == nil,
              pendingPauseIDs.contains(id),
              let index = downloads.firstIndex(where: { $0.id == id }),
              downloads[index].phase == .downloading else {
            return
        }

        var updated = downloads
        updated[index].phase = .paused
        updated[index].taskIdentifier = nil
        updated[index].resumeData = usableResumeData(resumeData)
        registerTerminalTransition(
            id: id,
            expectedPhase: .downloading,
            record: updated[index]
        )
    }

    private func handleCancelled(id: UUID) {
        guard downloads.contains(where: { $0.id == id && $0.phase == .cancelled }),
              pendingTerminalTransitions[id] == nil else {
            return
        }

        registerTerminalTransition(
            id: id,
            expectedPhase: .cancelled,
            record: nil
        )
    }

    private func handleFailed(
        id: UUID,
        code: String,
        message: String,
        resumeData: Data?
    ) {
        guard pendingFinalizations[id] == nil,
              pendingTerminalTransitions[id] == nil,
              let index = downloads.firstIndex(where: { $0.id == id }),
              downloads[index].phase == .downloading else {
            return
        }

        var updated = downloads
        updated[index].phase = .failed
        updated[index].taskIdentifier = nil
        updated[index].resumeData = usableResumeData(resumeData)
        updated[index].completedAt = nil
        updated[index].failedAt = failureOccurrence(after: updated[index].failedAt)
        updated[index].failure = DownloadFailure(
            code: code,
            message: message.isEmpty ? "Не удалось скачать файл" : message
        )
        registerTerminalTransition(
            id: id,
            expectedPhase: .downloading,
            record: updated[index]
        )
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

        guard pendingTerminalTransitions[id] == nil else { return }

        guard let index = downloads.firstIndex(where: { $0.id == id }),
              downloads[index].phase == .downloading else {
            return
        }

        let record = downloads[index]
        let destinationURL = DownloadNaming.destination(
            folder: settings.downloadsFolder,
            responseFilename: suggestedFilename,
            remoteURL: record.remoteURL,
            fileExists: fileOperations.fileExists
        )
        let completedAt = clock.now
        let stagedURL: URL
        do {
            stagedURL = try finalizationStore.stage(
                downloadID: id,
                temporaryURL: temporaryURL
            )
        } catch {
            registerDestinationFailure(
                id: id,
                expectedPhase: .downloading,
                code: "destination-stage",
                message: Self.stagingFailureMessage
            )
            return
        }
        do {
            try finalizationStore.save(DownloadFinalizationJournal(
                downloadID: id,
                destinationURL: destinationURL,
                completedAt: completedAt
            ))
        } catch {
            registerDestinationFailure(id: id, expectedPhase: .downloading)
            return
        }

        completeDurableFinalization(
            record: record,
            expectedPhase: .downloading,
            stagedURL: stagedURL,
            journal: DownloadFinalizationJournal(
                downloadID: id,
                destinationURL: destinationURL,
                completedAt: completedAt
            )
        )
    }

    private func completeDurableFinalization(
        record: CyclopDownload,
        expectedPhase: DownloadPhase,
        stagedURL: URL?,
        journal: DownloadFinalizationJournal
    ) {
        if let stagedURL {
            do {
                try fileOperations.createDirectory(
                    journal.destinationURL.deletingLastPathComponent()
                )
                guard !fileOperations.fileExists(journal.destinationURL.path) else {
                    registerDestinationFailure(id: record.id, expectedPhase: expectedPhase)
                    return
                }
                try fileOperations.moveItem(stagedURL, journal.destinationURL)
            } catch {
                registerDestinationFailure(id: record.id, expectedPhase: expectedPhase)
                return
            }
        } else if !fileOperations.fileExists(journal.destinationURL.path) {
            health = .unavailable(message: Self.finalizationRecoveryFailureMessage)
            return
        }

        ownFileMoveSubject.send(OwnDownloadFileMove(
            fileURL: journal.destinationURL,
            occurredAt: journal.completedAt
        ))
        var completed = record
        completed.phase = .completed
        completed.displayName = journal.destinationURL.lastPathComponent
        completed.destinationURL = journal.destinationURL
        completed.taskIdentifier = nil
        completed.resumeData = nil
        completed.completedAt = journal.completedAt
        completed.failedAt = nil
        completed.failure = nil
        let pending = PendingFinalization(
            expectedPhase: expectedPhase,
            record: completed,
            completion: OwnDownloadCompletion(
                fileURL: journal.destinationURL,
                occurredAt: journal.completedAt
            )
        )
        pendingNonterminalUpdates.removeValue(forKey: record.id)
        pendingTerminalTransitions.removeValue(forKey: record.id)
        pendingFinalizations[record.id] = pending
        _ = finalize(id: record.id, pending: pending)
    }

    private func reconcileDurableFinalizations(
        _ recoveries: [DownloadFinalizationRecovery]
    ) throws {
        for recovery in recoveries {
            guard let record = download(recovery.downloadID) else {
                throw DownloadFinalizationStoreError.invalidJournal
            }

            if record.phase == .completed {
                guard case .journal = recovery else {
                    throw DownloadFinalizationStoreError.invalidJournal
                }
                try finalizationStore.removeJournal(downloadID: record.id)
                continue
            }

            guard record.phase == .downloading
                    || (record.phase == .failed
                        && record.failure?.code == "destination-write") else {
                throw DownloadFinalizationStoreError.invalidJournal
            }

            let expectedPhase = record.phase
            switch recovery {
            case let .stagedOnly(downloadID, stagedURL):
                let journal = DownloadFinalizationJournal(
                    downloadID: downloadID,
                    destinationURL: DownloadNaming.destination(
                        folder: settings.downloadsFolder,
                        responseFilename: record.displayName,
                        remoteURL: record.remoteURL,
                        fileExists: fileOperations.fileExists
                    ),
                    completedAt: clock.now
                )
                try finalizationStore.save(journal)
                completeDurableFinalization(
                    record: record,
                    expectedPhase: expectedPhase,
                    stagedURL: stagedURL,
                    journal: journal
                )
            case let .journal(journal, stagedURL):
                guard stagedURL != nil
                        || fileOperations.fileExists(journal.destinationURL.path) else {
                    throw DownloadFinalizationStoreError.invalidJournal
                }
                completeDurableFinalization(
                    record: record,
                    expectedPhase: expectedPhase,
                    stagedURL: stagedURL,
                    journal: journal
                )
            }
        }
    }

    private func retryDurableFinalization(id: UUID) {
        guard let record = download(id),
              record.phase == .failed,
              record.failure?.code == "destination-write" else {
            return
        }

        let recovery: DownloadFinalizationRecovery
        do {
            guard let found = try finalizationStore.recoveries().first(where: {
                $0.downloadID == id
            }) else {
                health = .unavailable(message: Self.finalizationRecoveryFailureMessage)
                return
            }
            recovery = found
        } catch {
            health = .unavailable(message: Self.finalizationRecoveryFailureMessage)
            return
        }

        do {
            switch recovery {
            case let .stagedOnly(downloadID, stagedURL):
                let journal = DownloadFinalizationJournal(
                    downloadID: downloadID,
                    destinationURL: DownloadNaming.destination(
                        folder: settings.downloadsFolder,
                        responseFilename: record.displayName,
                        remoteURL: record.remoteURL,
                        fileExists: fileOperations.fileExists
                    ),
                    completedAt: clock.now
                )
                try finalizationStore.save(journal)
                completeDurableFinalization(
                    record: record,
                    expectedPhase: .failed,
                    stagedURL: stagedURL,
                    journal: journal
                )
            case let .journal(existingJournal, stagedURL):
                guard let stagedURL else {
                    guard fileOperations.fileExists(existingJournal.destinationURL.path) else {
                        health = .unavailable(
                            message: Self.finalizationRecoveryFailureMessage
                        )
                        return
                    }
                    completeDurableFinalization(
                        record: record,
                        expectedPhase: .failed,
                        stagedURL: nil,
                        journal: existingJournal
                    )
                    return
                }

                let journal: DownloadFinalizationJournal
                if fileOperations.fileExists(existingJournal.destinationURL.path) {
                    journal = DownloadFinalizationJournal(
                        downloadID: id,
                        destinationURL: DownloadNaming.destination(
                            folder: settings.downloadsFolder,
                            responseFilename: record.displayName,
                            remoteURL: record.remoteURL,
                            fileExists: fileOperations.fileExists
                        ),
                        completedAt: clock.now
                    )
                    try finalizationStore.save(journal)
                } else {
                    journal = existingJournal
                }
                completeDurableFinalization(
                    record: record,
                    expectedPhase: .failed,
                    stagedURL: stagedURL,
                    journal: journal
                )
            }
        } catch {
            health = .unavailable(message: Self.finalizationRecoveryFailureMessage)
        }
    }

    private func registerDestinationFailure(
        id: UUID,
        expectedPhase: DownloadPhase,
        code: String = "destination-write",
        message: String? = nil
    ) {
        guard let index = downloads.firstIndex(where: { $0.id == id }),
              downloads[index].phase == expectedPhase else {
            return
        }
        var failed = downloads[index]
        failed.phase = .failed
        failed.taskIdentifier = nil
        if code == "destination-stage" {
            failed.resumeData = nil
            failed.bytesReceived = 0
            failed.totalBytes = nil
        }
        failed.completedAt = nil
        failed.failedAt = failureOccurrence(after: failed.failedAt)
        failed.failure = DownloadFailure(
            code: code,
            message: message ?? Self.destinationFailureMessage
        )
        registerTerminalTransition(
            id: id,
            expectedPhase: expectedPhase,
            record: failed
        )
    }

    @discardableResult
    private func finalize(id: UUID, pending _: PendingFinalization) -> Bool {
        guard pendingFinalizations[id] != nil else { return false }
        return persistPendingMetadata(
            drainAfterSuccess: startStage == .complete || isDraining
        )
    }

    private func registerTerminalTransition(
        id: UUID,
        expectedPhase: DownloadPhase,
        record: CyclopDownload?
    ) {
        guard pendingTerminalTransitions[id] == nil else { return }

        pendingNonterminalUpdates.removeValue(forKey: id)
        pendingTerminalTransitions[id] = PendingTerminalTransition(
            expectedPhase: expectedPhase,
            record: record
        )
        _ = persistPendingMetadata(
            drainAfterSuccess: startStage == .complete || isDraining
        )
    }

    private func registerNonterminalUpdate(id: UUID, update: PendingNonterminalUpdate) {
        guard pendingTerminalTransitions[id] == nil,
              pendingFinalizations[id] == nil else {
            return
        }

        pendingNonterminalUpdates[id] = update
        _ = persistPendingMetadata(
            drainAfterSuccess: startStage == .complete || isDraining
        )
    }

    @discardableResult
    private func persistPendingMetadata(
        scheduleRetry: Bool = true,
        drainAfterSuccess: Bool = true
    ) -> Bool {
        guard writesAllowed else { return false }

        var updated = downloads
        var committedTerminalIDs: [UUID] = []
        var committedFinalizations: [(UUID, PendingFinalization)] = []
        var committedNonterminalIDs: [UUID] = []
        var staleTerminalIDs: [UUID] = []
        var staleFinalizationIDs: [UUID] = []
        var staleNonterminalIDs: [UUID] = []
        let pendingIDs = Set(pendingTerminalTransitions.keys)
            .union(pendingFinalizations.keys)
            .union(pendingNonterminalUpdates.keys)
            .sorted(by: {
                $0.uuidString < $1.uuidString
            })
        for id in pendingIDs {
            if let pending = pendingTerminalTransitions[id] {
                guard let index = updated.firstIndex(where: { $0.id == id }),
                      updated[index].phase == pending.expectedPhase else {
                    staleTerminalIDs.append(id)
                    if pendingFinalizations[id] != nil {
                        staleFinalizationIDs.append(id)
                    }
                    if pendingNonterminalUpdates[id] != nil {
                        staleNonterminalIDs.append(id)
                    }
                    continue
                }

                if let record = pending.record {
                    updated[index] = record
                } else {
                    updated.remove(at: index)
                }
                committedTerminalIDs.append(id)
                if pendingFinalizations[id] != nil {
                    staleFinalizationIDs.append(id)
                }
                if pendingNonterminalUpdates[id] != nil {
                    staleNonterminalIDs.append(id)
                }
                continue
            }

            if let pending = pendingFinalizations[id] {
                guard let index = updated.firstIndex(where: { $0.id == id }),
                      updated[index].phase == pending.expectedPhase else {
                    staleFinalizationIDs.append(id)
                    if pendingNonterminalUpdates[id] != nil {
                        staleNonterminalIDs.append(id)
                    }
                    continue
                }

                updated[index] = pending.record
                committedFinalizations.append((id, pending))
                if pendingNonterminalUpdates[id] != nil {
                    staleNonterminalIDs.append(id)
                }
                continue
            }

            guard let pending = pendingNonterminalUpdates[id],
                  let index = updated.firstIndex(where: { $0.id == id }),
                  updated[index].phase == .downloading else {
                staleNonterminalIDs.append(id)
                continue
            }

            if let taskIdentifier = pending.taskIdentifier {
                updated[index].taskIdentifier = taskIdentifier
                if pending.clearsResumeData {
                    updated[index].resumeData = nil
                }
            }
            if let progress = pending.progress {
                updated[index].bytesReceived = progress.bytesReceived
                updated[index].totalBytes = progress.totalBytes
            }
            committedNonterminalIDs.append(id)
        }

        for id in staleTerminalIDs {
            pendingTerminalTransitions.removeValue(forKey: id)
        }
        for id in staleFinalizationIDs {
            pendingFinalizations.removeValue(forKey: id)
        }
        for id in staleNonterminalIDs {
            pendingNonterminalUpdates.removeValue(forKey: id)
        }
        guard !committedTerminalIDs.isEmpty
                || !committedFinalizations.isEmpty
                || !committedNonterminalIDs.isEmpty else {
            if !needsScheduledRecovery {
                cancelScheduledMetadataRetry()
            }
            return true
        }

        do {
            try persistence.save(updated)
        } catch {
            health = .unavailable(message: Self.saveFailureMessage)
            if scheduleRetry {
                scheduleMetadataRetryIfNeeded()
            }
            return false
        }

        setDownloads(updated)
        health = .available
        for id in committedTerminalIDs {
            pendingTerminalTransitions.removeValue(forKey: id)
            pendingPauseIDs.remove(id)
            pendingFinalizations.removeValue(forKey: id)
        }
        for (id, _) in committedFinalizations {
            pendingFinalizations.removeValue(forKey: id)
            pendingPauseIDs.remove(id)
            do {
                try finalizationStore.removeJournal(downloadID: id)
            } catch {
                health = .unavailable(message: Self.finalizationRecoveryFailureMessage)
            }
        }
        for id in committedNonterminalIDs {
            pendingNonterminalUpdates.removeValue(forKey: id)
        }
        cleanupPendingAbandonments()
        if !needsScheduledRecovery {
            cancelScheduledMetadataRetry()
        }
        for (_, pending) in committedFinalizations {
            ownCompletionSubject.send(pending.completion)
        }
        if drainAfterSuccess {
            drainQueue()
        }
        return true
    }

    private func discardPendingTerminalTransition(id: UUID) {
        pendingTerminalTransitions.removeValue(forKey: id)
        if !needsScheduledRecovery {
            cancelScheduledMetadataRetry()
        }
    }

    private var hasPendingMetadata: Bool {
        !pendingTerminalTransitions.isEmpty
            || !pendingFinalizations.isEmpty
            || !pendingNonterminalUpdates.isEmpty
    }

    private var needsScheduledRecovery: Bool {
        if hasPendingMetadata || hasPendingAbandonmentCleanup {
            return true
        }
        guard isStarted else { return false }
        switch startStage {
        case .metadataBeforeRestore, .restore, .metadataBeforeDrain, .drain:
            return true
        case .stopped, .waitingForRestore, .complete:
            return false
        }
    }

    private var hasPendingAbandonmentCleanup: Bool {
        pendingAbandonmentIDs.contains { id in
            !downloads.contains(where: { $0.id == id })
        }
    }

    private func cleanupPendingAbandonments() {
        for id in pendingAbandonmentIDs.sorted(by: { $0.uuidString < $1.uuidString })
        where !downloads.contains(where: { $0.id == id }) {
            do {
                try finalizationStore.abandon(downloadID: id)
                pendingAbandonmentIDs.remove(id)
            } catch {
                health = .unavailable(message: Self.finalizationRecoveryFailureMessage)
                scheduleMetadataRetryIfNeeded()
            }
        }
    }

    private func scheduleMetadataRetryIfNeeded() {
        guard scheduledMetadataRetry == nil,
              needsScheduledRecovery else {
            return
        }

        let generation = metadataRetryGeneration
        let retryAt = clock.now.addingTimeInterval(Self.metadataPersistenceRetryInterval)
        scheduledMetadataRetry = scheduler.schedule(at: retryAt) { [weak self] in
            self?.handleScheduledMetadataRetry(generation: generation)
        }
    }

    private func handleScheduledMetadataRetry(generation: UInt) {
        guard generation == metadataRetryGeneration,
              needsScheduledRecovery else {
            return
        }

        cancelScheduledMetadataRetry()
        if hasPendingAbandonmentCleanup {
            cleanupPendingAbandonments()
        }
        if !isStarted || startStage == .complete {
            _ = persistPendingMetadata()
        } else {
            do {
                try continueStart()
            } catch {
                scheduleMetadataRetryIfNeeded()
            }
        }
    }

    private func cancelScheduledMetadataRetry() {
        metadataRetryGeneration &+= 1
        scheduledMetadataRetry?.cancel()
        scheduledMetadataRetry = nil
    }

    private func drainQueue() {
        guard isStarted,
              writesAllowed,
              startStage == .drain || startStage == .complete,
              concurrencyLimit > 0 else {
            return
        }
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
           now.timeIntervalSince(lastGlobalProgressSaveAt) < 0 {
            self.lastGlobalProgressSaveAt = nil
            lastProgressSaveAtByID.removeAll()
        } else if let lastGlobalProgressSaveAt,
                  now.timeIntervalSince(lastGlobalProgressSaveAt)
                    < Self.progressPersistenceInterval {
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

        setDownloads(updated)
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

    private func setDownloads(_ updated: [CyclopDownload]) {
        downloads = updated
        if isStarted {
            downloadsStateSubject.send(updated)
        }
    }

    private func usableResumeData(_ data: Data?) -> Data? {
        guard let data, !data.isEmpty else { return nil }
        return data
    }

    private func failureOccurrence(after previous: Date?) -> Date {
        guard let previous else { return clock.now }
        return max(clock.now, previous.addingTimeInterval(0.001))
    }
}
