import Combine
import Foundation
import XCTest
@testable import Cyclop

@MainActor
final class MeetingActivitySourceTests: XCTestCase {
    func testCalendarActivityStatePublisherEmitsOnlyCommittedFieldPairs() {
        let calendar = CalendarStore(accessProvider: { .denied })
        var emissionCount = 0
        let observation = calendar.activityStatePublisher.sink { activityState in
            emissionCount += 1
            XCTAssertEqual(
                Self.accessName(activityState.access),
                Self.accessName(calendar.access)
            )
            XCTAssertEqual(activityState.meetings.map(\.id), calendar.meetings.map(\.id))
        }
        defer {
            calendar.stop()
            withExtendedLifetime(observation) {}
        }

        calendar.start()

        XCTAssertGreaterThanOrEqual(emissionCount, 1)
    }

    func testProductionInitializerConsumesCommittedCalendarStateWithoutPrompting() {
        let calendar = CalendarStore()
        let defaults = UserDefaults(suiteName: "MeetingActivitySourceTests.production")!
        defaults.removePersistentDomain(forName: "MeetingActivitySourceTests.production")
        let settings = ActivitySettings(defaults: defaults)
        let scheduler = MeetingSourceScheduler()
        let source = MeetingActivitySource(
            calendar: calendar,
            settings: settings,
            clock: MutableActivityClock(now: date(9, 50)),
            scheduler: scheduler
        )

        XCTAssertEqual(currentState(of: source), .init(snapshots: [], health: .available))
        XCTAssertEqual(Self.accessName(calendar.access), "notRequested")
        XCTAssertEqual(scheduler.activeEntryCount, 0)
    }

    func testUpcomingMeetingMapsEveryFieldWithoutExposingURL() throws {
        let harness = MeetingSourceHarness(now: date(9, 50), leadMinutes: 15)
        let link = try XCTUnwrap(URL(string: "https://meet.example/secret-room"))

        harness.send(.granted, meetings: [meeting(
            id: "42",
            title: "Планирование",
            start: date(10, 0),
            end: date(10, 30),
            link: link,
            provider: "Безопасный сервис"
        )])

        XCTAssertEqual(harness.latest, ActivitySourceState(
            snapshots: [ActivitySnapshot(
                id: ActivityID(source: "meetings", local: "42"),
                sourceID: "meetings",
                kind: .meeting,
                phase: .active,
                title: "Планирование",
                subtitle: "Безопасный сервис",
                progress: nil,
                deadline: date(10, 0),
                occurredAt: nil,
                availableActions: [.join],
                containsSensitiveText: true
            )],
            health: .available
        ))
        XCTAssertFalse(harness.latest.snapshots[0].title.contains(link.absoluteString))
        XCTAssertFalse(harness.latest.snapshots[0].subtitle.contains(link.absoluteString))
    }

    func testVisibleOverlapsArePreservedAndSortedByStartThenID() {
        let harness = MeetingSourceHarness(now: date(9, 50), leadMinutes: 15)

        harness.send(.granted, meetings: [
            meeting(id: "z", title: "Позже", start: date(10, 1), end: date(10, 40)),
            meeting(id: "b", title: "Второй", start: date(10, 0), end: date(10, 30)),
            meeting(id: "a", title: "Первый", start: date(10, 0), end: date(10, 20)),
        ])

        XCTAssertEqual(harness.latest.snapshots.map(\.id.local), ["a", "b", "z"])
    }

    func testNotRequestedIsAvailableAndDeniedUsesExactHealthWithoutSnapshotsOrWake() {
        let harness = MeetingSourceHarness(now: date(9, 50), leadMinutes: 15)
        let visible = meeting(id: "42", title: "Встреча", start: date(10, 0), end: date(10, 30))

        harness.send(.notRequested, meetings: [visible])
        XCTAssertEqual(harness.latest, .init(snapshots: [], health: .available))
        XCTAssertEqual(harness.scheduler.activeEntryCount, 0)

        harness.send(.denied, meetings: [visible])
        XCTAssertEqual(
            harness.latest,
            .init(snapshots: [], health: .unavailable(message: "Нет доступа к календарю"))
        )
        XCTAssertEqual(harness.scheduler.activeEntryCount, 0)
    }

    func testFirstGrantedDatasetIsBaselineWithoutPastMilestone() {
        let harness = MeetingSourceHarness(now: date(10, 5), leadMinutes: 15)

        harness.send(.granted, meetings: [
            meeting(id: "42", title: "Уже идёт", start: date(10, 0), end: date(10, 30)),
        ])

        XCTAssertNil(harness.latest.snapshots.first?.occurredAt)
    }

    func testEverySupportedLeadControlsVisibilityAndExactThresholdBoundary() {
        for (lead, expectedVisible, expectedBoundary) in [
            (5, false, date(9, 55)),
            (10, false, date(9, 50)),
            (15, false, date(9, 45)),
            (30, true, date(9, 59)),
        ] {
            let harness = MeetingSourceHarness(now: date(9, 40), leadMinutes: lead)
            harness.send(.granted, meetings: [
                meeting(id: "\(lead)", title: "Lead \(lead)", start: date(10, 0), end: date(10, 30)),
            ])

            XCTAssertEqual(!harness.latest.snapshots.isEmpty, expectedVisible, "lead=\(lead)")
            XCTAssertEqual(harness.scheduler.nextDate, expectedBoundary, "lead=\(lead)")
            XCTAssertEqual(harness.scheduler.activeEntryCount, 1, "lead=\(lead)")
        }
    }

    func testUnsupportedRuntimeLeadFallsBackToFifteenWithoutWritingPublisherBack() {
        let harness = MeetingSourceHarness(now: date(9, 40), leadMinutes: 99)
        harness.send(.granted, meetings: [
            meeting(id: "42", title: "Fallback", start: date(10, 0), end: date(10, 30)),
        ])

        XCTAssertEqual(harness.scheduler.nextDate, date(9, 45))
        XCTAssertEqual(harness.publishedLeadMinutes, 99)
    }

    func testLeadChangeRecomputesVisibilityWithoutStaleThresholdAttention() {
        let harness = MeetingSourceHarness(now: date(9, 40), leadMinutes: 5)
        let input = meeting(id: "42", title: "Новый lead", start: date(10, 0), end: date(10, 30))
        harness.send(.granted, meetings: [input])
        XCTAssertTrue(harness.latest.snapshots.isEmpty)

        harness.clock.now = date(9, 50)
        harness.updateLeadMinutes(15)

        XCTAssertEqual(harness.latest.snapshots.map(\.id.local), ["42"])
        XCTAssertNil(harness.latest.snapshots.first?.occurredAt)
        XCTAssertEqual(harness.scheduler.nextDate, date(9, 59))
    }

    func testOneWakeAdvancesThroughThresholdOneMinuteStartAndEnd() throws {
        let harness = MeetingSourceHarness(now: date(9, 40), leadMinutes: 15)
        harness.send(.granted, meetings: [
            meeting(id: "42", title: "Границы", start: date(10, 0), end: date(10, 30)),
        ])
        XCTAssertEqual(harness.scheduler.nextDate, date(9, 45))

        let beforeThreshold = harness.latest
        harness.fireNext()
        XCTAssertEqual(harness.latest.snapshots.first?.occurredAt, date(9, 45))
        XCTAssertEqual(harness.scheduler.nextDate, date(9, 59))
        XCTAssertEqual(harness.scheduler.activeEntryCount, 1)
        XCTAssertEqual(
            ActivityAttentionPolicy.events(
                previous: beforeThreshold.snapshots,
                current: harness.latest.snapshots,
                now: harness.clock.now
            ).map(\.id),
            ["meeting:42:threshold:35100"]
        )

        harness.fireNext()
        XCTAssertEqual(harness.latest.snapshots.first?.occurredAt, date(9, 59))
        XCTAssertEqual(harness.scheduler.nextDate, date(10, 0))

        harness.fireNext()
        XCTAssertEqual(harness.latest.snapshots.first?.occurredAt, date(10, 0))
        XCTAssertEqual(harness.scheduler.nextDate, date(10, 30))

        harness.fireNext()
        XCTAssertTrue(harness.latest.snapshots.isEmpty)
        XCTAssertNil(harness.scheduler.nextDate)
        XCTAssertEqual(harness.scheduler.activeEntryCount, 0)
    }

    func testReloadOfSameDatasetDoesNotReissueMilestone() {
        let harness = MeetingSourceHarness(now: date(9, 40), leadMinutes: 15)
        let input = meeting(id: "42", title: "Reload", start: date(10, 0), end: date(10, 30))
        harness.send(.granted, meetings: [input])
        harness.fireNext()
        XCTAssertEqual(harness.latest.snapshots.first?.occurredAt, date(9, 45))

        harness.send(.granted, meetings: [input])
        XCTAssertNil(harness.latest.snapshots.first?.occurredAt)
        harness.send(.granted, meetings: [input])
        XCTAssertNil(harness.latest.snapshots.first?.occurredAt)
    }

    func testSleepAcrossSeveralBoundariesEmitsOnlyLatestPolicyMilestoneAtItsDate() {
        let harness = MeetingSourceHarness(now: date(9, 40), leadMinutes: 15)
        harness.send(.granted, meetings: [
            meeting(id: "42", title: "Сон", start: date(10, 0), end: date(10, 30)),
        ])

        harness.clock.now = date(10, 5)
        harness.fireCurrentWake()

        XCTAssertEqual(harness.latest.snapshots.first?.occurredAt, date(10, 0))
        XCTAssertEqual(harness.scheduler.nextDate, date(10, 30))
    }

    func testRollbackNeverRearmsBoundaryAtOrBeforeMonotonicCursor() {
        let harness = MeetingSourceHarness(now: date(9, 40), leadMinutes: 15)
        let input = meeting(id: "42", title: "Rollback", start: date(10, 0), end: date(10, 30))
        harness.send(.granted, meetings: [input])
        harness.fireNext()
        XCTAssertEqual(harness.latest.snapshots.first?.occurredAt, date(9, 45))

        harness.clock.now = date(9, 40)
        harness.send(.granted, meetings: [input])

        XCTAssertNil(harness.latest.snapshots.first?.occurredAt)
        XCTAssertEqual(harness.scheduler.nextDate, date(9, 59))
        XCTAssertEqual(harness.scheduler.activeEntryCount, 1)
    }

    func testDeniedThenGrantedStartsNewBaselineWithoutStaleMilestone() {
        let harness = MeetingSourceHarness(now: date(9, 40), leadMinutes: 15)
        let input = meeting(id: "42", title: "Новый цикл", start: date(10, 0), end: date(10, 30))
        harness.send(.granted, meetings: [input])
        harness.send(.denied, meetings: [input])
        harness.clock.now = date(10, 5)

        harness.send(.granted, meetings: [input])

        XCTAssertNil(harness.latest.snapshots.first?.occurredAt)
        XCTAssertEqual(harness.scheduler.nextDate, date(10, 30))
    }

    func testJoinOpensSafeCustomURLExactlyOnceForMatchingVisibleMeeting() throws {
        let harness = MeetingSourceHarness(
            now: date(9, 50),
            leadMinutes: 15,
            isJoinable: { $0.scheme == "cyclop-call" }
        )
        let link = try XCTUnwrap(URL(string: "cyclop-call://room/42"))
        harness.send(.granted, meetings: [
            meeting(id: "42", title: "Custom", start: date(10, 0), end: date(10, 30), link: link),
        ])

        harness.perform(.join, activityID: .init(source: "meetings", local: "42"))

        XCTAssertEqual(harness.openedURLs, [link])
    }

    func testProductionJoinPolicyRejectsHTTPFileAndUnknownHTTPSAtMappingAndPerform() throws {
        let harness = MeetingSourceHarness(
            now: date(9, 50),
            leadMinutes: 15,
            isJoinable: MeetingLink.isJoinable
        )
        let links = [
            try XCTUnwrap(URL(string: "http://meet.google.com/unsafe")),
            URL(fileURLWithPath: "/tmp/meeting"),
            try XCTUnwrap(URL(string: "https://unknown.example/room")),
        ]

        for (index, link) in links.enumerated() {
            let id = "unsafe-\(index)"
            harness.send(.granted, meetings: [
                meeting(id: id, title: "Unsafe", start: date(10, 0), end: date(10, 30), link: link),
            ])
            XCTAssertEqual(harness.latest.snapshots.first?.availableActions, [])
            harness.perform(.join, activityID: .init(source: "meetings", local: id))
        }

        XCTAssertTrue(harness.openedURLs.isEmpty)
    }

    func testJoinRevalidatesURLAtPerformTime() throws {
        var validationCount = 0
        let harness = MeetingSourceHarness(
            now: date(9, 50),
            leadMinutes: 15,
            isJoinable: { _ in
                validationCount += 1
                return validationCount == 1
            }
        )
        let link = try XCTUnwrap(URL(string: "cyclop-call://room/42"))
        harness.send(.granted, meetings: [
            meeting(id: "42", title: "Double validation", start: date(10, 0), end: date(10, 30), link: link),
        ])
        XCTAssertEqual(harness.latest.snapshots.first?.availableActions, [.join])

        harness.perform(.join, activityID: .init(source: "meetings", local: "42"))

        XCTAssertEqual(validationCount, 2)
        XCTAssertTrue(harness.openedURLs.isEmpty)
    }

    func testForeignIDUnknownMeetingAndUnsupportedActionDoNotOpenURL() throws {
        let harness = MeetingSourceHarness(now: date(9, 50), leadMinutes: 15)
        let link = try XCTUnwrap(URL(string: "https://meet.google.com/room"))
        harness.send(.granted, meetings: [
            meeting(id: "42", title: "No-op", start: date(10, 0), end: date(10, 30), link: link),
        ])

        harness.perform(.join, activityID: .init(source: "media", local: "42"))
        harness.perform(.join, activityID: .init(source: "meetings", local: "unknown"))
        harness.perform(.open, activityID: .init(source: "meetings", local: "42"))

        XCTAssertTrue(harness.openedURLs.isEmpty)
    }

    func testCancelledStaleCallbackCannotReplaceCurrentWake() {
        let harness = MeetingSourceHarness(now: date(9, 40), leadMinutes: 15)
        harness.send(.granted, meetings: [
            meeting(id: "42", title: "Stale", start: date(10, 0), end: date(10, 30)),
        ])
        let staleIndex = 0
        harness.updateLeadMinutes(10)
        XCTAssertEqual(harness.scheduler.entries.count, 2)
        XCTAssertEqual(harness.scheduler.nextDate, date(9, 50))

        harness.scheduler.fire(index: staleIndex)

        XCTAssertEqual(harness.scheduler.entries.count, 2)
        XCTAssertEqual(harness.scheduler.activeEntryCount, 1)
        XCTAssertEqual(harness.scheduler.nextDate, date(9, 50))
    }

    func testCancelReentrantCallbackLeavesExactlyOneReplacementWake() {
        let inputs = CurrentValueSubject<MeetingSourceInput, Never>(
            .init(access: .notRequested, meetings: [])
        )
        let leads = CurrentValueSubject<Int, Never>(15)
        let clock = MutableActivityClock(now: date(9, 40))
        let scheduler = ReentrantCancelMeetingScheduler()
        let source = MeetingActivitySource(
            states: inputs.eraseToAnyPublisher(),
            leadMinutes: leads.eraseToAnyPublisher(),
            opener: { _ in },
            isJoinable: { _ in false },
            clock: clock,
            scheduler: scheduler
        )
        inputs.send(.init(access: .granted, meetings: [
            meeting(id: "42", title: "Reentrant cancel", start: date(10, 0), end: date(10, 30)),
        ]))
        XCTAssertEqual(scheduler.activeEntryCount, 1)

        leads.send(10)

        XCTAssertEqual(scheduler.activeEntryCount, 1)
        XCTAssertEqual(scheduler.nextDate, date(9, 50))
        withExtendedLifetime(source) {}
    }

    func testInlineDueRegistrationKeepsOnlyCurrentReturnedHandle() {
        let clock = MutableActivityClock(now: date(9, 40))
        let inputs = CurrentValueSubject<MeetingSourceInput, Never>(.init(
            access: .granted,
            meetings: [meeting(
                id: "42",
                title: "Inline",
                start: date(10, 0),
                end: date(10, 30)
            )]
        ))
        let scheduler = InlineFirstMeetingScheduler(clock: clock)
        let source = MeetingActivitySource(
            states: inputs.eraseToAnyPublisher(),
            leadMinutes: Just(15).eraseToAnyPublisher(),
            opener: { _ in },
            isJoinable: { _ in false },
            clock: clock,
            scheduler: scheduler
        )
        XCTAssertEqual(scheduler.activeEntryCount, 1)
        XCTAssertEqual(scheduler.nextDate, date(9, 59))

        inputs.send(.init(access: .denied, meetings: []))

        XCTAssertEqual(scheduler.activeEntryCount, 0)
        withExtendedLifetime(source) {}
    }

    func testReentrantStateSubscriberPreservesFIFOForPassiveSubscriber() {
        let inputs = CurrentValueSubject<MeetingSourceInput, Never>(
            .init(access: .notRequested, meetings: [])
        )
        let scheduler = MeetingSourceScheduler()
        let source = MeetingActivitySource(
            states: inputs.eraseToAnyPublisher(),
            leadMinutes: Just(15).eraseToAnyPublisher(),
            opener: { _ in },
            isJoinable: { _ in false },
            clock: MutableActivityClock(now: date(9, 50)),
            scheduler: scheduler
        )
        var reentrantStates: [String] = []
        let reentrant = source.statePublisher.sink { state in
            reentrantStates.append(Self.stateName(state))
            if !state.snapshots.isEmpty {
                inputs.send(.init(access: .denied, meetings: []))
            }
        }
        var passiveStates: [String] = []
        let passive = source.statePublisher.sink {
            passiveStates.append(Self.stateName($0))
        }

        inputs.send(.init(access: .granted, meetings: [
            meeting(id: "42", title: "FIFO", start: date(10, 0), end: date(10, 30)),
        ]))

        XCTAssertEqual(reentrantStates, ["available-empty", "available-visible", "denied-empty"])
        XCTAssertEqual(passiveStates, ["available-empty", "available-visible", "denied-empty"])
        XCTAssertEqual(scheduler.activeEntryCount, 0)
        withExtendedLifetime((reentrant, passive, source)) {}
    }

    func testSourceDeinitCancelsOwnedWake() async {
        let cancelled = expectation(description: "Meeting wake отменён при deinit")
        let scheduler = MeetingSourceScheduler()
        scheduler.onCancel = { cancelled.fulfill() }
        let inputs = CurrentValueSubject<MeetingSourceInput, Never>(.init(
            access: .granted,
            meetings: [meeting(id: "42", title: "Deinit", start: date(10, 0), end: date(10, 30))]
        ))
        weak var weakSource: MeetingActivitySource?
        var source: MeetingActivitySource? = MeetingActivitySource(
            states: inputs.eraseToAnyPublisher(),
            leadMinutes: Just(15).eraseToAnyPublisher(),
            opener: { _ in },
            isJoinable: { _ in false },
            clock: MutableActivityClock(now: date(9, 40)),
            scheduler: scheduler
        )
        weakSource = source
        XCTAssertEqual(scheduler.activeEntryCount, 1)

        source = nil

        await fulfillment(of: [cancelled], timeout: 1)
        XCTAssertNil(weakSource)
        XCTAssertEqual(scheduler.activeEntryCount, 0)
    }

    func testOffActorReleaseCancelsOwnedWakeOnMainActor() async {
        let cancelled = expectation(description: "Off-actor meeting wake отменён на MainActor")
        let scheduler = MeetingSourceScheduler()
        scheduler.onCancel = { cancelled.fulfill() }
        let inputs = CurrentValueSubject<MeetingSourceInput, Never>(.init(
            access: .granted,
            meetings: [meeting(id: "42", title: "Detached", start: date(10, 0), end: date(10, 30))]
        ))
        let start = date(9, 40)

        await Task.detached {
            let source = await MainActor.run {
                MeetingActivitySource(
                    states: inputs.eraseToAnyPublisher(),
                    leadMinutes: Just(15).eraseToAnyPublisher(),
                    opener: { _ in },
                    isJoinable: { _ in false },
                    clock: MutableActivityClock(now: start),
                    scheduler: scheduler
                )
            }
            withExtendedLifetime(source) {}
        }.value

        await fulfillment(of: [cancelled], timeout: 1)
        XCTAssertEqual(scheduler.activeEntryCount, 0)
    }

    private func meeting(
        id: String,
        title: String,
        start: Date,
        end: Date,
        link: URL? = nil,
        provider: String? = nil
    ) -> MeetingActivityInput {
        MeetingActivityInput(
            id: id,
            title: title,
            start: start,
            end: end,
            link: link,
            provider: provider
        )
    }

    private func date(_ hour: Int, _ minute: Int) -> Date {
        Date(timeIntervalSince1970: TimeInterval(hour * 3_600 + minute * 60))
    }

    private func currentState(of source: MeetingActivitySource) -> ActivitySourceState {
        var current: ActivitySourceState?
        let observation = source.statePublisher.sink { current = $0 }
        withExtendedLifetime(observation) {}
        return current!
    }

    private static func accessName(_ access: CalendarStore.Access) -> String {
        switch access {
        case .notRequested: "notRequested"
        case .granted: "granted"
        case .denied: "denied"
        }
    }

    private static func stateName(_ state: ActivitySourceState) -> String {
        switch state.health {
        case .available:
            state.snapshots.isEmpty ? "available-empty" : "available-visible"
        case .unavailable:
            "denied-empty"
        }
    }
}

@MainActor
private final class MeetingSourceHarness {
    private let inputs = CurrentValueSubject<MeetingSourceInput, Never>(
        .init(access: .notRequested, meetings: [])
    )
    private let leadMinutes: CurrentValueSubject<Int, Never>
    let clock: MutableActivityClock
    let scheduler = MeetingSourceScheduler()
    private let opener = MeetingURLRecorder()
    private let source: MeetingActivitySource
    private var observation: AnyCancellable?
    private(set) var latest = ActivitySourceState(snapshots: [], health: .available)

    var publishedLeadMinutes: Int { leadMinutes.value }

    var openedURLs: [URL] { opener.urls }

    init(
        now: Date,
        leadMinutes: Int,
        isJoinable: @escaping (URL) -> Bool = { $0.scheme == "https" }
    ) {
        clock = MutableActivityClock(now: now)
        self.leadMinutes = CurrentValueSubject(leadMinutes)
        source = MeetingActivitySource(
            states: inputs.eraseToAnyPublisher(),
            leadMinutes: self.leadMinutes.eraseToAnyPublisher(),
            opener: { [opener] in opener.urls.append($0) },
            isJoinable: isJoinable,
            clock: clock,
            scheduler: scheduler
        )
        observation = source.statePublisher.sink { [weak self] in
            self?.latest = $0
        }
    }

    func send(_ access: MeetingSourceInput.Access, meetings: [MeetingActivityInput]) {
        inputs.send(.init(access: access, meetings: meetings))
    }

    func updateLeadMinutes(_ value: Int) {
        leadMinutes.send(value)
    }

    func perform(_ action: ActivityAction, activityID: ActivityID) {
        source.perform(action, activityID: activityID)
    }

    func fireNext() {
        guard let nextDate = scheduler.nextDate else {
            XCTFail("Нет запланированной meeting boundary")
            return
        }
        clock.now = nextDate
        scheduler.fireNext()
    }

    func fireCurrentWake() {
        scheduler.fireNext()
    }
}

private final class MeetingURLRecorder {
    var urls: [URL] = []
}

@MainActor
private final class MeetingSourceScheduler: ActivityScheduling {
    final class Cancellation: ActivityCancellation {
        private(set) var isCancelled = false

        var isFinished = false
        var onCancel: (@MainActor () -> Void)?

        func cancel() {
            guard !isCancelled else { return }
            isCancelled = true
            onCancel?()
        }
    }

    struct Entry {
        let date: Date
        let action: @MainActor () -> Void
        let cancellation: Cancellation
    }

    private(set) var entries: [Entry] = []
    var onCancel: (@MainActor () -> Void)?

    var activeEntryCount: Int {
        entries.filter { !$0.cancellation.isCancelled && !$0.cancellation.isFinished }.count
    }

    var nextDate: Date? {
        entries
            .filter { !$0.cancellation.isCancelled && !$0.cancellation.isFinished }
            .map(\.date)
            .min()
    }

    func schedule(
        at date: Date,
        _ action: @escaping @MainActor () -> Void
    ) -> ActivityCancellation {
        let cancellation = Cancellation()
        cancellation.onCancel = onCancel
        entries.append(.init(date: date, action: action, cancellation: cancellation))
        return cancellation
    }

    func fireNext() {
        guard let index = entries.indices
            .filter({
                !entries[$0].cancellation.isCancelled
                    && !entries[$0].cancellation.isFinished
            })
            .min(by: { entries[$0].date < entries[$1].date }) else {
            XCTFail("Нет active meeting wake")
            return
        }
        entries[index].cancellation.isFinished = true
        entries[index].action()
    }

    func fire(index: Int) {
        entries[index].action()
    }
}

@MainActor
private final class ReentrantCancelMeetingScheduler: ActivityScheduling {
    final class Cancellation: ActivityCancellation {
        let action: @MainActor () -> Void
        private var didCallAction = false
        private(set) var isCancelled = false

        init(action: @escaping @MainActor () -> Void) {
            self.action = action
        }

        func cancel() {
            isCancelled = true
            guard !didCallAction else { return }
            didCallAction = true
            action()
        }
    }

    struct Entry {
        let date: Date
        let cancellation: Cancellation
    }

    private(set) var entries: [Entry] = []

    var activeEntryCount: Int { entries.filter { !$0.cancellation.isCancelled }.count }
    var nextDate: Date? {
        entries.filter { !$0.cancellation.isCancelled }.map(\.date).min()
    }

    func schedule(
        at date: Date,
        _ action: @escaping @MainActor () -> Void
    ) -> ActivityCancellation {
        let cancellation = Cancellation(action: action)
        entries.append(.init(date: date, cancellation: cancellation))
        return cancellation
    }
}

@MainActor
private final class InlineFirstMeetingScheduler: ActivityScheduling {
    final class Cancellation: ActivityCancellation {
        private(set) var isCancelled = false
        var isFinished = false

        func cancel() { isCancelled = true }
    }

    struct Entry {
        let date: Date
        let cancellation: Cancellation
    }

    private let clock: MutableActivityClock
    private var didFireInline = false
    private(set) var entries: [Entry] = []

    init(clock: MutableActivityClock) {
        self.clock = clock
    }

    var activeEntryCount: Int {
        entries.filter { !$0.cancellation.isCancelled && !$0.cancellation.isFinished }.count
    }

    var nextDate: Date? {
        entries
            .filter { !$0.cancellation.isCancelled && !$0.cancellation.isFinished }
            .map(\.date)
            .min()
    }

    func schedule(
        at date: Date,
        _ action: @escaping @MainActor () -> Void
    ) -> ActivityCancellation {
        let cancellation = Cancellation()
        entries.append(.init(date: date, cancellation: cancellation))
        if !didFireInline {
            didFireInline = true
            clock.now = date
            cancellation.isFinished = true
            action()
        }
        return cancellation
    }
}
