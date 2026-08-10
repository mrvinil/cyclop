import Foundation

protocol ActivityClock: AnyObject {
    var now: Date { get }
}

final class SystemActivityClock: ActivityClock {
    var now: Date { Date() }
}

protocol ActivityCancellation: AnyObject {
    func cancel()
}

protocol ActivityScheduling: AnyObject {
    @discardableResult
    func schedule(at date: Date, _ action: @escaping @MainActor () -> Void) -> ActivityCancellation
}
