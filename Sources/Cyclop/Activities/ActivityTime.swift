import Foundation

protocol ActivityClock: AnyObject {
    var now: Date { get }
}

final class SystemActivityClock: ActivityClock {
    var now: Date { Date() }
}

@MainActor
protocol ActivityCancellation: AnyObject {
    func cancel()
}

@MainActor
protocol ActivityScheduling: AnyObject {
    @discardableResult
    func schedule(at date: Date, _ action: @escaping @MainActor () -> Void) -> ActivityCancellation
}

@MainActor
final class SystemActivityScheduler: ActivityScheduling {
    @discardableResult
    func schedule(
        at date: Date,
        _ action: @escaping @MainActor () -> Void
    ) -> ActivityCancellation {
        let cancellation = SystemActivityCancellation(action: action)
        let timer = Timer(fire: date, interval: 0, repeats: false) { [cancellation] _ in
            MainActor.assumeIsolated {
                cancellation.fire()
            }
        }
        cancellation.attach(timer)
        RunLoop.main.add(timer, forMode: .common)
        return cancellation
    }
}

@MainActor
private final class SystemActivityCancellation: ActivityCancellation {
    private var timer: Timer?
    private var action: (@MainActor () -> Void)?

    init(action: @escaping @MainActor () -> Void) {
        self.action = action
    }

    func attach(_ timer: Timer) {
        precondition(self.timer == nil)
        self.timer = timer
    }

    func cancel() {
        action = nil
        timer?.invalidate()
        timer = nil
    }

    func fire() {
        guard let action else { return }

        self.action = nil
        timer?.invalidate()
        timer = nil
        action()
    }
}
