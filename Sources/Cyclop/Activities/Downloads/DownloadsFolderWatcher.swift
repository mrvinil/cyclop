import Combine
import Darwin
import Dispatch
import Foundation

struct ExternalDownloadCompletion: Identifiable, Equatable {
    let id: String
    let fileURL: URL
    let occurredAt: Date
}

enum DownloadsFolderEvent: Equatable {
    case contentsChanged
    case folderReplaced
}

struct DownloadsFolderDescriptorOperations {
    let open: (String, Int32) -> Int32
    let close: (Int32) -> Void

    static let live = Self(
        open: { path, flags in Darwin.open(path, flags) },
        close: { descriptor in _ = Darwin.close(descriptor) }
    )
}

protocol DownloadsFolderDispatchSource: AnyObject {
    var data: DispatchSource.FileSystemEvent { get }
    func setEventHandler(_ handler: @escaping () -> Void)
    func setCancelHandler(_ handler: @escaping () -> Void)
    func resume()
    func cancel()
}

private final class LiveDownloadsFolderDispatchSource: DownloadsFolderDispatchSource {
    private let source: any DispatchSourceFileSystemObject

    init(_ source: any DispatchSourceFileSystemObject) {
        self.source = source
    }

    var data: DispatchSource.FileSystemEvent { source.data }

    func setEventHandler(_ handler: @escaping () -> Void) {
        source.setEventHandler(handler: handler)
    }

    func setCancelHandler(_ handler: @escaping () -> Void) {
        source.setCancelHandler(handler: handler)
    }

    func resume() {
        source.resume()
    }

    func cancel() {
        source.cancel()
    }
}

private final class DownloadsFolderDescriptorLease {
    private let descriptor: Int32
    private let closeDescriptor: (Int32) -> Void
    private var isClosed = false

    init(descriptor: Int32, closeDescriptor: @escaping (Int32) -> Void) {
        self.descriptor = descriptor
        self.closeDescriptor = closeDescriptor
    }

    func closeOnce() {
        guard !isClosed else { return }
        isClosed = true
        closeDescriptor(descriptor)
    }
}

@MainActor
final class DispatchDownloadsFolderEventMonitor: DownloadsFolderEventMonitoring {
    typealias SourceFactory = (
        Int32,
        DispatchSource.FileSystemEvent
    ) -> DownloadsFolderDispatchSource

    private static let eventMask: DispatchSource.FileSystemEvent = [
        .write,
        .rename,
        .delete,
        .extend,
        .attrib
    ]

    private let descriptorOperations: DownloadsFolderDescriptorOperations
    private let sourceFactory: SourceFactory
    private var source: DownloadsFolderDispatchSource?

    init(
        descriptorOperations: DownloadsFolderDescriptorOperations = .live,
        sourceFactory: @escaping SourceFactory = { descriptor, mask in
            LiveDownloadsFolderDispatchSource(
                DispatchSource.makeFileSystemObjectSource(
                    fileDescriptor: descriptor,
                    eventMask: mask,
                    queue: .main
                )
            )
        }
    ) {
        self.descriptorOperations = descriptorOperations
        self.sourceFactory = sourceFactory
    }

    func start(
        folder: URL,
        handler: @escaping @MainActor (DownloadsFolderEvent) -> Void
    ) throws {
        stop()
        let descriptor = descriptorOperations.open(folder.path, O_EVTONLY)
        guard descriptor >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }

        let lease = DownloadsFolderDescriptorLease(
            descriptor: descriptor,
            closeDescriptor: descriptorOperations.close
        )
        let source = sourceFactory(descriptor, Self.eventMask)
        source.setEventHandler { [weak source] in
            guard let source else { return }
            let event: DownloadsFolderEvent = source.data.contains(.rename)
                || source.data.contains(.delete)
                ? .folderReplaced
                : .contentsChanged
            MainActor.assumeIsolated {
                handler(event)
            }
        }
        source.setCancelHandler {
            lease.closeOnce()
        }
        self.source = source
        source.resume()
    }

    func stop() {
        guard let source else { return }
        self.source = nil
        source.cancel()
    }

    deinit {
        source?.cancel()
    }
}

@MainActor
protocol DownloadsFolderEventMonitoring: AnyObject {
    func start(
        folder: URL,
        handler: @escaping @MainActor (DownloadsFolderEvent) -> Void
    ) throws
    func stop()
}

@MainActor
final class DownloadsFolderWatcher: ObservableObject {
    @Published private(set) var completions: [ExternalDownloadCompletion] = []
    @Published private(set) var health: ActivitySourceHealth = .available

    var completionsStatePublisher: AnyPublisher<[ExternalDownloadCompletion], Never> {
        completionsStateSubject.publisher
    }

    private static let unavailableMessage = "Папка загрузок недоступна"
    private static let eventDebounceInterval: TimeInterval = 0.3
    private static let stabilityInterval: TimeInterval = 1.5
    private static let ownSuppressionInterval: TimeInterval = 10

    private enum FileIdentity: Hashable {
        case resource(AnyHashable)
        case path(String)

        var stableDescription: String {
            switch self {
            case let .resource(identifier):
                return "resource:\(String(reflecting: identifier))"
            case let .path(path):
                return "path:\(path)"
            }
        }
    }

    private enum ObservationPhase {
        case temporary
        case baseline
        case candidate(since: Date)
        case emitted
    }

    private struct Observation {
        var snapshot: FolderFileSnapshot
        var phase: ObservationPhase
        var missingSince: Date?
    }

    private let clock: ActivityClock
    private let scheduler: ActivityScheduling
    private let snapshotProvider: FolderSnapshotProviding
    private let eventMonitor: DownloadsFolderEventMonitoring
    private let completionsStateSubject = NonReentrantCurrentValueSubject<
        [ExternalDownloadCompletion]
    >([])

    private var folder: URL
    private var isStarted = false
    private var isMonitoring = false
    private var observations: [FileIdentity: Observation] = [:]
    private var debounceCancellation: ActivityCancellation?
    private var debounceGeneration: UInt = 0
    private var stabilityCancellation: ActivityCancellation?
    private var stabilityGeneration: UInt = 0
    private var monitorGeneration: UInt = 0
    private var settingsObservation: AnyCancellable?
    private var ownFileMoveObservation: AnyCancellable?
    private var ownSuppressionDates: [String: Date] = [:]
    private var suppressionCleanupCancellation: ActivityCancellation?
    private var suppressionCleanupGeneration: UInt = 0

    init(
        settings: ActivitySettings,
        clock: ActivityClock,
        scheduler: ActivityScheduling,
        snapshotProvider: FolderSnapshotProviding,
        ownFileMovePublisher: AnyPublisher<OwnDownloadFileMove, Never>,
        eventMonitor: DownloadsFolderEventMonitoring
    ) {
        folder = settings.downloadsFolder
        self.clock = clock
        self.scheduler = scheduler
        self.snapshotProvider = snapshotProvider
        self.eventMonitor = eventMonitor

        settingsObservation = settings.$downloadsFolder
            .dropFirst()
            .sink { [weak self] folder in
                self?.replaceFolder(with: folder)
            }
        ownFileMoveObservation = ownFileMovePublisher
            .sink { [weak self] move in
                self?.suppressOwnCompletion(
                    fileURL: move.fileURL,
                    at: move.occurredAt
                )
            }
    }

    convenience init(
        settings: ActivitySettings,
        clock: ActivityClock,
        scheduler: ActivityScheduling,
        ownFileMovePublisher: AnyPublisher<OwnDownloadFileMove, Never>
    ) {
        self.init(
            settings: settings,
            clock: clock,
            scheduler: scheduler,
            snapshotProvider: FileManagerFolderSnapshotProvider(),
            ownFileMovePublisher: ownFileMovePublisher,
            eventMonitor: DispatchDownloadsFolderEventMonitor()
        )
    }

    func start() {
        guard !isStarted else { return }
        isStarted = true
        startCurrentFolder()
    }

    func stop() {
        guard isStarted else { return }
        isStarted = false
        cancelDebounce()
        stopMonitoring()
        cancelStabilityCheck()
        observations.removeAll()
    }

    func folderDidChange() {
        guard isStarted, isMonitoring else { return }
        cancelDebounce()
        let generation = debounceGeneration
        debounceCancellation = scheduler.schedule(
            at: clock.now.addingTimeInterval(Self.eventDebounceInterval)
        ) { [weak self] in
            self?.scanAfterDebounce(generation: generation)
        }
    }

    func replaceFolder(with newFolder: URL) {
        guard newFolder != folder else { return }
        folder = newFolder
        guard isStarted else { return }

        cancelDebounce()
        stopMonitoring()
        cancelStabilityCheck()
        observations.removeAll()
        startCurrentFolder()
    }

    func suppressOwnCompletion(fileURL: URL, at date: Date) {
        purgeExpiredSuppressions(at: clock.now)
        ownSuppressionDates[canonicalPath(fileURL)] = date
        scheduleSuppressionCleanup()
    }

    func dismiss(_ completionID: String) {
        guard completions.contains(where: { $0.id == completionID }) else { return }
        setCompletions(completions.filter { $0.id != completionID })
    }

    private func startCurrentFolder() {
        do {
            monitorGeneration &+= 1
            let generation = monitorGeneration
            try eventMonitor.start(folder: folder) { [weak self] event in
                self?.handleMonitorEvent(event, generation: generation)
            }
            isMonitoring = true
            let snapshots = try snapshotsForTracking()
            observations = Dictionary(
                uniqueKeysWithValues: snapshots.map {
                    (
                        identity(for: $0),
                        Observation(
                            snapshot: $0,
                            phase: isTemporary($0) ? .temporary : .baseline,
                            missingSince: nil
                        )
                    )
                }
            )
            health = .available
        } catch {
            stopMonitoring()
            observations.removeAll()
            health = .unavailable(message: Self.unavailableMessage)
        }
    }

    private func restartCurrentFolder() {
        guard isStarted else { return }
        cancelDebounce()
        stopMonitoring()
        cancelStabilityCheck()
        observations.removeAll()
        startCurrentFolder()
    }

    private func handleMonitorEvent(_ event: DownloadsFolderEvent, generation: UInt) {
        guard isStarted, isMonitoring, generation == monitorGeneration else { return }
        switch event {
        case .contentsChanged:
            folderDidChange()
        case .folderReplaced:
            restartCurrentFolder()
        }
    }

    private func scanAfterDebounce(generation: UInt) {
        guard generation == debounceGeneration else { return }
        debounceCancellation = nil
        guard isStarted, isMonitoring else { return }
        do {
            try scan()
        } catch {
            becomeUnavailable()
        }
    }

    private func scan() throws {
        let snapshots = try snapshotsForTracking()
        let current = Dictionary(
            uniqueKeysWithValues: snapshots.map { (identity(for: $0), $0) }
        )
        let now = clock.now

        for identity in observations.keys {
            guard var observation = observations[identity] else { continue }
            if case let .candidate(since) = observation.phase, now < since {
                observation.phase = .candidate(since: now)
            }
            if let missingSince = observation.missingSince, now < missingSince {
                observation.missingSince = now
            }
            observations[identity] = observation
        }

        for identity in Array(observations.keys) where current[identity] == nil {
            guard var observation = observations[identity] else { continue }
            if observation.missingSince != nil {
                observations.removeValue(forKey: identity)
            } else {
                observation.missingSince = now
                if case .candidate = observation.phase {
                    observation.phase = .candidate(since: now)
                }
                observations[identity] = observation
            }
        }

        for snapshot in snapshots {
            let identity = identity(for: snapshot)
            guard var observation = observations[identity] else {
                observations[identity] = Observation(
                    snapshot: snapshot,
                    phase: isTemporary(snapshot) ? .temporary : .candidate(since: now),
                    missingSince: nil
                )
                continue
            }

            let returnedAfterMissingScan = observation.missingSince != nil
            observation.missingSince = nil

            if returnedAfterMissingScan,
               case .path = identity,
               !isTemporary(snapshot) {
                observation.phase = .candidate(since: now)
                observation.snapshot = snapshot
                observations[identity] = observation
                continue
            }

            switch observation.phase {
            case .temporary:
                if !isTemporary(snapshot) {
                    emit(snapshot: snapshot, identity: identity, at: now)
                    observation.phase = .emitted
                }
            case .baseline:
                if isTemporary(snapshot) {
                    observation.phase = .temporary
                } else if returnedAfterMissingScan,
                          case .resource = identity {
                    observation.phase = .baseline
                } else {
                    observation.phase = hasSameFingerprint(observation.snapshot, snapshot)
                        ? .baseline
                        : .candidate(since: now)
                }
            case let .candidate(since):
                if isTemporary(snapshot) {
                    observation.phase = .temporary
                } else if returnedAfterMissingScan
                    || !hasSameFingerprint(observation.snapshot, snapshot) {
                    observation.phase = .candidate(since: now)
                } else if now.timeIntervalSince(since) >= Self.stabilityInterval {
                    emit(snapshot: snapshot, identity: identity, at: now)
                    observation.phase = .emitted
                }
            case .emitted:
                if case .path = identity,
                   !hasSameFingerprint(observation.snapshot, snapshot) {
                    observation.phase = isTemporary(snapshot)
                        ? .temporary
                        : .candidate(since: now)
                }
            }
            observation.snapshot = snapshot
            observations[identity] = observation
        }

        health = .available
        scheduleNextStabilityCheck()
    }

    private func snapshotsForTracking() throws -> [FolderFileSnapshot] {
        let snapshots = try snapshotProvider.snapshots(in: folder)
            .filter { !$0.url.lastPathComponent.hasPrefix(".") }
            .sorted { $0.url.path < $1.url.path }
        var seenIdentities: Set<FileIdentity> = []
        return snapshots.filter { seenIdentities.insert(identity(for: $0)).inserted }
    }

    private func identity(for snapshot: FolderFileSnapshot) -> FileIdentity {
        if let resourceIdentifier = snapshot.fileResourceIdentifier {
            return .resource(resourceIdentifier)
        }
        return .path(canonicalPath(snapshot.url))
    }

    private func isTemporary(_ snapshot: FolderFileSnapshot) -> Bool {
        FileManagerFolderSnapshotProvider.isTemporaryFileName(snapshot.url.lastPathComponent)
    }

    private func hasSameFingerprint(
        _ lhs: FolderFileSnapshot,
        _ rhs: FolderFileSnapshot
    ) -> Bool {
        lhs.size == rhs.size && lhs.modifiedAt == rhs.modifiedAt
    }

    private func emit(snapshot: FolderFileSnapshot, identity: FileIdentity, at date: Date) {
        let path = canonicalPath(snapshot.url)
        purgeExpiredSuppressions(at: date)
        if let suppressedAt = ownSuppressionDates[path],
           date.timeIntervalSince(suppressedAt) < Self.ownSuppressionInterval {
            ownSuppressionDates.removeValue(forKey: path)
            scheduleSuppressionCleanup()
            return
        }

        let timestamp = Int64((date.timeIntervalSince1970 * 1_000).rounded())
        setCompletions(completions + [ExternalDownloadCompletion(
            id: "\(identity.stableDescription)|\(timestamp)",
            fileURL: snapshot.url,
            occurredAt: date
        )])
    }

    private func scheduleNextStabilityCheck() {
        let nextDate = observations.values.flatMap { observation -> [Date] in
            if let missingSince = observation.missingSince {
                return [missingSince.addingTimeInterval(Self.stabilityInterval)]
            }
            guard case let .candidate(since) = observation.phase else { return [] }
            return [since.addingTimeInterval(Self.stabilityInterval)]
        }
        .min()

        cancelStabilityCheck()
        guard let nextDate else { return }
        let generation = stabilityGeneration
        stabilityCancellation = scheduler.schedule(at: nextDate) { [weak self] in
            self?.handleStabilityCheck(generation: generation)
        }
    }

    private func handleStabilityCheck(generation: UInt) {
        guard generation == stabilityGeneration, isStarted, isMonitoring else { return }
        stabilityCancellation = nil
        do {
            try scan()
        } catch {
            becomeUnavailable()
        }
    }

    private func becomeUnavailable() {
        cancelDebounce()
        cancelStabilityCheck()
        stopMonitoring()
        observations.removeAll()
        health = .unavailable(message: Self.unavailableMessage)
    }

    private func cancelDebounce() {
        debounceGeneration &+= 1
        debounceCancellation?.cancel()
        debounceCancellation = nil
    }

    private func stopMonitoring() {
        monitorGeneration &+= 1
        guard isMonitoring else { return }
        eventMonitor.stop()
        isMonitoring = false
    }

    private func cancelStabilityCheck() {
        stabilityGeneration &+= 1
        stabilityCancellation?.cancel()
        stabilityCancellation = nil
    }

    private func canonicalPath(_ url: URL) -> String {
        url.standardizedFileURL
            .resolvingSymlinksInPath()
            .standardizedFileURL
            .path
    }

    private func purgeExpiredSuppressions(at date: Date) {
        let rolledBackPaths = ownSuppressionDates.compactMap { path, suppressedAt in
            date < suppressedAt ? path : nil
        }
        for path in rolledBackPaths {
            ownSuppressionDates[path] = date
        }
        ownSuppressionDates = ownSuppressionDates.filter {
            date.timeIntervalSince($0.value) < Self.ownSuppressionInterval
        }
    }

    private func scheduleSuppressionCleanup() {
        cancelSuppressionCleanup()
        guard let cleanupAt = ownSuppressionDates.values
            .map({ $0.addingTimeInterval(Self.ownSuppressionInterval) })
            .min() else {
            return
        }

        let generation = suppressionCleanupGeneration
        suppressionCleanupCancellation = scheduler.schedule(at: cleanupAt) { [weak self] in
            self?.handleSuppressionCleanup(generation: generation)
        }
    }

    private func handleSuppressionCleanup(generation: UInt) {
        guard generation == suppressionCleanupGeneration else { return }
        suppressionCleanupCancellation = nil
        purgeExpiredSuppressions(at: clock.now)
        scheduleSuppressionCleanup()
    }

    private func cancelSuppressionCleanup() {
        suppressionCleanupGeneration &+= 1
        suppressionCleanupCancellation?.cancel()
        suppressionCleanupCancellation = nil
    }

    private func setCompletions(_ updated: [ExternalDownloadCompletion]) {
        completions = updated
        completionsStateSubject.send(updated)
    }
}
