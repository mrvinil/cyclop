import Combine
import Foundation
import XCTest
@testable import Cyclop

@MainActor
final class TimerStoreTests: XCTestCase {
    func testLifecycleUsesWallClockDeadlinesAndPersistsExactFields() throws {
        let clock = MutableActivityClock(now: date(1_000))
        let persistence = MemoryTimerPersistence()
        let store = TimerStore(
            clock: clock,
            scheduler: ManualActivityScheduler(),
            persistence: persistence
        )
        try store.start()

        let id = try store.create(name: "Фокус", duration: 600)
        XCTAssertEqual(
            store.timer(id),
            timer(
                id: id,
                name: "Фокус",
                duration: 600,
                phase: .running,
                endsAt: date(1_600)
            )
        )

        clock.advance(by: 100)
        try store.pause(id)
        XCTAssertEqual(
            store.timer(id),
            timer(
                id: id,
                name: "Фокус",
                duration: 600,
                phase: .paused,
                pausedRemaining: 500
            )
        )

        clock.advance(by: 50)
        try store.resume(id)
        XCTAssertEqual(
            store.timer(id),
            timer(
                id: id,
                name: "Фокус",
                duration: 600,
                phase: .running,
                endsAt: date(1_650)
            )
        )

        try store.cancel(id)
        XCTAssertEqual(
            store.timer(id),
            timer(
                id: id,
                name: "Фокус",
                duration: 600,
                phase: .cancelled,
                pausedRemaining: 0
            )
        )
        XCTAssertEqual(persistence.savedValues.count, 4)
        XCTAssertEqual(persistence.stored, store.timers)
    }

    func testCreateValidatesFiniteInclusiveDurationAndDefaultsBlankName() throws {
        let (store, _, scheduler, persistence) = try makeStartedStore()

        let lowerID = try store.create(name: "", duration: 1)
        let upperID = try store.create(name: " \n\t ", duration: 359_999)

        XCTAssertEqual(store.timer(lowerID)?.name, "Таймер")
        XCTAssertEqual(store.timer(lowerID)?.originalDuration, 1)
        XCTAssertEqual(store.timer(upperID)?.name, "Таймер")
        XCTAssertEqual(store.timer(upperID)?.originalDuration, 359_999)
        XCTAssertEqual(persistence.savedValues.count, 2)
        XCTAssertEqual(scheduler.activeEntries.count, 1)

        let invalidDurations: [TimeInterval] = [
            -.infinity,
            -1,
            0,
            0.999,
            359_999.001,
            360_000,
            .infinity,
            .nan,
        ]
        let timersBeforeFailures = store.timers
        let savesBeforeFailures = persistence.savedValues.count
        let scheduledBeforeFailures = scheduler.activeEntries.map(\.date)

        for duration in invalidDurations {
            XCTAssertThrowsError(try store.create(name: "Ошибка", duration: duration)) { error in
                XCTAssertEqual(error as? TimerStoreError, .invalidDuration)
            }
        }

        XCTAssertEqual(store.timers, timersBeforeFailures)
        XCTAssertEqual(persistence.savedValues.count, savesBeforeFailures)
        XCTAssertEqual(scheduler.activeEntries.map(\.date), scheduledBeforeFailures)
    }

    func testRemainingIsDerivedFromClockForRunningAndPausedTimers() throws {
        let clock = MutableActivityClock(now: date(1_000))
        let store = TimerStore(
            clock: clock,
            scheduler: ManualActivityScheduler(),
            persistence: MemoryTimerPersistence()
        )
        try store.start()
        let id = try store.create(name: "Фокус", duration: 100)

        XCTAssertEqual(store.remaining(for: id), 100)
        clock.advance(by: 35)
        XCTAssertEqual(store.remaining(for: id), 65)
        clock.advance(by: 80)
        XCTAssertEqual(store.remaining(for: id), 0)

        try store.pause(id)
        XCTAssertEqual(store.remaining(for: id), 0)
        clock.advance(by: 500)
        XCTAssertEqual(store.remaining(for: id), 0)
        XCTAssertNil(store.remaining(for: unknownID))
    }

    func testPublishesTimerMutationOnlyAfterPersistenceSucceeds() throws {
        let (store, _, _, persistence) = try makeStartedStore()
        var persistenceWasCurrentAtPublish: [Bool] = []
        let observation = store.$timers
            .dropFirst()
            .sink { timers in
                persistenceWasCurrentAtPublish.append(persistence.stored == timers)
            }

        _ = try store.create(name: "Фокус", duration: 60)

        XCTAssertEqual(persistenceWasCurrentAtPublish, [true])
        withExtendedLifetime(observation) {}
    }

    func testStartRecoversExpiredTimerAndSchedulesNearestFutureDeadline() throws {
        let stored = [
            timer(id: id(1), name: "Позже", duration: 500, phase: .running, endsAt: date(1_300)),
            timer(id: id(2), name: "Пауза", duration: 500, phase: .paused, pausedRemaining: 120),
            timer(id: id(3), name: "Раньше", duration: 500, phase: .running, endsAt: date(900)),
            timer(
                id: id(4),
                name: "Готово",
                duration: 500,
                phase: .completed,
                pausedRemaining: 0,
                completedAt: date(800)
            ),
        ]
        let persistence = MemoryTimerPersistence(stored)
        let scheduler = ManualActivityScheduler()
        let store = TimerStore(
            clock: MutableActivityClock(now: date(1_000)),
            scheduler: scheduler,
            persistence: persistence
        )

        try store.start()

        let recovered = [
            stored[0],
            stored[1],
            timer(
                id: id(3),
                name: "Раньше",
                duration: 500,
                phase: .completed,
                pausedRemaining: 0,
                completedAt: date(900)
            ),
            stored[3],
        ]
        XCTAssertEqual(store.timers, recovered)
        XCTAssertEqual(persistence.savedValues, [recovered])
        XCTAssertEqual(scheduler.activeEntries.map(\.date), [date(1_300)])
        XCTAssertEqual(store.health, .available)
    }

    func testStopCancelsWakeAndSubsequentStartReloadsAndReschedules() throws {
        let first = timer(
            id: id(1),
            name: "Первый",
            duration: 100,
            phase: .running,
            endsAt: date(1_100)
        )
        let second = timer(
            id: id(2),
            name: "Второй",
            duration: 200,
            phase: .running,
            endsAt: date(1_200)
        )
        let persistence = MemoryTimerPersistence([first])
        let scheduler = ManualActivityScheduler()
        let store = TimerStore(
            clock: MutableActivityClock(now: date(1_000)),
            scheduler: scheduler,
            persistence: persistence
        )
        try store.start()
        let firstWake = try XCTUnwrap(scheduler.activeEntries.first)

        store.stop()
        store.stop()

        XCTAssertTrue(firstWake.cancellation.isCancelled)
        XCTAssertTrue(scheduler.activeEntries.isEmpty)
        XCTAssertEqual(store.timers, [first])

        persistence.stored = [second]
        try store.start()

        XCTAssertEqual(persistence.loadCount, 2)
        XCTAssertEqual(store.timers, [second])
        XCTAssertEqual(scheduler.activeEntries.map(\.date), [date(1_200)])
    }

    func testStopKeepsSuccessfulLoadWriteGateOpenWithoutSchedulingNewWake() throws {
        let (store, _, scheduler, persistence) = try makeStartedStore()
        store.stop()

        let id = try store.create(name: "После stop", duration: 60)

        XCTAssertEqual(persistence.saveCount, 1)
        XCTAssertEqual(store.timer(id)?.phase, .running)
        XCTAssertTrue(scheduler.activeEntries.isEmpty)
    }

    func testFailedReloadPreservesPublishedTimersAndActiveWake() throws {
        let original = timer(
            id: id(1),
            name: "Исходный",
            duration: 100,
            phase: .running,
            endsAt: date(1_100)
        )
        let persistence = MemoryTimerPersistence([original])
        let scheduler = ManualActivityScheduler()
        let store = TimerStore(
            clock: MutableActivityClock(now: date(1_000)),
            scheduler: scheduler,
            persistence: persistence
        )
        try store.start()
        let originalWake = try XCTUnwrap(scheduler.activeEntries.first)
        persistence.stored = []
        persistence.loadError = PersistenceDoubleError.failed

        XCTAssertThrowsError(try store.start()) { error in
            XCTAssertEqual(error as? TimerStoreError, .persistenceFailed)
        }

        XCTAssertEqual(store.timers, [original])
        XCTAssertFalse(originalWake.cancellation.isCancelled)
        XCTAssertEqual(scheduler.activeEntries.count, 1)
        XCTAssertEqual(store.health, .unavailable(message: "Не удалось загрузить таймеры"))

        persistence.loadError = nil
        try store.start()
        XCTAssertEqual(store.timers, [])
        XCTAssertTrue(scheduler.activeEntries.isEmpty)
        XCTAssertEqual(store.health, .available)
    }

    func testFailedLoadBlocksWritesUntilSuccessfulReload() throws {
        let persisted = timer(
            id: id(1),
            name: "Не перезаписывать",
            duration: 100,
            phase: .paused,
            pausedRemaining: 40
        )
        let persistence = MemoryTimerPersistence([persisted])
        persistence.loadError = PersistenceDoubleError.failed
        let scheduler = ManualActivityScheduler()
        let store = TimerStore(
            clock: MutableActivityClock(now: date(1_000)),
            scheduler: scheduler,
            persistence: persistence
        )

        XCTAssertThrowsError(try store.start()) { error in
            XCTAssertEqual(error as? TimerStoreError, .persistenceFailed)
        }
        XCTAssertThrowsError(try store.create(name: "Новый", duration: 60)) { error in
            XCTAssertEqual(error as? TimerStoreError, .persistenceFailed)
        }

        XCTAssertEqual(persistence.saveCount, 0)
        XCTAssertEqual(persistence.stored, [persisted])
        XCTAssertEqual(store.timers, [])
        XCTAssertTrue(scheduler.activeEntries.isEmpty)
        XCTAssertEqual(store.health, .unavailable(message: "Не удалось загрузить таймеры"))

        persistence.loadError = nil
        try store.start()
        let createdID = try store.create(name: "Новый", duration: 60)

        XCTAssertEqual(persistence.saveCount, 1)
        XCTAssertEqual(store.timer(createdID)?.phase, .running)
        XCTAssertEqual(store.health, .available)
    }

    func testFailedReloadBlocksDueReconcileWithoutReplacingLoadHealth() throws {
        let clock = MutableActivityClock(now: date(1_000))
        let dueLater = timer(
            id: id(1),
            name: "Не завершать после load error",
            duration: 100,
            phase: .running,
            endsAt: date(1_100)
        )
        let persistence = MemoryTimerPersistence([dueLater])
        let scheduler = ManualActivityScheduler()
        let store = TimerStore(clock: clock, scheduler: scheduler, persistence: persistence)
        try store.start()
        let wake = try XCTUnwrap(scheduler.activeEntries.first)
        persistence.loadError = PersistenceDoubleError.failed
        XCTAssertThrowsError(try store.start())
        clock.advance(by: 200)

        wake.action()

        XCTAssertEqual(persistence.saveCount, 0)
        XCTAssertEqual(store.timers, [dueLater])
        XCTAssertTrue(scheduler.activeEntries.isEmpty)
        XCTAssertEqual(store.health, .unavailable(message: "Не удалось загрузить таймеры"))
    }

    func testEveryPhaseAcceptsOnlyItsDocumentedTransitions() throws {
        let clock = MutableActivityClock(now: date(1_000))
        let running = timer(
            id: id(1),
            name: "Работает",
            duration: 100,
            phase: .running,
            endsAt: date(1_100)
        )
        let paused = timer(
            id: id(2),
            name: "Пауза",
            duration: 200,
            phase: .paused,
            pausedRemaining: 75
        )
        let completed = timer(
            id: id(3),
            name: "Готово",
            duration: 300,
            phase: .completed,
            pausedRemaining: 0,
            completedAt: date(950),
            completionSoundPlayed: true
        )
        let cancelled = timer(
            id: id(4),
            name: "Отменён",
            duration: 400,
            phase: .cancelled,
            pausedRemaining: 0
        )
        let completedForDismiss = timer(
            id: id(5),
            name: "Скрыть готовый",
            duration: 500,
            phase: .completed,
            pausedRemaining: 0,
            completedAt: date(925)
        )
        let persistence = MemoryTimerPersistence([
            running,
            paused,
            completed,
            cancelled,
            completedForDismiss,
        ])
        let store = TimerStore(
            clock: clock,
            scheduler: ManualActivityScheduler(),
            persistence: persistence
        )
        try store.start()

        try store.pause(running.id)
        XCTAssertEqual(store.timer(running.id)?.phase, .paused)
        try store.resume(running.id)
        XCTAssertEqual(store.timer(running.id)?.phase, .running)
        try store.cancel(running.id)
        XCTAssertEqual(store.timer(running.id)?.phase, .cancelled)

        try store.resume(paused.id)
        XCTAssertEqual(store.timer(paused.id)?.phase, .running)
        try store.cancel(paused.id)
        XCTAssertEqual(store.timer(paused.id)?.phase, .cancelled)

        try store.restart(completed.id)
        XCTAssertEqual(
            store.timer(completed.id),
            timer(
                id: completed.id,
                name: "Готово",
                duration: 300,
                phase: .running,
                endsAt: date(1_300)
            )
        )
        try store.dismiss(cancelled.id)
        XCTAssertNil(store.timer(cancelled.id))
        try store.dismiss(completedForDismiss.id)
        XCTAssertNil(store.timer(completedForDismiss.id))

        try store.dismiss(running.id)
        try store.restart(paused.id)
        XCTAssertEqual(
            store.timer(paused.id),
            timer(
                id: paused.id,
                name: "Пауза",
                duration: 200,
                phase: .running,
                endsAt: date(1_200)
            )
        )
    }

    func testInvalidTransitionMatrixDoesNotPersistOrReschedule() throws {
        let phases: [(TimerPhase, CyclopTimer)] = [
            (
                .running,
                timer(
                    id: id(1),
                    name: "Работает",
                    duration: 100,
                    phase: .running,
                    endsAt: date(1_100)
                )
            ),
            (
                .paused,
                timer(
                    id: id(2),
                    name: "Пауза",
                    duration: 100,
                    phase: .paused,
                    pausedRemaining: 50
                )
            ),
            (
                .completed,
                timer(
                    id: id(3),
                    name: "Готово",
                    duration: 100,
                    phase: .completed,
                    pausedRemaining: 0,
                    completedAt: date(900)
                )
            ),
            (
                .cancelled,
                timer(
                    id: id(4),
                    name: "Отменён",
                    duration: 100,
                    phase: .cancelled,
                    pausedRemaining: 0
                )
            ),
        ]
        for (phase, record) in phases {
            for action in invalidActions(for: phase) {
                let persistence = MemoryTimerPersistence([record])
                let scheduler = ManualActivityScheduler()
                let store = TimerStore(
                    clock: MutableActivityClock(now: date(1_000)),
                    scheduler: scheduler,
                    persistence: persistence
                )
                try store.start()
                let timersBeforeAction = store.timers
                let activeDatesBeforeAction = scheduler.activeEntries.map(\.date)

                XCTAssertThrowsError(try perform(action, on: record.id, in: store)) { error in
                    XCTAssertEqual(error as? TimerStoreError, .invalidTransition)
                }
                XCTAssertEqual(store.timers, timersBeforeAction, "phase=\(phase), action=\(action)")
                XCTAssertEqual(persistence.savedValues, [], "phase=\(phase), action=\(action)")
                XCTAssertEqual(
                    scheduler.activeEntries.map(\.date),
                    activeDatesBeforeAction,
                    "phase=\(phase), action=\(action)"
                )
            }
        }
    }

    func testUnknownIDReturnsTypedErrorForEveryMutationWithoutSideEffects() throws {
        let (store, _, scheduler, persistence) = try makeStartedStore()
        let actions: [TimerAction] = [.pause, .resume, .cancel, .dismiss, .restart]

        for action in actions {
            let timersBeforeAction = store.timers
            let activeDatesBeforeAction = scheduler.activeEntries.map(\.date)

            XCTAssertThrowsError(try perform(action, on: unknownID, in: store)) { error in
                XCTAssertEqual(error as? TimerStoreError, .timerNotFound)
            }
            XCTAssertEqual(store.timers, timersBeforeAction)
            XCTAssertEqual(persistence.savedValues, [])
            XCTAssertEqual(scheduler.activeEntries.map(\.date), activeDatesBeforeAction)
        }
    }

    func testSaveFailureDoesNotPublishOrChangeScheduleAndSuccessfulRetryRestoresHealth() throws {
        let existing = timer(
            id: id(1),
            name: "Фокус",
            duration: 100,
            phase: .running,
            endsAt: date(1_100)
        )
        let persistence = MemoryTimerPersistence([existing])
        let scheduler = ManualActivityScheduler()
        let store = TimerStore(
            clock: MutableActivityClock(now: date(1_000)),
            scheduler: scheduler,
            persistence: persistence
        )
        try store.start()
        let originalWake = try XCTUnwrap(scheduler.activeEntries.first)
        persistence.saveError = PersistenceDoubleError.failed
        var timerPublications: [[CyclopTimer]] = []
        let observation = store.$timers.dropFirst().sink { timerPublications.append($0) }

        XCTAssertThrowsError(try store.pause(existing.id)) { error in
            XCTAssertEqual(error as? TimerStoreError, .persistenceFailed)
        }

        XCTAssertEqual(store.timers, [existing])
        XCTAssertEqual(persistence.stored, [existing])
        XCTAssertEqual(persistence.savedValues, [])
        XCTAssertEqual(timerPublications, [])
        XCTAssertFalse(originalWake.cancellation.isCancelled)
        XCTAssertEqual(scheduler.activeEntries.count, 1)
        XCTAssertEqual(store.health, .unavailable(message: "Не удалось сохранить таймеры"))

        persistence.saveError = nil
        try store.pause(existing.id)
        XCTAssertEqual(store.timer(existing.id)?.phase, .paused)
        XCTAssertTrue(scheduler.activeEntries.isEmpty)
        XCTAssertEqual(store.health, .available)
        withExtendedLifetime(observation) {}
    }

    func testFailedCreateDoesNotPublishOrScheduleUnsavedTimer() throws {
        let (store, _, scheduler, persistence) = try makeStartedStore()
        persistence.saveError = PersistenceDoubleError.failed

        XCTAssertThrowsError(try store.create(name: "Не сохранится", duration: 60)) { error in
            XCTAssertEqual(error as? TimerStoreError, .persistenceFailed)
        }

        XCTAssertEqual(store.timers, [])
        XCTAssertEqual(persistence.stored, [])
        XCTAssertTrue(scheduler.activeEntries.isEmpty)
        XCTAssertEqual(store.health, .unavailable(message: "Не удалось сохранить таймеры"))
    }

    func testMultipleTimersUseOnlyNearestCancellationSafeWake() throws {
        let (store, _, scheduler, persistence) = try makeStartedStore()
        _ = try store.create(name: "Позже", duration: 300)
        let staleWake = try XCTUnwrap(scheduler.entries.last)
        _ = try store.create(name: "Раньше", duration: 100)
        let currentWake = try XCTUnwrap(scheduler.activeEntries.first)
        let entryCountBeforeStaleAction = scheduler.entries.count
        let saveCountBeforeStaleAction = persistence.saveCount
        var timerPublications: [[CyclopTimer]] = []
        let observation = store.$timers.dropFirst().sink { timerPublications.append($0) }

        XCTAssertTrue(staleWake.cancellation.isCancelled)
        XCTAssertEqual(scheduler.activeEntries.map(\.date), [date(1_100)])

        staleWake.action()

        XCTAssertFalse(currentWake.cancellation.isCancelled)
        XCTAssertEqual(scheduler.entries.count, entryCountBeforeStaleAction)
        XCTAssertTrue(scheduler.activeEntries.first?.cancellation === currentWake.cancellation)
        XCTAssertEqual(persistence.saveCount, saveCountBeforeStaleAction)
        XCTAssertEqual(timerPublications, [])
        XCTAssertEqual(store.timers.map(\.phase), [.running, .running])
        XCTAssertEqual(scheduler.activeEntries.map(\.date), [date(1_100)])
        withExtendedLifetime(observation) {}
    }

    func testDeadlineWakeCompletesExactBoundaryInOnePersistenceTransitionAndPublish() throws {
        let clock = MutableActivityClock(now: date(1_000))
        let persistence = MemoryTimerPersistence()
        let scheduler = ManualActivityScheduler()
        let store = TimerStore(clock: clock, scheduler: scheduler, persistence: persistence)
        try store.start()
        let firstID = try store.create(name: "Первый", duration: 100)
        let secondID = try store.create(name: "Второй", duration: 120)
        let laterID = try store.create(name: "Позже", duration: 500)
        let savesBeforeWake = persistence.savedValues.count
        var timerPublications: [[CyclopTimer]] = []
        let observation = store.$timers.dropFirst().sink { timerPublications.append($0) }
        clock.advance(by: 120)
        let wake = try XCTUnwrap(scheduler.activeEntries.first)
        let completedTimers = [
            timer(
                id: firstID,
                name: "Первый",
                duration: 100,
                phase: .completed,
                pausedRemaining: 0,
                completedAt: date(1_100)
            ),
            timer(
                id: secondID,
                name: "Второй",
                duration: 120,
                phase: .completed,
                pausedRemaining: 0,
                completedAt: date(1_120)
            ),
            timer(
                id: laterID,
                name: "Позже",
                duration: 500,
                phase: .running,
                endsAt: date(1_500)
            ),
        ]

        wake.action()

        XCTAssertEqual(persistence.savedValues.count, savesBeforeWake + 1)
        XCTAssertEqual(persistence.savedValues.last, completedTimers)
        XCTAssertEqual(timerPublications, [completedTimers])
        XCTAssertEqual(store.timers, completedTimers)
        XCTAssertEqual(scheduler.activeEntries.map(\.date), [date(1_500)])
        XCTAssertEqual(store.health, .available)
        withExtendedLifetime(observation) {}
    }

    func testDeadlineSaveFailureKeepsRunningStateAndLeavesNoWake() throws {
        let clock = MutableActivityClock(now: date(1_000))
        let due = timer(
            id: id(1),
            name: "Срок",
            duration: 100,
            phase: .running,
            endsAt: date(1_100)
        )
        let persistence = MemoryTimerPersistence([due])
        let scheduler = ManualActivityScheduler()
        let store = TimerStore(
            clock: clock,
            scheduler: scheduler,
            persistence: persistence
        )
        try store.start()
        persistence.saveError = PersistenceDoubleError.failed
        let wake = try XCTUnwrap(scheduler.activeEntries.first)
        clock.advance(by: 200)

        wake.action()

        XCTAssertEqual(store.timers, [due])
        XCTAssertEqual(persistence.stored, [due])
        XCTAssertTrue(scheduler.activeEntries.isEmpty)
        XCTAssertEqual(store.health, .unavailable(message: "Не удалось сохранить таймеры"))
    }

    private func makeStartedStore() throws -> (
        TimerStore,
        MutableActivityClock,
        ManualActivityScheduler,
        MemoryTimerPersistence
    ) {
        let clock = MutableActivityClock(now: date(1_000))
        let scheduler = ManualActivityScheduler()
        let persistence = MemoryTimerPersistence()
        let store = TimerStore(clock: clock, scheduler: scheduler, persistence: persistence)
        try store.start()
        return (store, clock, scheduler, persistence)
    }

    private func perform(_ action: TimerAction, on id: UUID, in store: TimerStore) throws {
        switch action {
        case .pause:
            try store.pause(id)
        case .resume:
            try store.resume(id)
        case .cancel:
            try store.cancel(id)
        case .dismiss:
            try store.dismiss(id)
        case .restart:
            try store.restart(id)
        }
    }

    private func invalidActions(for phase: TimerPhase) -> [TimerAction] {
        switch phase {
        case .running:
            return [.resume, .dismiss, .restart]
        case .paused:
            return [.pause, .dismiss, .restart]
        case .completed, .cancelled:
            return [.pause, .resume, .cancel]
        }
    }
}

private enum TimerAction: CaseIterable {
    case pause
    case resume
    case cancel
    case dismiss
    case restart
}

private enum PersistenceDoubleError: Error {
    case failed
}

private let unknownID = UUID(uuidString: "FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFF")!

private func date(_ seconds: TimeInterval) -> Date {
    Date(timeIntervalSince1970: seconds)
}

private func id(_ suffix: Int) -> UUID {
    UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", suffix))!
}

private func timer(
    id: UUID,
    name: String,
    duration: TimeInterval,
    phase: TimerPhase,
    endsAt: Date? = nil,
    pausedRemaining: TimeInterval? = nil,
    completedAt: Date? = nil,
    completionSoundPlayed: Bool = false
) -> CyclopTimer {
    CyclopTimer(
        id: id,
        name: name,
        originalDuration: duration,
        phase: phase,
        endsAt: endsAt,
        pausedRemaining: pausedRemaining,
        completedAt: completedAt,
        completionSoundPlayed: completionSoundPlayed
    )
}
