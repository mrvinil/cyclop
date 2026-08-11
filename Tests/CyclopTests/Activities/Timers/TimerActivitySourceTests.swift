import Combine
import Foundation
import XCTest
@testable import Cyclop

@MainActor
final class TimerActivitySourceTests: XCTestCase {
    func testMapsEveryPublishedPhaseFieldActionAndPreservesStoreOrder() throws {
        let paused = timer(
            id: id(1),
            name: "Пауза",
            duration: 300,
            phase: .paused,
            pausedRemaining: 120
        )
        let cancelled = timer(
            id: id(2),
            name: "Отменён",
            duration: 60,
            phase: .cancelled,
            pausedRemaining: 0
        )
        let running = timer(
            id: id(3),
            name: "Фокус",
            duration: 1_500,
            phase: .running,
            endsAt: date(2_500)
        )
        let completed = timer(
            id: id(4),
            name: "Чай",
            duration: 300,
            phase: .completed,
            pausedRemaining: 0,
            completedAt: date(900),
            completionSoundPlayed: true
        )
        let (store, _, _, _) = try makeStartedStore([paused, cancelled, running, completed])

        let source = TimerActivitySource(store: store)
        let state = try currentState(of: source)

        XCTAssertEqual(source.sourceID, "timers")
        XCTAssertEqual(state.health, .available)
        XCTAssertEqual(state.snapshots, [
            snapshot(
                for: paused,
                phase: .paused,
                deadline: nil,
                occurredAt: nil,
                actions: [.resume, .cancel]
            ),
            snapshot(
                for: running,
                phase: .active,
                deadline: date(2_500),
                occurredAt: nil,
                actions: [.pause, .cancel]
            ),
            snapshot(
                for: completed,
                phase: .completed,
                deadline: nil,
                occurredAt: date(900),
                actions: [.dismiss, .restart]
            ),
        ])
    }

    func testPublishesCurrentStoreStateImmediatelyAndSubsequentTimerChanges() throws {
        let (store, _, _, _) = try makeStartedStore()
        let source = TimerActivitySource(store: store)
        var states: [ActivitySourceState] = []
        let observation = source.statePublisher.sink { states.append($0) }

        let timerID = try store.create(name: "Фокус", duration: 600)
        try store.pause(timerID)

        XCTAssertEqual(states.first, .init(snapshots: [], health: .available))
        XCTAssertEqual(states.last?.snapshots.map(\.phase), [.paused])
        XCTAssertEqual(states.last?.snapshots.map(\.id), [
            ActivityID(source: "timers", local: timerID.uuidString),
        ])
        withExtendedLifetime(observation) {}
    }

    func testCompletedIdentityAndOccurrenceRemainStableAcrossReloadLikeSourceCreation() throws {
        let completed = timer(
            id: id(1),
            name: "Стабильный",
            duration: 90,
            phase: .completed,
            pausedRemaining: 0,
            completedAt: date(875),
            completionSoundPlayed: true
        )
        let persistence = MemoryTimerPersistence([completed])
        let firstStore = TimerStore(
            clock: MutableActivityClock(now: date(1_000)),
            scheduler: ManualActivityScheduler(),
            persistence: persistence
        )
        try firstStore.start()
        let first = try XCTUnwrap(currentState(of: TimerActivitySource(store: firstStore)).snapshots.first)

        let relaunchedStore = TimerStore(
            clock: MutableActivityClock(now: date(1_500)),
            scheduler: ManualActivityScheduler(),
            persistence: persistence
        )
        try relaunchedStore.start()
        let relaunched = try XCTUnwrap(
            currentState(of: TimerActivitySource(store: relaunchedStore)).snapshots.first
        )

        XCTAssertEqual(first.id, relaunched.id)
        XCTAssertEqual(first.occurredAt, date(875))
        XCTAssertEqual(relaunched.occurredAt, date(875))
    }

    func testReflectsExactStoreHealthForLoadFailureAndRecovery() throws {
        let persistence = MemoryTimerPersistence()
        persistence.loadError = TestPersistenceError.failed
        let store = TimerStore(
            clock: MutableActivityClock(now: date(1_000)),
            scheduler: ManualActivityScheduler(),
            persistence: persistence
        )
        let source = TimerActivitySource(store: store)

        XCTAssertThrowsError(try store.start())
        XCTAssertEqual(
            try currentState(of: source).health,
            .unavailable(message: "Не удалось загрузить таймеры")
        )

        persistence.loadError = nil
        try store.start()

        XCTAssertEqual(try currentState(of: source).health, .available)
    }

    func testRoutesEverySupportedActionThroughStoreTransitions() throws {
        let runningForPause = timer(
            id: id(1),
            name: "Пауза",
            duration: 300,
            phase: .running,
            endsAt: date(1_300)
        )
        let pausedForResume = timer(
            id: id(2),
            name: "Продолжить",
            duration: 300,
            phase: .paused,
            pausedRemaining: 80
        )
        let runningForCancel = timer(
            id: id(3),
            name: "Отменить",
            duration: 300,
            phase: .running,
            endsAt: date(1_300)
        )
        let completedForDismiss = timer(
            id: id(4),
            name: "Скрыть",
            duration: 300,
            phase: .completed,
            pausedRemaining: 0,
            completedAt: date(900)
        )
        let completedForRestart = timer(
            id: id(5),
            name: "Повторить",
            duration: 450,
            phase: .completed,
            pausedRemaining: 0,
            completedAt: date(950),
            completionSoundPlayed: true
        )
        let (store, _, _, persistence) = try makeStartedStore([
            runningForPause,
            pausedForResume,
            runningForCancel,
            completedForDismiss,
            completedForRestart,
        ])
        let source = TimerActivitySource(store: store)

        source.perform(.pause, activityID: activityID(runningForPause.id))
        source.perform(.resume, activityID: activityID(pausedForResume.id))
        source.perform(.cancel, activityID: activityID(runningForCancel.id))
        source.perform(.dismiss, activityID: activityID(completedForDismiss.id))
        source.perform(.restart, activityID: activityID(completedForRestart.id))

        XCTAssertEqual(store.timer(runningForPause.id)?.phase, .paused)
        XCTAssertEqual(store.timer(pausedForResume.id)?.phase, .running)
        XCTAssertNil(store.timer(runningForCancel.id))
        XCTAssertNil(store.timer(completedForDismiss.id))
        XCTAssertEqual(store.timer(completedForRestart.id)?.phase, .running)
        XCTAssertEqual(store.timer(completedForRestart.id)?.endsAt, date(1_450))
        XCTAssertEqual(persistence.saveCount, 5)
    }

    func testInvalidSourceMalformedUUIDAndUnsupportedActionsAreNoOps() throws {
        let running = timer(
            id: id(1),
            name: "Не менять",
            duration: 300,
            phase: .running,
            endsAt: date(1_300)
        )
        let (store, _, _, persistence) = try makeStartedStore([running])
        let source = TimerActivitySource(store: store)
        let initialState = try currentState(of: source)

        source.perform(
            .pause,
            activityID: ActivityID(source: "downloads", local: running.id.uuidString)
        )
        source.perform(
            .pause,
            activityID: ActivityID(source: "timers", local: "не-uuid")
        )
        for action in [
            ActivityAction.play,
            .previous,
            .next,
            .join,
            .retry,
            .open,
            .reveal,
        ] {
            source.perform(action, activityID: activityID(running.id))
        }

        XCTAssertEqual(store.timers, [running])
        XCTAssertEqual(persistence.saveCount, 0)
        XCTAssertEqual(try currentState(of: source), initialState)
    }

    func testPersistenceFailurePreservesPublishedRussianStoreHealthWithoutCrash() throws {
        let running = timer(
            id: id(1),
            name: "Сохранение",
            duration: 300,
            phase: .running,
            endsAt: date(1_300)
        )
        let (store, _, _, persistence) = try makeStartedStore([running])
        let source = TimerActivitySource(store: store)
        persistence.saveError = TestPersistenceError.failed

        source.perform(.pause, activityID: activityID(running.id))

        let failedState = try currentState(of: source)
        XCTAssertEqual(failedState.snapshots.map(\.phase), [.active])
        XCTAssertEqual(
            failedState.health,
            .unavailable(message: "Не удалось сохранить таймеры")
        )
    }

    func testSuccessfulRetryPublishesNewSnapshotsAtomicallyWithRecoveredHealth() throws {
        let running = timer(
            id: id(1),
            name: "Атомарный retry",
            duration: 300,
            phase: .running,
            endsAt: date(1_300)
        )
        let (store, _, _, persistence) = try makeStartedStore([running])
        let source = TimerActivitySource(store: store)
        var states: [ActivitySourceState] = []
        let observation = source.statePublisher.sink { states.append($0) }

        persistence.saveError = TestPersistenceError.failed
        source.perform(.pause, activityID: activityID(running.id))
        persistence.saveError = nil
        source.perform(.pause, activityID: activityID(running.id))

        XCTAssertEqual(states, [
            ActivitySourceState(
                snapshots: [snapshot(
                    for: running,
                    phase: .active,
                    deadline: date(1_300),
                    occurredAt: nil,
                    actions: [.pause, .cancel]
                )],
                health: .available
            ),
            ActivitySourceState(
                snapshots: [snapshot(
                    for: running,
                    phase: .active,
                    deadline: date(1_300),
                    occurredAt: nil,
                    actions: [.pause, .cancel]
                )],
                health: .unavailable(message: "Не удалось сохранить таймеры")
            ),
            ActivitySourceState(
                snapshots: [snapshot(
                    for: running,
                    phase: .paused,
                    deadline: nil,
                    occurredAt: nil,
                    actions: [.resume, .cancel]
                )],
                health: .available
            ),
        ])
        withExtendedLifetime(observation) {}
    }

    func testTransitionErrorPublishesDeterministicDiagnosticAndNextUpdateRestoresHealth() throws {
        let running = timer(
            id: id(1),
            name: "Переход",
            duration: 300,
            phase: .running,
            endsAt: date(1_300)
        )
        let (store, _, _, _) = try makeStartedStore([running])
        let source = TimerActivitySource(store: store)

        source.perform(.resume, activityID: activityID(running.id))

        XCTAssertEqual(
            try currentState(of: source).health,
            .unavailable(message: "Не удалось выполнить действие с таймером")
        )
        XCTAssertEqual(store.health, .available)

        try store.pause(running.id)

        XCTAssertEqual(try currentState(of: source).health, .available)
        XCTAssertEqual(try currentState(of: source).snapshots.map(\.phase), [.paused])
    }

    func testPauseAtExactDeadlineCompletesThroughSourceAndCoordinatorWithoutGenericError() throws {
        try assertPauseCompletesThroughSourceAndCoordinator(now: 1_100)
    }

    func testOverduePauseCompletesThroughSourceAndCoordinatorWithoutGenericError() throws {
        try assertPauseCompletesThroughSourceAndCoordinator(now: 1_250)
    }

    func testCancelBeforeDeadlineDeletesRunningAndPausedTimersFromEveryLayerAndReload() throws {
        let (store, clock, _, persistence) = try makeStartedStore()
        let runningID = try store.create(name: "Работает", duration: 300)
        let pausedID = try store.create(name: "Пауза", duration: 400)
        clock.advance(by: 25)
        try store.pause(pausedID)
        let source = TimerActivitySource(store: store)

        source.perform(.cancel, activityID: activityID(runningID))
        source.perform(.cancel, activityID: activityID(pausedID))

        XCTAssertTrue(store.timers.isEmpty)
        XCTAssertTrue(persistence.stored.isEmpty)
        XCTAssertEqual(try currentState(of: source), .init(snapshots: [], health: .available))

        let relaunchedStore = TimerStore(
            clock: clock,
            scheduler: ManualActivityScheduler(),
            persistence: persistence
        )
        try relaunchedStore.start()
        let relaunchedSource = TimerActivitySource(store: relaunchedStore)

        XCTAssertTrue(relaunchedStore.timers.isEmpty)
        XCTAssertEqual(
            try currentState(of: relaunchedSource),
            .init(snapshots: [], health: .available)
        )
    }

    private func assertPauseCompletesThroughSourceAndCoordinator(now: TimeInterval) throws {
        let clock = MutableActivityClock(now: date(1_000))
        let scheduler = ManualActivityScheduler()
        let persistence = MemoryTimerPersistence()
        let sound = SourceSoundPlayer(persistence: persistence)
        let store = TimerStore(
            clock: clock,
            scheduler: scheduler,
            persistence: persistence,
            soundPlayer: sound
        )
        try store.start()
        let timerID = try store.create(name: "Граница", duration: 100)
        let source = TimerActivitySource(store: store)
        let suiteName = "TimerActivitySourceTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = ActivitySettings(
            defaults: defaults,
            homeDirectory: URL(fileURLWithPath: "/Users/test")
        )
        let coordinator = ActivityCoordinator(
            sources: [source],
            settings: settings,
            attentionLedger: ActivityAttentionLedger(defaults: defaults, clock: clock),
            clock: clock
        )
        var sourceUpdates: [ActivitySourceState] = []
        let observation = source.statePublisher.dropFirst().sink { sourceUpdates.append($0) }
        clock.advance(by: now - 1_000)

        coordinator.perform(.pause, activityID: activityID(timerID))

        let completed = try XCTUnwrap(store.timer(timerID))
        XCTAssertEqual(completed.phase, .completed)
        XCTAssertEqual(completed.completedAt, date(1_100))
        XCTAssertNil(completed.endsAt)
        XCTAssertEqual(completed.pausedRemaining, 0)
        XCTAssertTrue(completed.completionSoundPlayed)
        XCTAssertEqual(persistence.savedValues.count, 2)
        XCTAssertEqual(persistence.stored, [completed])
        XCTAssertEqual(sound.playCount, 1)
        XCTAssertTrue(sound.persistenceWasClaimedAtPlay)
        XCTAssertEqual(sourceUpdates.count, 1)
        XCTAssertEqual(sourceUpdates.first?.health, .available)
        XCTAssertEqual(sourceUpdates.first?.snapshots.first?.phase, .completed)
        XCTAssertEqual(sourceUpdates.first?.snapshots.first?.occurredAt, date(1_100))
        XCTAssertEqual(
            sourceUpdates.first?.snapshots.first?.availableActions,
            [.dismiss, .restart]
        )
        XCTAssertEqual(coordinator.displayState.primary?.id, activityID(timerID))
        XCTAssertEqual(coordinator.displayState.attention?.kind, .timerCompleted)
        XCTAssertEqual(coordinator.displayState.attention?.occurredAt, date(1_100))
        XCTAssertEqual(coordinator.displayState.diagnostics["timers"], .available)
        withExtendedLifetime(observation) {}
    }

    private func makeStartedStore(
        _ timers: [CyclopTimer] = []
    ) throws -> (
        TimerStore,
        MutableActivityClock,
        ManualActivityScheduler,
        MemoryTimerPersistence
    ) {
        let clock = MutableActivityClock(now: date(1_000))
        let scheduler = ManualActivityScheduler()
        let persistence = MemoryTimerPersistence(timers)
        let store = TimerStore(clock: clock, scheduler: scheduler, persistence: persistence)
        try store.start()
        return (store, clock, scheduler, persistence)
    }

    private func currentState(of source: TimerActivitySource) throws -> ActivitySourceState {
        var current: ActivitySourceState?
        let observation = source.statePublisher.prefix(1).sink { current = $0 }
        defer { observation.cancel() }
        return try XCTUnwrap(current)
    }

    private func snapshot(
        for timer: CyclopTimer,
        phase: ActivityPhase,
        deadline: Date?,
        occurredAt: Date?,
        actions: Set<ActivityAction>
    ) -> ActivitySnapshot {
        ActivitySnapshot(
            id: activityID(timer.id),
            sourceID: "timers",
            kind: .timer,
            phase: phase,
            title: timer.name,
            subtitle: "",
            progress: nil,
            deadline: deadline,
            occurredAt: occurredAt,
            availableActions: actions,
            containsSensitiveText: true
        )
    }

    private func activityID(_ id: UUID) -> ActivityID {
        ActivityID(source: "timers", local: id.uuidString)
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

    private func id(_ suffix: Int) -> UUID {
        UUID(uuidString: String(format: "30000000-0000-0000-0000-%012d", suffix))!
    }

    private func date(_ seconds: TimeInterval) -> Date {
        Date(timeIntervalSince1970: seconds)
    }
}

private enum TestPersistenceError: Error {
    case failed
}

private final class SourceSoundPlayer: TimerSoundPlaying {
    private let persistence: MemoryTimerPersistence
    private(set) var playCount = 0
    private(set) var persistenceWasClaimedAtPlay = true

    init(persistence: MemoryTimerPersistence) {
        self.persistence = persistence
    }

    func playCompletion() {
        playCount += 1
        persistenceWasClaimedAtPlay = persistenceWasClaimedAtPlay
            && persistence.stored
                .filter { $0.phase == .completed }
                .allSatisfy(\.completionSoundPlayed)
    }
}
