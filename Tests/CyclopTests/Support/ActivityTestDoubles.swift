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
