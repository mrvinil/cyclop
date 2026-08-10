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
