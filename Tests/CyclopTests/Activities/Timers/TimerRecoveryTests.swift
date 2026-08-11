import Combine
import Foundation
import XCTest
@testable import Cyclop

@MainActor
final class TimerRecoveryTests: XCTestCase {
    func testStartCompletesExpiredTimerAndPlaysSoundExactlyOnce() throws {
        let expired = runningTimer(id: timerID(1), endsAt: recoveryDate(900))
        let persistence = MemoryTimerPersistence([expired])
        let sound = SpyTimerSoundPlayer(persistence: persistence)
        let store = TimerStore(
            clock: MutableActivityClock(now: recoveryDate(1_000)),
            scheduler: ManualActivityScheduler(),
            persistence: persistence,
            soundPlayer: sound
        )

        try store.start()

        let completed = completedTimer(
            id: expired.id,
            completedAt: recoveryDate(900),
            completionSoundPlayed: true
        )
        XCTAssertEqual(store.timers, [completed])
        XCTAssertEqual(persistence.savedValues, [[completed]])
        XCTAssertEqual(sound.playCount, 1)

        store.stop()
        try store.start()

        XCTAssertEqual(store.timers, [completed])
        XCTAssertEqual(persistence.savedValues, [[completed]])
        XCTAssertEqual(sound.playCount, 1)
    }

    func testStartCompletesRunningTimerAtExactDeadline() throws {
        let due = runningTimer(id: timerID(1), endsAt: recoveryDate(1_000))
        let persistence = MemoryTimerPersistence([due])
        let sound = SpyTimerSoundPlayer(persistence: persistence)
        let store = TimerStore(
            clock: MutableActivityClock(now: recoveryDate(1_000)),
            scheduler: ManualActivityScheduler(),
            persistence: persistence,
            soundPlayer: sound
        )

        try store.start()

        XCTAssertEqual(store.timer(due.id)?.phase, .completed)
        XCTAssertEqual(store.timer(due.id)?.completedAt, recoveryDate(1_000))
        XCTAssertNil(store.timer(due.id)?.endsAt)
        XCTAssertEqual(store.timer(due.id)?.pausedRemaining, 0)
        XCTAssertEqual(store.timer(due.id)?.completionSoundPlayed, true)
        XCTAssertEqual(sound.playCount, 1)
    }

    func testClockJumpCompletesAllDueTimersInOneClaimedBatchAndOnePublish() throws {
        let first = runningTimer(id: timerID(1), name: "Первый", endsAt: recoveryDate(1_100))
        let second = runningTimer(id: timerID(2), name: "Второй", endsAt: recoveryDate(1_200))
        let later = runningTimer(id: timerID(3), name: "Позже", endsAt: recoveryDate(6_000))
        let persistence = MemoryTimerPersistence([first, second, later])
        let clock = MutableActivityClock(now: recoveryDate(1_000))
        let scheduler = ManualActivityScheduler()
        let sound = SpyTimerSoundPlayer(persistence: persistence)
        let store = TimerStore(
            clock: clock,
            scheduler: scheduler,
            persistence: persistence,
            soundPlayer: sound
        )
        try store.start()
        var publications: [[CyclopTimer]] = []
        let observation = store.$timers.dropFirst().sink { publications.append($0) }
        let wake = try XCTUnwrap(scheduler.activeEntries.first)
        clock.advance(by: 3_600)

        wake.action()

        let expected = [
            completedTimer(
                id: first.id,
                name: "Первый",
                completedAt: recoveryDate(1_100),
                completionSoundPlayed: true
            ),
            completedTimer(
                id: second.id,
                name: "Второй",
                completedAt: recoveryDate(1_200),
                completionSoundPlayed: true
            ),
            later,
        ]
        XCTAssertEqual(persistence.savedValues, [expected])
        XCTAssertEqual(publications, [expected])
        XCTAssertEqual(store.timers, expected)
        XCTAssertEqual(sound.playCount, 2)
        XCTAssertEqual(scheduler.activeEntries.map(\.date), [recoveryDate(6_000)])
        XCTAssertEqual(store.health, .available)
        withExtendedLifetime(observation) {}
    }

    func testStartClaimsPendingCompletedTimerBeforeSoundWithoutReplayingClaimedTimer() throws {
        let pending = completedTimer(
            id: timerID(1),
            name: "Ожидает звук",
            completedAt: recoveryDate(900),
            completionSoundPlayed: false
        )
        let claimed = completedTimer(
            id: timerID(2),
            name: "Уже звучал",
            completedAt: recoveryDate(800),
            completionSoundPlayed: true
        )
        let persistence = MemoryTimerPersistence([pending, claimed])
        let sound = SpyTimerSoundPlayer(persistence: persistence)
        let store = TimerStore(
            clock: MutableActivityClock(now: recoveryDate(1_000)),
            scheduler: ManualActivityScheduler(),
            persistence: persistence,
            soundPlayer: sound
        )

        try store.start()

        var expectedPending = pending
        expectedPending.completionSoundPlayed = true
        XCTAssertEqual(persistence.savedValues, [[expectedPending, claimed]])
        XCTAssertEqual(store.timers, [expectedPending, claimed])
        XCTAssertEqual(sound.playCount, 1)
        XCTAssertTrue(sound.persistenceWasClaimedAtEveryPlay)
    }

    func testTransitionAndClaimSaveFailureKeepsRunningStateAndDoesNotPlaySound() throws {
        let due = runningTimer(id: timerID(1), endsAt: recoveryDate(900))
        let persistence = MemoryTimerPersistence([due])
        persistence.saveError = RecoveryPersistenceError.failed
        let sound = SpyTimerSoundPlayer(persistence: persistence)
        let scheduler = ManualActivityScheduler()
        let store = TimerStore(
            clock: MutableActivityClock(now: recoveryDate(1_000)),
            scheduler: scheduler,
            persistence: persistence,
            soundPlayer: sound
        )

        XCTAssertThrowsError(try store.start()) { error in
            XCTAssertEqual(error as? TimerStoreError, .persistenceFailed)
        }

        XCTAssertEqual(store.timers, [due])
        XCTAssertEqual(persistence.stored, [due])
        XCTAssertEqual(persistence.saveCount, 1)
        XCTAssertEqual(persistence.savedValues, [])
        XCTAssertEqual(sound.playCount, 0)
        XCTAssertTrue(scheduler.activeEntries.isEmpty)
        XCTAssertEqual(store.health, .unavailable(message: "Не удалось сохранить таймеры"))

        persistence.saveError = nil
        try store.start()
        XCTAssertEqual(store.timer(due.id)?.phase, .completed)
        XCTAssertEqual(store.timer(due.id)?.completionSoundPlayed, true)
        XCTAssertEqual(sound.playCount, 1)
    }

    func testPendingClaimSaveFailureKeepsUnclaimedStateAndDoesNotPlaySound() throws {
        let pending = completedTimer(
            id: timerID(1),
            completedAt: recoveryDate(900),
            completionSoundPlayed: false
        )
        let persistence = MemoryTimerPersistence([pending])
        persistence.saveError = RecoveryPersistenceError.failed
        let sound = SpyTimerSoundPlayer(persistence: persistence)
        let store = TimerStore(
            clock: MutableActivityClock(now: recoveryDate(1_000)),
            scheduler: ManualActivityScheduler(),
            persistence: persistence,
            soundPlayer: sound
        )

        XCTAssertThrowsError(try store.start()) { error in
            XCTAssertEqual(error as? TimerStoreError, .persistenceFailed)
        }

        XCTAssertEqual(store.timers, [pending])
        XCTAssertEqual(persistence.stored, [pending])
        XCTAssertEqual(persistence.savedValues, [])
        XCTAssertEqual(sound.playCount, 0)
        XCTAssertEqual(store.health, .unavailable(message: "Не удалось сохранить таймеры"))

        persistence.saveError = nil
        try store.start()
        XCTAssertEqual(store.timer(pending.id)?.completionSoundPlayed, true)
        XCTAssertEqual(sound.playCount, 1)
    }

    func testDeadlineClaimsOnlyTimersCompletedByCurrentCallback() throws {
        let pending = completedTimer(
            id: timerID(1),
            name: "Ожидает lifecycle retry",
            completedAt: recoveryDate(900),
            completionSoundPlayed: false
        )
        let persistence = MemoryTimerPersistence([pending])
        persistence.saveError = RecoveryPersistenceError.failed
        let clock = MutableActivityClock(now: recoveryDate(1_000))
        let scheduler = ManualActivityScheduler()
        let sound = SpyTimerSoundPlayer(persistence: persistence)
        let store = TimerStore(
            clock: clock,
            scheduler: scheduler,
            persistence: persistence,
            soundPlayer: sound
        )
        XCTAssertThrowsError(try store.start())
        persistence.saveError = nil
        let newID = try store.create(name: "Новый", duration: 100)
        let wake = try XCTUnwrap(scheduler.activeEntries.first)
        clock.advance(by: 100)

        wake.action()

        let expectedNew = completedTimer(
            id: newID,
            name: "Новый",
            completedAt: recoveryDate(1_100),
            completionSoundPlayed: true
        )
        XCTAssertEqual(store.timers, [pending, expectedNew])
        XCTAssertEqual(persistence.savedValues.last, [pending, expectedNew])
        XCTAssertEqual(sound.playCount, 1)
    }

    func testFailedRecoveryDuringReloadCancelsWakeFromPreviousLoadedState() throws {
        let future = runningTimer(id: timerID(1), endsAt: recoveryDate(1_100))
        let due = runningTimer(id: timerID(2), endsAt: recoveryDate(900))
        let persistence = MemoryTimerPersistence([future])
        let scheduler = ManualActivityScheduler()
        let sound = SpyTimerSoundPlayer(persistence: persistence)
        let store = TimerStore(
            clock: MutableActivityClock(now: recoveryDate(1_000)),
            scheduler: scheduler,
            persistence: persistence,
            soundPlayer: sound
        )
        try store.start()
        let previousWake = try XCTUnwrap(scheduler.activeEntries.first)
        persistence.stored = [due]
        persistence.saveError = RecoveryPersistenceError.failed

        XCTAssertThrowsError(try store.start()) { error in
            XCTAssertEqual(error as? TimerStoreError, .persistenceFailed)
        }

        XCTAssertTrue(previousWake.cancellation.isCancelled)
        XCTAssertTrue(scheduler.activeEntries.isEmpty)
        XCTAssertEqual(store.timers, [due])
        XCTAssertEqual(persistence.stored, [due])
        XCTAssertEqual(sound.playCount, 0)
        XCTAssertEqual(store.health, .unavailable(message: "Не удалось сохранить таймеры"))
    }

    func testFailedLoadDoesNotWriteOrPlaySoundUntilSuccessfulReload() throws {
        let due = runningTimer(id: timerID(1), endsAt: recoveryDate(900))
        let persistence = MemoryTimerPersistence([due])
        persistence.loadError = RecoveryPersistenceError.failed
        let sound = SpyTimerSoundPlayer(persistence: persistence)
        let store = TimerStore(
            clock: MutableActivityClock(now: recoveryDate(1_000)),
            scheduler: ManualActivityScheduler(),
            persistence: persistence,
            soundPlayer: sound
        )

        XCTAssertThrowsError(try store.start()) { error in
            XCTAssertEqual(error as? TimerStoreError, .persistenceFailed)
        }
        XCTAssertEqual(persistence.saveCount, 0)
        XCTAssertEqual(sound.playCount, 0)
        XCTAssertEqual(store.timers, [])
        XCTAssertEqual(store.health, .unavailable(message: "Не удалось загрузить таймеры"))

        persistence.loadError = nil
        try store.start()

        XCTAssertEqual(persistence.saveCount, 1)
        XCTAssertEqual(store.timer(due.id)?.phase, .completed)
        XCTAssertEqual(store.timer(due.id)?.completionSoundPlayed, true)
        XCTAssertEqual(sound.playCount, 1)
    }

    func testResumeWithZeroRemainingCompletesInOneClaimedPublishWithoutRunningState() throws {
        let paused = CyclopTimer(
            id: timerID(1),
            name: "Нулевая пауза",
            originalDuration: 100,
            phase: .paused,
            endsAt: nil,
            pausedRemaining: 0,
            completedAt: nil,
            completionSoundPlayed: false
        )
        let persistence = MemoryTimerPersistence([paused])
        let sound = SpyTimerSoundPlayer(persistence: persistence)
        let store = TimerStore(
            clock: MutableActivityClock(now: recoveryDate(1_000)),
            scheduler: ManualActivityScheduler(),
            persistence: persistence,
            soundPlayer: sound
        )
        try store.start()
        var publications: [[CyclopTimer]] = []
        let observation = store.$timers.dropFirst().sink { publications.append($0) }

        try store.resume(paused.id)

        let completed = completedTimer(
            id: paused.id,
            name: paused.name,
            completedAt: recoveryDate(1_000),
            completionSoundPlayed: true
        )
        XCTAssertEqual(store.timers, [completed])
        XCTAssertEqual(persistence.stored, [completed])
        XCTAssertEqual(persistence.savedValues, [[completed]])
        XCTAssertEqual(publications, [[completed]])
        XCTAssertEqual(sound.playCount, 1)
        XCTAssertTrue(sound.persistenceWasClaimedAtEveryPlay)
        withExtendedLifetime(observation) {}
    }

    func testOverduePauseCompletesEveryDueTimerInOneClaimedBatchAndPublish() throws {
        let first = runningTimer(id: timerID(1), name: "Первый", endsAt: recoveryDate(1_100))
        let second = runningTimer(id: timerID(2), name: "Второй", endsAt: recoveryDate(1_200))
        let persistence = MemoryTimerPersistence([first, second])
        let clock = MutableActivityClock(now: recoveryDate(1_000))
        let sound = SpyTimerSoundPlayer(persistence: persistence)
        let store = TimerStore(
            clock: clock,
            scheduler: ManualActivityScheduler(),
            persistence: persistence,
            soundPlayer: sound
        )
        try store.start()
        var publications: [[CyclopTimer]] = []
        let observation = store.$timers.dropFirst().sink { publications.append($0) }
        clock.advance(by: 300)

        try store.pause(first.id)

        let expected = [
            completedTimer(
                id: first.id,
                name: first.name,
                completedAt: recoveryDate(1_100),
                completionSoundPlayed: true
            ),
            completedTimer(
                id: second.id,
                name: second.name,
                completedAt: recoveryDate(1_200),
                completionSoundPlayed: true
            ),
        ]
        XCTAssertEqual(store.timers, expected)
        XCTAssertEqual(persistence.stored, expected)
        XCTAssertEqual(persistence.savedValues, [expected])
        XCTAssertEqual(publications, [expected])
        XCTAssertEqual(sound.playCount, 2)
        XCTAssertTrue(sound.persistenceWasClaimedAtEveryPlay)
        withExtendedLifetime(observation) {}
    }

    func testFailedDeadlineSaveThenRecoveredPauseRetriesCompletion() throws {
        try assertFailedDeadlineThenActionRetriesCompletion(.pause)
    }

    func testFailedDeadlineSaveThenRecoveredCancelRetriesCompletion() throws {
        try assertFailedDeadlineThenActionRetriesCompletion(.cancel)
    }

    private func assertFailedDeadlineThenActionRetriesCompletion(
        _ action: RecoveryAction
    ) throws {
        let due = runningTimer(id: timerID(1), endsAt: recoveryDate(1_100))
        let persistence = MemoryTimerPersistence([due])
        let clock = MutableActivityClock(now: recoveryDate(1_000))
        let scheduler = ManualActivityScheduler()
        let sound = SpyTimerSoundPlayer(persistence: persistence)
        let store = TimerStore(
            clock: clock,
            scheduler: scheduler,
            persistence: persistence,
            soundPlayer: sound
        )
        try store.start()
        let wake = try XCTUnwrap(scheduler.activeEntries.first)
        clock.advance(by: 200)
        persistence.saveError = RecoveryPersistenceError.failed

        wake.action()
        XCTAssertEqual(store.timers, [due])
        XCTAssertEqual(persistence.stored, [due])
        XCTAssertEqual(sound.playCount, 0)

        XCTAssertThrowsError(try perform(action, on: due.id, in: store)) { error in
            XCTAssertEqual(error as? TimerStoreError, .persistenceFailed)
        }
        XCTAssertEqual(store.timers, [due])
        XCTAssertEqual(persistence.stored, [due])
        XCTAssertEqual(sound.playCount, 0)
        XCTAssertEqual(store.health, .unavailable(message: "Не удалось сохранить таймеры"))

        persistence.saveError = nil
        try perform(action, on: due.id, in: store)

        let completed = completedTimer(
            id: due.id,
            completedAt: recoveryDate(1_100),
            completionSoundPlayed: true
        )
        XCTAssertEqual(store.timers, [completed])
        XCTAssertEqual(persistence.stored, [completed])
        XCTAssertEqual(persistence.savedValues, [[completed]])
        XCTAssertEqual(sound.playCount, 1)
        XCTAssertTrue(sound.persistenceWasClaimedAtEveryPlay)
        XCTAssertEqual(store.health, .available)
    }

    private func perform(
        _ action: RecoveryAction,
        on id: UUID,
        in store: TimerStore
    ) throws {
        switch action {
        case .pause:
            try store.pause(id)
        case .cancel:
            try store.cancel(id)
        }
    }
}

private enum RecoveryAction {
    case pause
    case cancel
}

private final class SpyTimerSoundPlayer: TimerSoundPlaying {
    private let persistence: MemoryTimerPersistence?
    private(set) var playCount = 0
    private(set) var persistenceWasClaimedAtEveryPlay = true

    init(persistence: MemoryTimerPersistence? = nil) {
        self.persistence = persistence
    }

    func playCompletion() {
        playCount += 1
        if let persistence {
            persistenceWasClaimedAtEveryPlay = persistenceWasClaimedAtEveryPlay
                && persistence.stored
                    .filter { $0.phase == .completed }
                    .allSatisfy(\.completionSoundPlayed)
        }
    }
}

private enum RecoveryPersistenceError: Error {
    case failed
}

private func recoveryDate(_ seconds: TimeInterval) -> Date {
    Date(timeIntervalSince1970: seconds)
}

private func timerID(_ suffix: Int) -> UUID {
    UUID(uuidString: String(format: "10000000-0000-0000-0000-%012d", suffix))!
}

private func runningTimer(
    id: UUID,
    name: String = "Таймер",
    endsAt: Date
) -> CyclopTimer {
    CyclopTimer(
        id: id,
        name: name,
        originalDuration: 100,
        phase: .running,
        endsAt: endsAt,
        pausedRemaining: nil,
        completedAt: nil,
        completionSoundPlayed: false
    )
}

private func completedTimer(
    id: UUID,
    name: String = "Таймер",
    completedAt: Date,
    completionSoundPlayed: Bool
) -> CyclopTimer {
    CyclopTimer(
        id: id,
        name: name,
        originalDuration: 100,
        phase: .completed,
        endsAt: nil,
        pausedRemaining: 0,
        completedAt: completedAt,
        completionSoundPlayed: completionSoundPlayed
    )
}
