import XCTest
@testable import Cyclop

final class ActivityCoordinatorTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!
    private let homeDirectory = URL(fileURLWithPath: "/Users/test")

    override func setUp() {
        super.setUp()
        suiteName = "ActivityCoordinatorTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    @MainActor
    func testCoordinatorMergesDeterministicallyAndRoutesBySnapshotSourceID() {
        let timers = FakeActivitySource(sourceID: "timers")
        let media = FakeActivitySource(sourceID: "media")
        let coordinator = makeCoordinator([timers, media])
        let timer = completedTimer(sourceID: "timers", idSource: "legacy-timer")
        let track = playingMedia(sourceID: "media", idSource: "legacy-media")

        media.subject.send(.init(
            snapshots: [track],
            health: .unavailable(message: "Источник музыки недоступен")
        ))
        timers.subject.send(.init(snapshots: [timer], health: .available))

        XCTAssertEqual(coordinator.displayState.allActivities.map(\.id), [timer.id, track.id])
        XCTAssertEqual(coordinator.displayState.primary?.id, timer.id)
        XCTAssertEqual(coordinator.displayState.indicators.map(\.activityID), [track.id])
        XCTAssertEqual(coordinator.displayState.diagnostics, [
            "timers": .available,
            "media": .unavailable(message: "Источник музыки недоступен")
        ])

        coordinator.perform(.dismiss, activityID: timer.id)
        coordinator.perform(.pause, activityID: track.id)

        XCTAssertEqual(timers.performed.last?.0, .dismiss)
        XCTAssertEqual(timers.performed.last?.1, timer.id)
        XCTAssertEqual(media.performed.last?.0, .pause)
        XCTAssertEqual(media.performed.last?.1, track.id)
    }

    @MainActor
    func testRoutingStopsWhenSourceRemovesActivity() {
        let source = FakeActivitySource(sourceID: "timers")
        let coordinator = makeCoordinator([source])
        let timer = activeTimer(sourceID: source.sourceID)

        source.subject.send(.init(snapshots: [timer], health: .available))
        source.subject.send(.init(snapshots: [], health: .available))
        coordinator.perform(.cancel, activityID: timer.id)

        XCTAssertTrue(source.performed.isEmpty)
    }

    @MainActor
    func testKindVisibilitySettingsHideOnlyCompactPresentation() {
        let source = FakeActivitySource(sourceID: "fixtures")
        let settings = makeSettings()
        let coordinator = makeCoordinator([source], settings: settings)
        let snapshots = [
            meeting(sourceID: source.sourceID, occurredAt: nil),
            activeTimer(sourceID: source.sourceID),
            activeDownload(sourceID: source.sourceID),
            playingMedia(sourceID: source.sourceID)
        ]
        source.subject.send(.init(snapshots: snapshots, health: .available))

        let cases: [(setEnabled: (Bool) -> Void, hiddenID: ActivityID)] = [
            ({ settings.meetingsEnabled = $0 }, snapshots[0].id),
            ({ settings.timersEnabled = $0 }, snapshots[1].id),
            ({ settings.downloadsEnabled = $0 }, snapshots[2].id),
            ({ settings.mediaEnabled = $0 }, snapshots[3].id)
        ]

        for testCase in cases {
            testCase.setEnabled(false)
            let visibleIDs = compactIDs(in: coordinator.displayState)
            XCTAssertFalse(visibleIDs.contains(testCase.hiddenID))
            XCTAssertEqual(coordinator.displayState.allActivities.map(\.id), snapshots.map(\.id))
            testCase.setEnabled(true)
            XCTAssertTrue(compactIDs(in: coordinator.displayState).contains(testCase.hiddenID))
        }
    }

    @MainActor
    func testGlobalVisibilityClearsCompactStateWithoutMutatingOrActingOnSource() {
        let source = FakeActivitySource(sourceID: "fixtures")
        let settings = makeSettings()
        let coordinator = makeCoordinator([source], settings: settings)
        let timer = completedTimer(sourceID: source.sourceID)
        let track = playingMedia(sourceID: source.sourceID)
        let sourceState = ActivitySourceState(snapshots: [timer, track], health: .available)
        source.subject.send(sourceState)
        XCTAssertNotNil(coordinator.displayState.attention)

        settings.isEnabled = false

        XCTAssertEqual(coordinator.displayState.allActivities, sourceState.snapshots)
        XCTAssertNil(coordinator.displayState.primary)
        XCTAssertTrue(coordinator.displayState.indicators.isEmpty)
        XCTAssertEqual(coordinator.displayState.hiddenIndicatorCount, 0)
        XCTAssertNil(coordinator.displayState.attention)
        XCTAssertEqual(coordinator.displayState.diagnostics, [source.sourceID: .available])
        XCTAssertEqual(source.subject.value, sourceState)
        XCTAssertTrue(source.performed.isEmpty)
    }

    @MainActor
    func testGlobalOffDoesNotClaimAttentionThatWasNeverPresented() throws {
        let source = FakeActivitySource(sourceID: "fixtures")
        let settings = makeSettings()
        settings.isEnabled = false
        let coordinator = makeCoordinator([source], settings: settings)
        let timer = completedTimer(sourceID: source.sourceID)

        source.subject.send(.init(snapshots: [timer], health: .available))
        XCTAssertNil(coordinator.displayState.attention)
        source.subject.send(.init(snapshots: [], health: .available))

        settings.isEnabled = true
        source.subject.send(.init(snapshots: [timer], health: .available))

        XCTAssertEqual(try XCTUnwrap(coordinator.displayState.attention).kind, .timerCompleted)
    }

    @MainActor
    func testGlobalHideSettlesActiveAndPendingTerminalAttentionBeforeReenable() throws {
        let source = FakeActivitySource(sourceID: "fixtures")
        let settings = makeSettings()
        let coordinator = makeCoordinator([source], settings: settings)
        let timer = completedTimer(sourceID: source.sourceID)
        let failed = failedDownload(sourceID: source.sourceID)
        let track = playingMedia(sourceID: source.sourceID)
        source.subject.send(.init(snapshots: [failed, track, timer], health: .available))
        XCTAssertEqual(try XCTUnwrap(coordinator.displayState.attention).kind, .timerCompleted)

        settings.isEnabled = false
        settings.isEnabled = true

        XCTAssertNil(coordinator.displayState.attention)
        XCTAssertEqual(coordinator.displayState.primary?.id, track.id)
        XCTAssertEqual(
            coordinator.displayState.indicators.map(\.activityID),
            [timer.id, failed.id]
        )
    }

    @MainActor
    func testPerKindHideSettlesActiveFailedDownloadBeforeReenable() throws {
        let source = FakeActivitySource(sourceID: "fixtures")
        let settings = makeSettings()
        let coordinator = makeCoordinator([source], settings: settings)
        let failed = failedDownload(sourceID: source.sourceID)
        let track = playingMedia(sourceID: source.sourceID)
        source.subject.send(.init(snapshots: [failed, track], health: .available))
        XCTAssertEqual(try XCTUnwrap(coordinator.displayState.attention).kind, .downloadFailed)

        settings.downloadsEnabled = false
        settings.downloadsEnabled = true

        XCTAssertNil(coordinator.displayState.attention)
        XCTAssertEqual(coordinator.displayState.primary?.id, track.id)
        XCTAssertEqual(coordinator.displayState.indicators.map(\.activityID), [failed.id])
    }

    @MainActor
    func testPerKindHideDropsMeetingAttentionWithoutDemotingMeeting() throws {
        let source = FakeActivitySource(sourceID: "meetings")
        let settings = makeSettings()
        let coordinator = makeCoordinator([source], settings: settings)
        let currentMeeting = meeting(sourceID: source.sourceID, occurredAt: 1_100)
        let track = playingMedia(sourceID: source.sourceID)
        source.subject.send(.init(snapshots: [track, currentMeeting], health: .available))
        XCTAssertEqual(
            try XCTUnwrap(coordinator.displayState.attention).kind,
            .meetingThreshold
        )

        settings.meetingsEnabled = false
        settings.meetingsEnabled = true

        XCTAssertNil(coordinator.displayState.attention)
        XCTAssertEqual(coordinator.displayState.primary?.id, currentMeeting.id)
        XCTAssertEqual(coordinator.displayState.indicators.map(\.activityID), [track.id])
    }

    @MainActor
    func testAttentionSurvivesUnrelatedSourceUpdatesUntilSettled() throws {
        let timers = FakeActivitySource(sourceID: "timers")
        let media = FakeActivitySource(sourceID: "media")
        let coordinator = makeCoordinator([timers, media])
        let timer = completedTimer(sourceID: timers.sourceID)

        timers.subject.send(.init(snapshots: [timer], health: .available))
        let attention = try XCTUnwrap(coordinator.displayState.attention)
        media.subject.send(.init(
            snapshots: [playingMedia(sourceID: media.sourceID)],
            health: .unavailable(message: "Нет данных")
        ))

        XCTAssertEqual(coordinator.displayState.attention, attention)
    }

    @MainActor
    func testSettledCompletedTimerBecomesIndicatorInsteadOfPermanentPrimary() throws {
        let source = FakeActivitySource(sourceID: "fixtures")
        let coordinator = makeCoordinator([source])
        let timer = completedTimer(sourceID: source.sourceID)
        let track = playingMedia(sourceID: source.sourceID)
        source.subject.send(.init(snapshots: [timer, track], health: .available))

        let event = try XCTUnwrap(coordinator.displayState.attention)
        XCTAssertEqual(coordinator.displayState.primary?.id, timer.id)
        coordinator.settleAttention(event)

        XCTAssertNil(coordinator.displayState.attention)
        XCTAssertEqual(coordinator.displayState.primary?.id, track.id)
        XCTAssertTrue(coordinator.displayState.indicators.contains { $0.activityID == timer.id })
    }

    @MainActor
    func testSettledFailedDownloadBecomesIndicatorUntilViewed() throws {
        let source = FakeActivitySource(sourceID: "fixtures")
        let coordinator = makeCoordinator([source])
        let download = failedDownload(sourceID: source.sourceID)
        let track = playingMedia(sourceID: source.sourceID)
        source.subject.send(.init(snapshots: [download, track], health: .available))

        let event = try XCTUnwrap(coordinator.displayState.attention)
        XCTAssertEqual(coordinator.displayState.primary?.id, download.id)
        coordinator.settleAttention(event)

        XCTAssertEqual(coordinator.displayState.primary?.id, track.id)
        XCTAssertTrue(coordinator.displayState.indicators.contains { $0.activityID == download.id })

        coordinator.markViewed(download.id)

        XCTAssertFalse(compactIDs(in: coordinator.displayState).contains(download.id))
        XCTAssertTrue(coordinator.displayState.allActivities.contains { $0.id == download.id })
    }

    @MainActor
    func testViewedFailedAndCompletedDownloadsLeaveRawCardsButDisappearFromCompactState() {
        let source = FakeActivitySource(sourceID: "downloads")
        let coordinator = makeCoordinator([source])
        let failed = failedDownload(sourceID: source.sourceID, local: "failed")
        let completed = completedDownload(sourceID: source.sourceID, local: "completed")
        source.subject.send(.init(snapshots: [failed, completed], health: .available))

        coordinator.markViewed(failed.id)
        coordinator.markViewed(completed.id)

        XCTAssertEqual(coordinator.displayState.allActivities.map(\.id), [failed.id, completed.id])
        XCTAssertNil(coordinator.displayState.primary)
        XCTAssertTrue(coordinator.displayState.indicators.isEmpty)
        XCTAssertEqual(coordinator.displayState.hiddenIndicatorCount, 0)
        XCTAssertNil(coordinator.displayState.attention)
    }

    @MainActor
    func testMarkViewedDoesNotHideSettledCompletedTimer() throws {
        let source = FakeActivitySource(sourceID: "fixtures")
        let coordinator = makeCoordinator([source])
        let timer = completedTimer(sourceID: source.sourceID)
        let track = playingMedia(sourceID: source.sourceID)
        source.subject.send(.init(snapshots: [timer, track], health: .available))
        coordinator.settleAttention(try XCTUnwrap(coordinator.displayState.attention))

        coordinator.markViewed(timer.id)

        XCTAssertEqual(coordinator.displayState.primary?.id, track.id)
        XCTAssertTrue(coordinator.displayState.indicators.contains { $0.activityID == timer.id })
    }

    @MainActor
    func testLedgerRejectedTerminalEventsAreImmediatelySettledAfterRelaunch() throws {
        let source = FakeActivitySource(sourceID: "fixtures")
        let clock = MutableActivityClock(now: date(2_000))
        let ledger = ActivityAttentionLedger(defaults: defaults, clock: clock)
        let timer = completedTimer(sourceID: source.sourceID, local: "timer")
        let failed = failedDownload(sourceID: source.sourceID, local: "download")
        let terminalEvents = ActivityAttentionPolicy.events(
            previous: [],
            current: ActivityRanking.sorted([failed, timer]),
            now: clock.now
        )
        XCTAssertEqual(terminalEvents.map(\.kind), [.timerCompleted, .downloadFailed])
        terminalEvents.forEach { XCTAssertTrue(ledger.claim($0)) }

        let coordinator = makeCoordinator([source], clock: clock, ledger: ledger)
        let track = playingMedia(sourceID: source.sourceID)
        source.subject.send(.init(snapshots: [failed, track, timer], health: .available))

        XCTAssertNil(coordinator.displayState.attention)
        XCTAssertEqual(coordinator.displayState.primary?.id, track.id)
        XCTAssertEqual(
            Set(coordinator.displayState.indicators.map(\.activityID)),
            Set([timer.id, failed.id])
        )
    }

    @MainActor
    func testLedgerRejectedMeetingEventDoesNotDemoteMeeting() throws {
        let source = FakeActivitySource(sourceID: "meetings")
        let clock = MutableActivityClock(now: date(2_000))
        let ledger = ActivityAttentionLedger(defaults: defaults, clock: clock)
        let meeting = meeting(sourceID: source.sourceID, occurredAt: 1_100)
        let event = try XCTUnwrap(ActivityAttentionPolicy.events(
            previous: [],
            current: [meeting],
            now: clock.now
        ).first)
        XCTAssertTrue(ledger.claim(event))

        let coordinator = makeCoordinator([source], clock: clock, ledger: ledger)
        source.subject.send(.init(
            snapshots: [playingMedia(sourceID: source.sourceID), meeting],
            health: .available
        ))

        XCTAssertNil(coordinator.displayState.attention)
        XCTAssertEqual(coordinator.displayState.primary?.id, meeting.id)
    }

    @MainActor
    func testSimultaneousAttentionUsesCompactPriorityAndAdvancesFIFO() throws {
        let source = FakeActivitySource(sourceID: "fixtures")
        let coordinator = makeCoordinator([source])
        let timer = completedTimer(sourceID: source.sourceID)
        let failed = failedDownload(sourceID: source.sourceID)
        let track = playingMedia(sourceID: source.sourceID)

        source.subject.send(.init(snapshots: [failed, track, timer], health: .available))

        let timerEvent = try XCTUnwrap(coordinator.displayState.attention)
        XCTAssertEqual(timerEvent.kind, .timerCompleted)
        coordinator.settleAttention(timerEvent)

        let failedEvent = try XCTUnwrap(coordinator.displayState.attention)
        XCTAssertEqual(failedEvent.kind, .downloadFailed)
        XCTAssertEqual(coordinator.displayState.primary?.id, failed.id)
        coordinator.settleAttention(failedEvent)

        XCTAssertNil(coordinator.displayState.attention)
        XCTAssertEqual(coordinator.displayState.primary?.id, track.id)
        XCTAssertEqual(
            Set(coordinator.displayState.indicators.map(\.activityID)),
            Set([timer.id, failed.id])
        )
    }

    @MainActor
    func testPendingAttentionRemainsClaimableAfterRelaunchUntilItIsPromoted() throws {
        let timer = completedTimer(sourceID: "fixtures")
        let failed = failedDownload(sourceID: "fixtures")

        do {
            let firstSource = FakeActivitySource(sourceID: "fixtures")
            let firstCoordinator = makeCoordinator([firstSource])
            firstSource.subject.send(.init(snapshots: [failed, timer], health: .available))

            XCTAssertEqual(
                try XCTUnwrap(firstCoordinator.displayState.attention).kind,
                .timerCompleted
            )
        }

        let relaunchedSource = FakeActivitySource(sourceID: "fixtures")
        let relaunchedCoordinator = makeCoordinator([relaunchedSource])
        relaunchedSource.subject.send(.init(snapshots: [failed], health: .available))

        XCTAssertEqual(
            try XCTUnwrap(relaunchedCoordinator.displayState.attention).kind,
            .downloadFailed
        )
        XCTAssertEqual(relaunchedCoordinator.displayState.primary?.id, failed.id)
    }

    @MainActor
    func testTerminalMarksArePrunedAfterActivitiesDisappear() throws {
        let source = FakeActivitySource(sourceID: "fixtures")
        let coordinator = makeCoordinator([source])
        let timer = completedTimer(sourceID: source.sourceID, occurredAt: 1_000)
        let failed = failedDownload(sourceID: source.sourceID, occurredAt: 1_000)
        source.subject.send(.init(snapshots: [timer, failed], health: .available))
        coordinator.settleAttention(try XCTUnwrap(coordinator.displayState.attention))
        coordinator.markViewed(failed.id)

        source.subject.send(.init(snapshots: [], health: .available))
        let restartedTimer = completedTimer(sourceID: source.sourceID, occurredAt: 2_000)
        let retriedDownload = failedDownload(sourceID: source.sourceID, occurredAt: 2_000)
        source.subject.send(.init(
            snapshots: [restartedTimer, retriedDownload],
            health: .available
        ))

        XCTAssertEqual(coordinator.displayState.primary?.id, restartedTimer.id)
        XCTAssertTrue(coordinator.displayState.indicators.contains {
            $0.activityID == retriedDownload.id
        })
    }

    @MainActor
    func testStaleSettlementAfterRemovalDoesNotDemoteReusedActivityID() throws {
        let source = FakeActivitySource(sourceID: "fixtures")
        let coordinator = makeCoordinator([source])
        let timer = completedTimer(sourceID: source.sourceID, occurredAt: 1_000)
        source.subject.send(.init(snapshots: [timer], health: .available))
        let staleEvent = try XCTUnwrap(coordinator.displayState.attention)

        source.subject.send(.init(snapshots: [], health: .available))
        coordinator.settleAttention(staleEvent)
        let reused = completedTimer(sourceID: source.sourceID, occurredAt: 2_000)
        source.subject.send(.init(snapshots: [reused], health: .available))

        XCTAssertEqual(coordinator.displayState.primary?.id, reused.id)
        XCTAssertEqual(try XCTUnwrap(coordinator.displayState.attention).activityID, reused.id)
    }

    @MainActor
    func testStaleSettlementFromEarlierOccurrenceDoesNotDemoteCurrentTerminalCycle() throws {
        let source = FakeActivitySource(sourceID: "fixtures")
        let coordinator = makeCoordinator([source])
        let firstCompletion = completedTimer(sourceID: source.sourceID, occurredAt: 1_000)
        source.subject.send(.init(snapshots: [firstCompletion], health: .available))
        let staleEvent = try XCTUnwrap(coordinator.displayState.attention)

        source.subject.send(.init(
            snapshots: [activeTimer(sourceID: source.sourceID, local: firstCompletion.id.local)],
            health: .available
        ))
        let secondCompletion = completedTimer(sourceID: source.sourceID, occurredAt: 2_000)
        source.subject.send(.init(snapshots: [secondCompletion], health: .available))
        let currentEvent = try XCTUnwrap(coordinator.displayState.attention)
        XCTAssertNotEqual(currentEvent.id, staleEvent.id)

        coordinator.settleAttention(staleEvent)

        XCTAssertEqual(coordinator.displayState.attention, currentEvent)
        XCTAssertEqual(coordinator.displayState.primary?.id, secondCompletion.id)
        XCTAssertFalse(coordinator.displayState.indicators.contains {
            $0.activityID == secondCompletion.id
        })
    }

    @MainActor
    func testSettledTimerMarkIsPrunedByEveryNonterminalDomainPhase() throws {
        for (index, phase) in nonterminalPhases.enumerated() {
            let source = FakeActivitySource(sourceID: "timers.\(index)")
            let coordinator = makeCoordinator([source])
            let completed = completedTimer(
                sourceID: source.sourceID,
                local: "timer-\(index)",
                occurredAt: TimeInterval(1_000 + index)
            )
            source.subject.send(.init(snapshots: [completed], health: .available))
            coordinator.settleAttention(try XCTUnwrap(coordinator.displayState.attention))
            XCTAssertNil(coordinator.displayState.primary, "phase=\(phase.rawValue)")

            source.subject.send(.init(
                snapshots: [snapshot(
                    local: completed.id.local,
                    sourceID: source.sourceID,
                    kind: .timer,
                    phase: phase
                )],
                health: .available
            ))
            let completedAgain = completedTimer(
                sourceID: source.sourceID,
                local: completed.id.local,
                occurredAt: TimeInterval(2_000 + index)
            )
            source.subject.send(.init(snapshots: [completedAgain], health: .available))

            XCTAssertEqual(
                coordinator.displayState.primary?.id,
                completedAgain.id,
                "phase=\(phase.rawValue)"
            )
        }
    }

    @MainActor
    func testViewedDownloadMarkIsPrunedByEveryNonterminalDomainPhase() {
        for (index, phase) in nonterminalPhases.enumerated() {
            let source = FakeActivitySource(sourceID: "downloads.\(index)")
            let coordinator = makeCoordinator([source])
            let failed = failedDownload(
                sourceID: source.sourceID,
                local: "download-\(index)",
                occurredAt: TimeInterval(1_000 + index)
            )
            source.subject.send(.init(snapshots: [failed], health: .available))
            coordinator.markViewed(failed.id)
            XCTAssertNil(coordinator.displayState.primary, "phase=\(phase.rawValue)")

            source.subject.send(.init(
                snapshots: [snapshot(
                    local: failed.id.local,
                    sourceID: source.sourceID,
                    kind: .download,
                    phase: phase
                )],
                health: .available
            ))
            let failedAgain = failedDownload(
                sourceID: source.sourceID,
                local: failed.id.local,
                occurredAt: TimeInterval(2_000 + index)
            )
            source.subject.send(.init(snapshots: [failedAgain], health: .available))

            XCTAssertEqual(
                coordinator.displayState.primary?.id,
                failedAgain.id,
                "phase=\(phase.rawValue)"
            )
        }
    }

    @MainActor
    private func makeCoordinator(
        _ sources: [ActivitySource],
        settings: ActivitySettings? = nil,
        clock: ActivityClock? = nil,
        ledger: ActivityAttentionLedger? = nil
    ) -> ActivityCoordinator {
        let resolvedClock = clock ?? MutableActivityClock(now: date(2_000))
        return ActivityCoordinator(
            sources: sources,
            settings: settings ?? makeSettings(),
            attentionLedger: ledger ?? ActivityAttentionLedger(defaults: defaults, clock: resolvedClock),
            clock: resolvedClock
        )
    }

    @MainActor
    private func makeSettings() -> ActivitySettings {
        ActivitySettings(defaults: defaults, homeDirectory: homeDirectory)
    }

    private func compactIDs(in state: ActivityDisplayState) -> Set<ActivityID> {
        var ids = Set(state.indicators.map(\.activityID))
        if let primaryID = state.primary?.id {
            ids.insert(primaryID)
        }
        return ids
    }

    private var nonterminalPhases: [ActivityPhase] {
        [.ambient, .active, .attention, .paused]
    }

    private func completedTimer(
        sourceID: String,
        idSource: String? = nil,
        local: String = "completed-timer",
        occurredAt: TimeInterval = 1_000
    ) -> ActivitySnapshot {
        snapshot(
            local: local,
            sourceID: sourceID,
            idSource: idSource,
            kind: .timer,
            phase: .completed,
            occurredAt: occurredAt,
            actions: [.dismiss, .restart]
        )
    }

    private func activeTimer(
        sourceID: String,
        local: String = "active-timer"
    ) -> ActivitySnapshot {
        snapshot(
            local: local,
            sourceID: sourceID,
            kind: .timer,
            phase: .active,
            deadline: 3_000,
            actions: [.pause, .cancel]
        )
    }

    private func failedDownload(
        sourceID: String,
        local: String = "failed-download",
        occurredAt: TimeInterval = 1_100
    ) -> ActivitySnapshot {
        snapshot(
            local: local,
            sourceID: sourceID,
            kind: .download,
            phase: .failed,
            occurredAt: occurredAt,
            actions: [.retry, .cancel]
        )
    }

    private func completedDownload(
        sourceID: String,
        local: String = "completed-download",
        occurredAt: TimeInterval = 1_200
    ) -> ActivitySnapshot {
        snapshot(
            local: local,
            sourceID: sourceID,
            kind: .download,
            phase: .completed,
            occurredAt: occurredAt,
            actions: [.open, .reveal, .dismiss]
        )
    }

    private func activeDownload(
        sourceID: String,
        local: String = "active-download"
    ) -> ActivitySnapshot {
        snapshot(
            local: local,
            sourceID: sourceID,
            kind: .download,
            phase: .active,
            actions: [.pause, .cancel]
        )
    }

    private func playingMedia(
        sourceID: String,
        idSource: String? = nil,
        local: String = "playing-media"
    ) -> ActivitySnapshot {
        snapshot(
            local: local,
            sourceID: sourceID,
            idSource: idSource,
            kind: .media,
            phase: .active,
            actions: [.pause]
        )
    }

    private func meeting(
        sourceID: String,
        local: String = "meeting",
        occurredAt: TimeInterval?
    ) -> ActivitySnapshot {
        snapshot(
            local: local,
            sourceID: sourceID,
            kind: .meeting,
            phase: .active,
            deadline: 2_000,
            occurredAt: occurredAt,
            actions: [.join]
        )
    }

    private func snapshot(
        local: String,
        sourceID: String,
        idSource: String? = nil,
        kind: ActivityKind,
        phase: ActivityPhase,
        deadline: TimeInterval? = nil,
        occurredAt: TimeInterval? = nil,
        actions: Set<ActivityAction> = []
    ) -> ActivitySnapshot {
        ActivitySnapshot(
            id: ActivityID(source: idSource ?? sourceID, local: local),
            sourceID: sourceID,
            kind: kind,
            phase: phase,
            title: local,
            subtitle: "",
            progress: nil,
            deadline: deadline.map(date),
            occurredAt: occurredAt.map(date),
            availableActions: actions,
            containsSensitiveText: false
        )
    }

    private func date(_ interval: TimeInterval) -> Date {
        Date(timeIntervalSince1970: interval)
    }
}
