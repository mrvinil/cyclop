import Foundation
import XCTest
@testable import Cyclop

final class ActivityAttentionTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "ActivityAttentionTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    func testAttentionDurationsMatchEachEventContract() {
        XCTAssertEqual(AttentionEvent.Kind.meetingThreshold.duration, 5)
        XCTAssertEqual(AttentionEvent.Kind.meetingOneMinute.duration, 5)
        XCTAssertEqual(AttentionEvent.Kind.meetingStarted.duration, 5)
        XCTAssertEqual(AttentionEvent.Kind.timerCompleted.duration, 10)
        XCTAssertEqual(AttentionEvent.Kind.downloadFailed.duration, 8)
        XCTAssertEqual(AttentionEvent.Kind.downloadCompleted.duration, 5)
    }

    func testLedgerPersistsDeduplicationAndExpiresAnIDOnlyAfter24Hours() {
        let clock = MutableActivityClock(now: date(1_000))
        let event = AttentionEvent(
            id: "meeting:42:threshold:1000",
            activityID: ActivityID(source: "meetings", local: "42"),
            kind: .meetingThreshold,
            occurredAt: clock.now
        )

        XCTAssertTrue(ActivityAttentionLedger(defaults: defaults, clock: clock).claim(event))
        XCTAssertFalse(ActivityAttentionLedger(defaults: defaults, clock: clock).claim(event))

        clock.advance(by: 86_400)
        XCTAssertFalse(ActivityAttentionLedger(defaults: defaults, clock: clock).claim(event))

        clock.advance(by: 1)
        XCTAssertTrue(ActivityAttentionLedger(defaults: defaults, clock: clock).claim(event))
    }

    func testLedgerPrunesExpiredPersistedEntriesWhenClaimingAnotherEvent() throws {
        defaults.set([
            "expired": 13_599.0,
            "boundary": 13_600.0,
            "recent": 99_999.0
        ], forKey: "activities.attentionLedger")
        let clock = MutableActivityClock(now: date(100_000))
        let event = AttentionEvent(
            id: "timer:timers:tea:completed:90000",
            activityID: ActivityID(source: "timers", local: "tea"),
            kind: .timerCompleted,
            occurredAt: date(90_000)
        )

        XCTAssertTrue(ActivityAttentionLedger(defaults: defaults, clock: clock).claim(event))

        let stored = try XCTUnwrap(defaults.dictionary(forKey: "activities.attentionLedger"))
        XCTAssertNil(stored["expired"])
        XCTAssertEqual(stored["boundary"] as? Double, 13_600)
        XCTAssertEqual(stored["recent"] as? Double, 99_999)
        XCTAssertEqual(stored[event.id] as? Double, 100_000)
    }

    func testTimerCompletionIsEmittedOnlyOnTransitionWithStableSnapshotID() {
        let active = snapshot(id: "tea", kind: .timer, phase: .active)
        let completed = snapshot(id: "tea", kind: .timer, phase: .completed, occurredAt: 1_000)

        let first = ActivityAttentionPolicy.events(
            previous: [active],
            current: [completed],
            now: date(1_001)
        )
        let repeatedWithAnotherEvaluationTime = ActivityAttentionPolicy.events(
            previous: [active],
            current: [completed],
            now: date(2_000)
        )

        XCTAssertEqual(first, [AttentionEvent(
            id: "timer:4#test:3#tea:completed:1000",
            activityID: completed.id,
            kind: .timerCompleted,
            occurredAt: date(1_000)
        )])
        XCTAssertEqual(repeatedWithAnotherEvaluationTime, first)
        XCTAssertTrue(ActivityAttentionPolicy.events(
            previous: [completed],
            current: [completed],
            now: date(2_000)
        ).isEmpty)
    }

    func testTerminalIDsEncodeFullActivityIDWithoutDelimiterCollisions() {
        let first = snapshot(
            id: "c",
            source: "a:b",
            kind: .timer,
            phase: .completed,
            occurredAt: 1_000
        )
        let second = snapshot(
            id: "b:c",
            source: "a",
            kind: .timer,
            phase: .completed,
            occurredAt: 1_000
        )

        let events = ActivityAttentionPolicy.events(
            previous: [],
            current: [first, second],
            now: date(1_000)
        )

        XCTAssertEqual(events.map(\.id), [
            "timer:3#a:b:1#c:completed:1000",
            "timer:1#a:3#b:c:completed:1000"
        ])
    }

    func testTransitionMatchingUsesFullActivityIDInsteadOfLocalComponent() {
        let previous = snapshot(
            id: "shared",
            source: "timers.first",
            kind: .timer,
            phase: .completed,
            occurredAt: 1_000
        )
        let current = snapshot(
            id: "shared",
            source: "timers.second",
            kind: .timer,
            phase: .completed,
            occurredAt: 1_000
        )

        XCTAssertEqual(ActivityAttentionPolicy.events(
            previous: [previous],
            current: [current],
            now: date(1_000)
        ).map(\.activityID), [current.id])
    }

    func testFirstTerminalSnapshotWithOccurrenceProducesAttention() {
        let failed = snapshot(
            id: "first-failure",
            source: "downloads.external",
            kind: .download,
            phase: .failed,
            occurredAt: 1_500
        )

        XCTAssertEqual(ActivityAttentionPolicy.events(
            previous: [],
            current: [failed],
            now: date(1_500)
        ), [AttentionEvent(
            id: "download:18#downloads.external:13#first-failure:failed:1500",
            activityID: failed.id,
            kind: .downloadFailed,
            occurredAt: date(1_500)
        )])
    }

    func testDownloadFailureAndCompletionAreEmittedOnlyOnTransitions() {
        let active = snapshot(id: "archive", kind: .download, phase: .active)
        let failed = snapshot(id: "archive", kind: .download, phase: .failed, occurredAt: 2_000)
        let completed = snapshot(id: "archive", kind: .download, phase: .completed, occurredAt: 3_000)

        XCTAssertEqual(ActivityAttentionPolicy.events(
            previous: [active],
            current: [failed],
            now: date(2_000)
        ), [AttentionEvent(
            id: "download:4#test:7#archive:failed:2000",
            activityID: failed.id,
            kind: .downloadFailed,
            occurredAt: date(2_000)
        )])

        XCTAssertTrue(ActivityAttentionPolicy.events(
            previous: [failed],
            current: [failed],
            now: date(2_500)
        ).isEmpty)

        XCTAssertEqual(ActivityAttentionPolicy.events(
            previous: [active],
            current: [completed],
            now: date(3_000)
        ), [AttentionEvent(
            id: "download:4#test:7#archive:completed:3000",
            activityID: completed.id,
            kind: .downloadCompleted,
            occurredAt: date(3_000)
        )])

        XCTAssertTrue(ActivityAttentionPolicy.events(
            previous: [completed],
            current: [completed],
            now: date(3_500)
        ).isEmpty)
    }

    func testMeetingMilestonesDeriveKindsAndStableIDsFromTheirBoundaries() {
        let ordinary = snapshot(
            id: "42",
            source: "meetings",
            kind: .meeting,
            phase: .active,
            deadline: 2_000
        )
        let milestones: [(occurredAt: TimeInterval, kind: AttentionEvent.Kind, id: String)] = [
            (1_100, .meetingThreshold, "meeting:42:threshold:1100"),
            (1_940, .meetingOneMinute, "meeting:42:oneMinute:1940"),
            (2_000, .meetingStarted, "meeting:42:started:2000")
        ]

        for milestone in milestones {
            let current = snapshot(
                id: "42",
                source: "meetings",
                kind: .meeting,
                phase: .active,
                deadline: 2_000,
                occurredAt: milestone.occurredAt
            )
            let event = AttentionEvent(
                id: milestone.id,
                activityID: current.id,
                kind: milestone.kind,
                occurredAt: date(milestone.occurredAt)
            )

            XCTAssertEqual(ActivityAttentionPolicy.events(
                previous: [ordinary],
                current: [current],
                now: date(milestone.occurredAt)
            ), [event])
            XCTAssertTrue(ActivityAttentionPolicy.events(
                previous: [current],
                current: [current],
                now: date(milestone.occurredAt + 30)
            ).isEmpty)
        }
    }

    func testMeetingMilestonesRequireCanonicalMeetingSourceAndActivityIDSource() {
        let wrongActivitySource = snapshot(
            id: "42",
            source: "calendar",
            sourceID: "meetings",
            kind: .meeting,
            phase: .active,
            deadline: 2_000,
            occurredAt: 1_940
        )
        let wrongRoutingSource = snapshot(
            id: "42",
            source: "meetings",
            sourceID: "calendar",
            kind: .meeting,
            phase: .active,
            deadline: 2_000,
            occurredAt: 1_940
        )

        XCTAssertTrue(ActivityAttentionPolicy.events(
            previous: [],
            current: [wrongActivitySource, wrongRoutingSource],
            now: date(1_940)
        ).isEmpty)
    }

    func testNearMeetingBoundariesRemainThresholdMilestones() throws {
        let ordinary = snapshot(
            id: "boundary",
            source: "meetings",
            kind: .meeting,
            phase: .active,
            deadline: 2_000
        )
        let nearBoundaries: [TimeInterval] = [
            1_940.001,
            1_939.999,
            1_999.999,
            2_000.001
        ]

        for occurredAt in nearBoundaries {
            let milestone = snapshot(
                id: "boundary",
                source: "meetings",
                kind: .meeting,
                phase: .active,
                deadline: 2_000,
                occurredAt: occurredAt
            )
            let event = try XCTUnwrap(ActivityAttentionPolicy.events(
                previous: [ordinary],
                current: [milestone],
                now: date(occurredAt)
            ).first)

            XCTAssertEqual(event.kind, .meetingThreshold, "occurredAt=\(occurredAt)")
        }
    }

    func testMultipleSimultaneousEventsPreserveCurrentSnapshotOrder() {
        let completedDownload = snapshot(
            id: "download",
            source: "downloads.external",
            kind: .download,
            phase: .completed,
            occurredAt: 4_000
        )
        let unsupportedMedia = snapshot(
            id: "media",
            source: "media",
            kind: .media,
            phase: .completed,
            occurredAt: 4_000
        )
        let startedMeeting = snapshot(
            id: "meeting",
            source: "meetings",
            kind: .meeting,
            phase: .active,
            deadline: 4_000,
            occurredAt: 4_000
        )
        let completedTimer = snapshot(
            id: "timer",
            source: "timers",
            kind: .timer,
            phase: .completed,
            occurredAt: 4_000
        )

        let events = ActivityAttentionPolicy.events(
            previous: [],
            current: [completedDownload, unsupportedMedia, startedMeeting, completedTimer],
            now: date(4_000)
        )

        XCTAssertEqual(events.map(\.activityID), [
            completedDownload.id,
            startedMeeting.id,
            completedTimer.id
        ])
        XCTAssertEqual(events.map(\.kind), [
            .downloadCompleted,
            .meetingStarted,
            .timerCompleted
        ])
    }

    func testPolicyRequiresDeterministicOccurrenceAndIgnoresUnsupportedTerminalStates() {
        let snapshots = [
            snapshot(id: "timer", kind: .timer, phase: .completed),
            snapshot(id: "download", kind: .download, phase: .failed),
            snapshot(id: "media", kind: .media, phase: .completed, occurredAt: 4_000),
            snapshot(id: "failed-timer", kind: .timer, phase: .failed, occurredAt: 4_000)
        ]

        XCTAssertTrue(ActivityAttentionPolicy.events(
            previous: [],
            current: snapshots,
            now: date(5_000)
        ).isEmpty)
    }

    private func snapshot(
        id: String,
        source: String = "test",
        sourceID: String? = nil,
        kind: ActivityKind,
        phase: ActivityPhase,
        deadline: TimeInterval? = nil,
        occurredAt: TimeInterval? = nil
    ) -> ActivitySnapshot {
        ActivitySnapshot(
            id: ActivityID(source: source, local: id),
            sourceID: sourceID ?? source,
            kind: kind,
            phase: phase,
            title: id,
            subtitle: "",
            progress: nil,
            deadline: deadline.map(date),
            occurredAt: occurredAt.map(date),
            availableActions: [],
            containsSensitiveText: false
        )
    }

    private func date(_ interval: TimeInterval) -> Date {
        Date(timeIntervalSince1970: interval)
    }
}
