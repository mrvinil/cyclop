import Combine
import Foundation
import XCTest
@testable import Cyclop

@MainActor
final class TimerCountdownTests: XCTestCase {
    func testHiddenCountdownSchedulesOnlyNearestDeadline() throws {
        let (store, _, scheduler, _) = try makeStartedStore(now: 1_000.25)

        _ = try store.create(name: "Фокус", duration: 600)

        XCTAssertEqual(store.countdownRevision, 0)
        XCTAssertEqual(scheduler.activeEntries.map(\.date), [countdownDate(1_600.25)])
    }

    func testVisibleCountdownSchedulesSinglePulseAtStrictNextWholeSecond() throws {
        let (store, _, scheduler, _) = try makeStartedStore(now: 1_000)
        _ = try store.create(name: "Фокус", duration: 600)

        store.setCountdownVisible(true)

        XCTAssertEqual(scheduler.activeEntries.count, 1)
        XCTAssertEqual(scheduler.activeEntries.map(\.date), [countdownDate(1_001)])
    }

    func testVisibleCountdownUsesEarlierDeadlineInsteadOfPulse() throws {
        let clock = MutableActivityClock(now: countdownDate(1_000.25))
        let scheduler = ManualActivityScheduler()
        let store = TimerStore(
            clock: clock,
            scheduler: scheduler,
            persistence: MemoryTimerPersistence([
                runningTimer(endsAt: countdownDate(1_000.5)),
            ])
        )
        try store.start()

        store.setCountdownVisible(true)

        XCTAssertEqual(scheduler.activeEntries.count, 1)
        XCTAssertEqual(scheduler.activeEntries.map(\.date), [countdownDate(1_000.5)])
    }

    func testVisibleCountdownSetBeforeStartSchedulesPulseForLaterRunningTimer() throws {
        let clock = MutableActivityClock(now: countdownDate(1_000.25))
        let scheduler = ManualActivityScheduler()
        let store = TimerStore(
            clock: clock,
            scheduler: scheduler,
            persistence: MemoryTimerPersistence([
                runningTimer(endsAt: countdownDate(1_600.25)),
            ])
        )

        store.setCountdownVisible(true)
        try store.start()

        XCTAssertEqual(scheduler.activeEntries.count, 1)
        XCTAssertEqual(scheduler.activeEntries.map(\.date), [countdownDate(1_001)])
    }

    func testRepeatedVisibilityDoesNotRescheduleWake() throws {
        let (store, _, scheduler, _) = try makeStartedStore(now: 1_000.25)
        _ = try store.create(name: "Фокус", duration: 600)

        store.setCountdownVisible(true)
        let visibleWake = try XCTUnwrap(scheduler.activeEntries.first)
        let entryCount = scheduler.entries.count
        store.setCountdownVisible(true)
        store.setCountdownVisible(false)
        let hiddenWake = try XCTUnwrap(scheduler.activeEntries.first)
        let hiddenEntryCount = scheduler.entries.count
        store.setCountdownVisible(false)

        XCTAssertEqual(scheduler.entries.count, hiddenEntryCount)
        XCTAssertEqual(hiddenEntryCount, entryCount + 1)
        XCTAssertTrue(visibleWake.cancellation.isCancelled)
        XCTAssertFalse(hiddenWake.cancellation.isCancelled)
        XCTAssertEqual(hiddenWake.date, countdownDate(1_600.25))
    }

    func testHidingCountdownCancelsPulseAndRestoresDeadlineWake() throws {
        let (store, _, scheduler, _) = try makeStartedStore(now: 1_000.25)
        _ = try store.create(name: "Фокус", duration: 600)
        store.setCountdownVisible(true)
        let pulseWake = try XCTUnwrap(scheduler.activeEntries.first)

        store.setCountdownVisible(false)

        XCTAssertTrue(pulseWake.cancellation.isCancelled)
        XCTAssertEqual(scheduler.activeEntries.count, 1)
        XCTAssertEqual(scheduler.activeEntries.map(\.date), [countdownDate(1_600.25)])
    }

    func testVisibleCountdownWithNoRunningTimersLeavesSchedulerEmpty() throws {
        let (store, _, scheduler, _) = try makeStartedStore(now: 1_000.25)
        let id = try store.create(name: "Фокус", duration: 600)

        try store.pause(id)
        store.setCountdownVisible(true)

        XCTAssertTrue(scheduler.activeEntries.isEmpty)
    }

    func testPulseIncrementsRevisionWithoutPersistenceTimerPublishHealthOrSound() throws {
        let sound = CountingSoundPlayer()
        let (store, clock, scheduler, persistence) = try makeStartedStore(now: 1_000.25, soundPlayer: sound)
        _ = try store.create(name: "Фокус", duration: 600)
        var timerPublications: [[CyclopTimer]] = []
        let observation = store.$timers.dropFirst().sink { timerPublications.append($0) }
        let savesBeforePulse = persistence.saveCount
        store.setCountdownVisible(true)
        let pulseWake = try XCTUnwrap(scheduler.activeEntries.first)
        clock.advance(by: 0.75)

        pulseWake.action()

        XCTAssertEqual(store.countdownRevision, 1)
        XCTAssertEqual(persistence.saveCount, savesBeforePulse)
        XCTAssertEqual(timerPublications, [])
        XCTAssertEqual(store.health, .available)
        XCTAssertEqual(sound.playCount, 0)
        XCTAssertEqual(scheduler.activeEntries.map(\.date), [countdownDate(1_002)])
        withExtendedLifetime(observation) {}
    }

    func testPulseAtDeadlineBoundaryIncrementsRevisionAndCompletesTimer() throws {
        let (store, clock, scheduler, persistence) = try makeStartedStore(now: 1_000)
        let id = try store.create(name: "Фокус", duration: 1)
        store.setCountdownVisible(true)
        let wake = try XCTUnwrap(scheduler.activeEntries.first)
        clock.advance(by: 1)

        wake.action()

        XCTAssertEqual(store.countdownRevision, 1)
        XCTAssertEqual(store.timer(id)?.phase, .completed)
        XCTAssertEqual(persistence.saveCount, 2)
        XCTAssertTrue(scheduler.activeEntries.isEmpty)
    }

    func testStalePulseCallbackCannotChangeRevisionOrReplaceDeadlineWake() throws {
        let (store, _, scheduler, persistence) = try makeStartedStore(now: 1_000.25)
        _ = try store.create(name: "Фокус", duration: 600)
        store.setCountdownVisible(true)
        let stalePulse = try XCTUnwrap(scheduler.activeEntries.first)
        store.setCountdownVisible(false)
        let deadlineWake = try XCTUnwrap(scheduler.activeEntries.first)
        let entryCount = scheduler.entries.count
        let saveCount = persistence.saveCount

        stalePulse.action()

        XCTAssertTrue(stalePulse.cancellation.isCancelled)
        XCTAssertFalse(deadlineWake.cancellation.isCancelled)
        XCTAssertEqual(store.countdownRevision, 0)
        XCTAssertEqual(scheduler.entries.count, entryCount)
        XCTAssertTrue(scheduler.activeEntries.first?.cancellation === deadlineWake.cancellation)
        XCTAssertEqual(persistence.saveCount, saveCount)
    }

    private func makeStartedStore(
        now: TimeInterval,
        soundPlayer: TimerSoundPlaying? = nil
    ) throws -> (
        TimerStore,
        MutableActivityClock,
        ManualActivityScheduler,
        MemoryTimerPersistence
    ) {
        let clock = MutableActivityClock(now: countdownDate(now))
        let scheduler = ManualActivityScheduler()
        let persistence = MemoryTimerPersistence()
        let store = TimerStore(
            clock: clock,
            scheduler: scheduler,
            persistence: persistence,
            soundPlayer: soundPlayer
        )
        try store.start()
        return (store, clock, scheduler, persistence)
    }

    private func runningTimer(endsAt: Date) -> CyclopTimer {
        CyclopTimer(
            id: UUID(uuidString: "20000000-0000-0000-0000-000000000001")!,
            name: "Фокус",
            originalDuration: 600,
            phase: .running,
            endsAt: endsAt,
            pausedRemaining: nil,
            completedAt: nil,
            completionSoundPlayed: false
        )
    }
}

private final class CountingSoundPlayer: TimerSoundPlaying {
    private(set) var playCount = 0

    func playCompletion() {
        playCount += 1
    }
}

private func countdownDate(_ seconds: TimeInterval) -> Date {
    Date(timeIntervalSince1970: seconds)
}
