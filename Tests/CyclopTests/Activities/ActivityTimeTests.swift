import XCTest
@testable import Cyclop

final class ActivityTimeTests: XCTestCase {
    func testMutableClockAdvancesDeterministically() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let clock = MutableActivityClock(now: start)
        clock.advance(by: 15)
        XCTAssertEqual(clock.now, start.addingTimeInterval(15))
    }

    @MainActor
    func testSystemSchedulerFiresAtAbsoluteDateOnMainActorAtMostOnce() {
        let scheduler = SystemActivityScheduler()
        let fired = expectation(description: "Запланированное действие выполнено")
        fired.assertForOverFulfill = true
        let probeFired = expectation(description: "Более поздняя проверка выполнена")
        let deadline = Date().addingTimeInterval(0.02)
        var executionCount = 0
        var actualFireDate: Date?

        let cancellation = scheduler.schedule(at: deadline) {
            executionCount += 1
            actualFireDate = Date()
            XCTAssertTrue(Thread.isMainThread)
            fired.fulfill()
        }
        let probeCancellation = scheduler.schedule(at: deadline.addingTimeInterval(0.04)) {
            probeFired.fulfill()
        }

        wait(for: [fired, probeFired], timeout: 1)

        XCTAssertEqual(executionCount, 1)
        XCTAssertGreaterThanOrEqual(actualFireDate ?? .distantPast, deadline)
        withExtendedLifetime((cancellation, probeCancellation)) {}
    }

    @MainActor
    func testSystemSchedulerFiresPastDeadlinePromptly() {
        let scheduler = SystemActivityScheduler()
        let fired = expectation(description: "Просроченное действие выполнено")

        let cancellation = scheduler.schedule(at: Date().addingTimeInterval(-60)) {
            fired.fulfill()
        }

        wait(for: [fired], timeout: 0.5)
        withExtendedLifetime(cancellation) {}
    }

    @MainActor
    func testSystemSchedulerCancellationIsIdempotentAndPreventsAction() {
        let scheduler = SystemActivityScheduler()
        let probeFired = expectation(description: "Проверка после отменённого deadline выполнена")
        let deadline = Date().addingTimeInterval(0.02)
        var executionCount = 0

        let cancellation = scheduler.schedule(at: deadline) {
            executionCount += 1
        }
        cancellation.cancel()
        cancellation.cancel()
        let probeCancellation = scheduler.schedule(at: deadline.addingTimeInterval(0.04)) {
            probeFired.fulfill()
        }

        wait(for: [probeFired], timeout: 1)

        XCTAssertEqual(executionCount, 0)
        withExtendedLifetime((cancellation, probeCancellation)) {}
    }
}
