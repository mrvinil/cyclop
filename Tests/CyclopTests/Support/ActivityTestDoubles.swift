import Combine
import Foundation
@testable import Cyclop

final class MutableActivityClock: ActivityClock {
    var now: Date

    init(now: Date) {
        self.now = now
    }

    func advance(by interval: TimeInterval) {
        now.addTimeInterval(interval)
    }
}

final class MemoryTimerPersistence: TimerPersisting {
    var stored: [CyclopTimer]
    var loadError: Error?
    var saveError: Error?
    private(set) var loadCount = 0
    private(set) var saveCount = 0
    private(set) var savedValues: [[CyclopTimer]] = []

    init(_ stored: [CyclopTimer] = []) {
        self.stored = stored
    }

    func load() throws -> [CyclopTimer] {
        loadCount += 1
        if let loadError {
            throw loadError
        }
        return stored
    }

    func save(_ timers: [CyclopTimer]) throws {
        saveCount += 1
        if let saveError {
            throw saveError
        }
        stored = timers
        savedValues.append(timers)
    }
}

private enum TestPersistenceFailure: Error {
    case injected
}

final class MemoryDownloadPersistence: DownloadPersisting {
    var stored: [CyclopDownload]
    var loadError: Error?
    var saveError: Error?
    var failingSaveCalls: Set<Int> = []
    var onSave: (([CyclopDownload]) -> Void)?
    private(set) var loadCount = 0
    private(set) var saveCount = 0
    private(set) var savedValues: [[CyclopDownload]] = []

    init(_ stored: [CyclopDownload] = []) {
        self.stored = stored
    }

    func load() throws -> [CyclopDownload] {
        loadCount += 1
        if let loadError {
            throw loadError
        }
        return stored
    }

    func save(_ downloads: [CyclopDownload]) throws {
        saveCount += 1
        if failingSaveCalls.contains(saveCount) {
            throw TestPersistenceFailure.injected
        }
        if let saveError {
            throw saveError
        }
        stored = downloads
        savedValues.append(downloads)
        onSave?(downloads)
    }
}

@MainActor
final class FakeDownloadTransport: DownloadTransport {
    struct StartCall: Equatable {
        let id: UUID
        let url: URL
        let resumeData: Data?
    }

    var eventHandler: ((DownloadTransportEvent) -> Void)?
    var onRestore: (([CyclopDownload]) -> Void)?
    var onStart: ((UUID) -> Void)?
    var onPause: ((UUID) -> Void)?
    var onCancel: ((UUID) -> Void)?
    var completesRestoreImmediately = true
    private(set) var restoredValues: [[CyclopDownload]] = []
    private(set) var startCalls: [StartCall] = []
    private(set) var pausedIDs: [UUID] = []
    private(set) var cancelledIDs: [UUID] = []
    private(set) var pendingRestoreCompletions: [@MainActor () -> Void] = []

    var startedIDs: [UUID] { startCalls.map(\.id) }

    func restore(
        records: [CyclopDownload],
        completion: @escaping @MainActor () -> Void
    ) {
        restoredValues.append(records)
        onRestore?(records)
        if completesRestoreImmediately {
            completion()
        } else {
            pendingRestoreCompletions.append(completion)
        }
    }

    func completeNextRestore() {
        guard !pendingRestoreCompletions.isEmpty else { return }
        pendingRestoreCompletions.removeFirst()()
    }

    func start(id: UUID, url: URL, resumeData: Data?) {
        startCalls.append(.init(id: id, url: url, resumeData: resumeData))
        onStart?(id)
    }

    func pause(id: UUID) {
        pausedIDs.append(id)
        onPause?(id)
    }

    func cancel(id: UUID) {
        cancelledIDs.append(id)
        onCancel?(id)
    }

    func send(_ event: DownloadTransportEvent) {
        eventHandler?(event)
    }
}

@MainActor
final class ManualActivityScheduler: ActivityScheduling {
    struct Entry {
        let date: Date
        let action: @MainActor () -> Void
        let cancellation: TestCancellation
    }

    private(set) var entries: [Entry] = []

    var activeEntries: [Entry] {
        entries.filter { !$0.cancellation.isCancelled }
    }

    @discardableResult
    func schedule(at date: Date, _ action: @escaping @MainActor () -> Void) -> ActivityCancellation {
        let cancellation = TestCancellation()
        entries.append(Entry(date: date, action: action, cancellation: cancellation))
        return cancellation
    }
}

@MainActor
final class TestCancellation: ActivityCancellation {
    private(set) var isCancelled = false

    func cancel() {
        isCancelled = true
    }
}

@MainActor
final class FakeActivitySource: ActivitySource {
    let sourceID: String
    let subject = CurrentValueSubject<ActivitySourceState, Never>(.init(snapshots: [], health: .available))
    private(set) var performed: [(ActivityAction, ActivityID)] = []

    var statePublisher: AnyPublisher<ActivitySourceState, Never> {
        subject.eraseToAnyPublisher()
    }

    init(sourceID: String) {
        self.sourceID = sourceID
    }

    func perform(_ action: ActivityAction, activityID: ActivityID) {
        performed.append((action, activityID))
    }
}
