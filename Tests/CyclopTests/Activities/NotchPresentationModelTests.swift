import XCTest
@testable import Cyclop

final class NotchPresentationModelTests: XCTestCase {
    @MainActor
    func testDisplayTransitionsCoverIdleCompactAttentionAndExpandedModes() {
        let harness = PresentationHarness()
        XCTAssertEqual(harness.model.state.mode, .idle)

        let track = media()
        harness.model.receive(display: display(primary: track))
        XCTAssertEqual(harness.model.state.mode, .compact)

        let event = attentionEvent(id: "timer-completed", kind: .timerCompleted)
        harness.model.receive(display: display(primary: track, attention: event))
        XCTAssertEqual(harness.model.state.mode, .attention)

        harness.model.openFromPointer(overActiveIsland: true)
        XCTAssertEqual(harness.model.state.mode, .expanded)
    }

    @MainActor
    func testAttentionReturnsToCompactAfterDuration() {
        let harness = PresentationHarness()
        let track = media()
        let event = attentionEvent(id: "timer-completed", kind: .timerCompleted)
        let compactDisplay = display(primary: track)
        harness.onAttentionExpired = { _ in
            harness.model.receive(display: compactDisplay)
        }

        harness.model.receive(display: display(primary: track, attention: event))
        harness.scheduler.entries[0].action()

        XCTAssertEqual(harness.expiredEvents, [event])
        XCTAssertEqual(harness.model.state, .init(mode: .compact, display: compactDisplay))
    }

    @MainActor
    func testAttentionSchedulesAtClockNowPlusEventDurationAndReplacesOneCancellation() {
        let harness = PresentationHarness(now: 1_000)
        let first = attentionEvent(id: "timer-completed", kind: .timerCompleted)
        harness.model.receive(display: display(primary: media(), attention: first))

        XCTAssertEqual(harness.scheduler.entries.count, 1)
        XCTAssertEqual(harness.scheduler.entries[0].date, date(1_010))

        harness.clock.advance(by: 3)
        let second = attentionEvent(id: "download-failed", kind: .downloadFailed)
        harness.model.receive(display: display(primary: media(), attention: second))

        XCTAssertTrue(harness.scheduler.entries[0].cancellation.isCancelled)
        XCTAssertEqual(harness.scheduler.entries.count, 2)
        XCTAssertEqual(harness.scheduler.activeEntries.count, 1)
        XCTAssertEqual(harness.scheduler.entries[1].date, date(1_011))
    }

    @MainActor
    func testSameAttentionUpdateRefreshesDisplayWithoutExtendingDeadline() {
        let harness = PresentationHarness(now: 1_000)
        let event = attentionEvent(id: "timer-completed", kind: .timerCompleted)
        let firstTrack = media(id: "first")
        harness.model.receive(display: display(primary: firstTrack, attention: event))

        harness.clock.advance(by: 4)
        let updatedTrack = media(id: "updated")
        let updatedDisplay = display(primary: updatedTrack, attention: event)
        harness.model.receive(display: updatedDisplay)

        XCTAssertEqual(harness.model.state, .init(mode: .attention, display: updatedDisplay))
        XCTAssertEqual(harness.scheduler.entries.count, 1)
        XCTAssertEqual(harness.scheduler.entries[0].date, date(1_010))
        XCTAssertFalse(harness.scheduler.entries[0].cancellation.isCancelled)
    }

    @MainActor
    func testOldGenerationClosureCannotExpireNewAttention() {
        let harness = PresentationHarness()
        let first = attentionEvent(id: "first", kind: .timerCompleted)
        harness.model.receive(display: display(primary: media(), attention: first))
        let oldEntry = harness.scheduler.entries[0]

        let second = attentionEvent(id: "second", kind: .downloadFailed)
        let secondDisplay = display(primary: media(), attention: second)
        harness.model.receive(display: secondDisplay)
        oldEntry.action()

        XCTAssertTrue(oldEntry.cancellation.isCancelled)
        XCTAssertTrue(harness.expiredEvents.isEmpty)
        XCTAssertEqual(harness.model.state, .init(mode: .attention, display: secondDisplay))
        XCTAssertEqual(harness.scheduler.activeEntries.count, 1)
    }

    @MainActor
    func testCancelledClosureCannotChangeNewCompactDisplay() {
        let harness = PresentationHarness()
        let event = attentionEvent(id: "timer-completed", kind: .timerCompleted)
        harness.model.receive(display: display(primary: media(), attention: event))
        let cancelledEntry = harness.scheduler.entries[0]
        let compactDisplay = display(primary: media(id: "updated"))

        harness.model.receive(display: compactDisplay)
        cancelledEntry.action()

        XCTAssertTrue(cancelledEntry.cancellation.isCancelled)
        XCTAssertTrue(harness.expiredEvents.isEmpty)
        XCTAssertEqual(harness.model.state, .init(mode: .compact, display: compactDisplay))
    }

    @MainActor
    func testExpirationCallsCallbackBeforeUsingRecalculatedDisplay() {
        let harness = PresentationHarness()
        let event = attentionEvent(id: "timer-completed", kind: .timerCompleted)
        let recalculatedDisplay = display()
        var modeObservedByCallback: NotchPresentationMode?
        harness.onAttentionExpired = { _ in
            modeObservedByCallback = harness.model.state.mode
            harness.model.receive(display: recalculatedDisplay)
        }
        harness.model.receive(display: display(primary: media(), attention: event))

        harness.scheduler.entries[0].action()

        XCTAssertEqual(modeObservedByCallback, .attention)
        XCTAssertEqual(harness.expiredEvents, [event])
        XCTAssertEqual(harness.model.state, .init(mode: .idle, display: recalculatedDisplay))
    }

    @MainActor
    func testExpandedModeSurvivesDisplayUpdatesAndCloseUsesCurrentCompactState() {
        let harness = PresentationHarness()
        harness.model.openFromPointer(overActiveIsland: false)
        let event = attentionEvent(id: "timer-completed", kind: .timerCompleted)
        let activeDisplay = display(primary: media(), attention: event)

        harness.model.receive(display: activeDisplay)
        XCTAssertEqual(harness.model.state, .init(mode: .expanded, display: activeDisplay))

        harness.model.closeFromPointer()
        XCTAssertEqual(harness.model.state, .init(mode: .compact, display: activeDisplay))
    }

    @MainActor
    func testIndicatorOrOverflowWithoutPrimaryStillUsesCompactMode() {
        let indicator = ActivityIndicator(
            activityID: .init(source: "timers", local: "completed"),
            kind: .timer,
            phase: .completed
        )
        let displays = [
            display(indicators: [indicator]),
            display(hiddenIndicatorCount: 1)
        ]

        for compactDisplay in displays {
            let harness = PresentationHarness()
            harness.model.receive(display: compactDisplay)
            XCTAssertEqual(harness.model.state.mode, .compact)

            harness.model.openFromPointer(overActiveIsland: true)
            harness.model.closeFromPointer()
            XCTAssertEqual(harness.model.state, .init(mode: .compact, display: compactDisplay))
        }
    }

    @MainActor
    func testAutomaticActivitiesRequestIsTemporaryAndDoesNotOverwriteLastUserTab() {
        let harness = PresentationHarness()
        harness.model.recordUserTab("calendar")

        harness.model.openFromPointer(overActiveIsland: true)
        XCTAssertEqual(harness.model.state.mode, .expanded)
        XCTAssertEqual(harness.model.requestedTab, "activities")

        harness.model.closeFromPointer()
        XCTAssertNil(harness.model.requestedTab)

        harness.model.openFromPointer(overActiveIsland: false)
        XCTAssertEqual(harness.model.requestedTab, "calendar")
    }

    @MainActor
    func testManualTabSelectionStopsAutomaticRequest() {
        let harness = PresentationHarness()
        harness.model.openFromPointer(overActiveIsland: true)
        XCTAssertEqual(harness.model.requestedTab, "activities")

        harness.model.recordUserTab("notes")

        XCTAssertNil(harness.model.requestedTab)
        harness.model.closeFromPointer()
        harness.model.openFromPointer(overActiveIsland: false)
        XCTAssertEqual(harness.model.requestedTab, "notes")
    }

    @MainActor
    func testEmptyIslandUsesInitialMediaTabAndCloseReturnsToIdle() {
        let harness = PresentationHarness()

        harness.model.openFromPointer(overActiveIsland: false)
        XCTAssertEqual(harness.model.requestedTab, "media")
        XCTAssertEqual(harness.model.state.mode, .expanded)

        harness.model.closeFromPointer()
        XCTAssertNil(harness.model.requestedTab)
        XCTAssertEqual(harness.model.state.mode, .idle)
    }
}

@MainActor
private final class PresentationHarness {
    let clock: MutableActivityClock
    let scheduler = ManualActivityScheduler()
    private(set) var expiredEvents: [AttentionEvent] = []
    var onAttentionExpired: ((AttentionEvent) -> Void)?

    lazy var model = NotchPresentationModel(
        clock: clock,
        scheduler: scheduler
    ) { [weak self] event in
        guard let self else { return }
        expiredEvents.append(event)
        onAttentionExpired?(event)
    }

    init(now: TimeInterval = 1_000) {
        clock = MutableActivityClock(now: date(now))
    }
}

private func display(
    primary: ActivitySnapshot? = nil,
    indicators: [ActivityIndicator] = [],
    hiddenIndicatorCount: Int = 0,
    attention: AttentionEvent? = nil
) -> ActivityDisplayState {
    ActivityDisplayState(
        allActivities: primary.map { [$0] } ?? [],
        primary: primary,
        indicators: indicators,
        hiddenIndicatorCount: hiddenIndicatorCount,
        attention: attention,
        diagnostics: [:]
    )
}

private func media(id: String = "track") -> ActivitySnapshot {
    ActivitySnapshot(
        id: .init(source: "media", local: id),
        sourceID: "media",
        kind: .media,
        phase: .active,
        title: "Трек",
        subtitle: "Исполнитель",
        progress: nil,
        deadline: nil,
        occurredAt: nil,
        availableActions: [.pause],
        containsSensitiveText: false
    )
}

private func attentionEvent(
    id: String,
    kind: AttentionEvent.Kind
) -> AttentionEvent {
    AttentionEvent(
        id: id,
        activityID: .init(source: "fixtures", local: id),
        kind: kind,
        occurredAt: date(900)
    )
}

private func date(_ interval: TimeInterval) -> Date {
    Date(timeIntervalSince1970: interval)
}
