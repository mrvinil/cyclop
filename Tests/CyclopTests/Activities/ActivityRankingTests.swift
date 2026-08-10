import Foundation
import XCTest
@testable import Cyclop

final class ActivityRankingTests: XCTestCase {
    func testPriorityOrderMatchesSpecification() {
        let cases = [
            PriorityCase(id: "media", kind: .media, phase: .active),
            PriorityCase(id: "completed-download", kind: .download, phase: .completed),
            PriorityCase(id: "active-download", kind: .download, phase: .active),
            PriorityCase(id: "active-timer", kind: .timer, phase: .active),
            PriorityCase(id: "failed-download", kind: .download, phase: .failed),
            PriorityCase(id: "meeting", kind: .meeting, phase: .ambient),
            PriorityCase(id: "completed-timer", kind: .timer, phase: .completed)
        ]

        XCTAssertEqual(ActivityRanking.sorted(cases.map(makeSnapshot)).map(\.id.local), [
            "completed-timer", "meeting", "failed-download", "active-timer", "active-download", "media", "completed-download"
        ])
    }

    func testSortUsesDeadlineThenOccurrenceThenIdentifierToBreakTies() {
        let snapshots = [
            makeSnapshot(id: "zeta", kind: .timer, phase: .active, occurredAt: 300),
            makeSnapshot(id: "nil-deadline", kind: .timer, phase: .active, occurredAt: 999),
            makeSnapshot(id: "beta", kind: .timer, phase: .active, deadline: 100, occurredAt: 200),
            makeSnapshot(id: "alpha", kind: .timer, phase: .active, deadline: 100, occurredAt: 200),
            makeSnapshot(id: "early-deadline", kind: .timer, phase: .active, deadline: 50, occurredAt: 1),
            makeSnapshot(id: "newer", kind: .timer, phase: .active, deadline: 100, occurredAt: 300)
        ]

        XCTAssertEqual(ActivityRanking.sorted(snapshots).map(\.id.local), [
            "early-deadline", "newer", "alpha", "beta", "nil-deadline", "zeta"
        ])
    }

    func testSortIncludesPausedMediaButExcludesPausedTimerDownloadAndUnrankedActivities() {
        let snapshots = [
            makeSnapshot(id: "active-timer", kind: .timer, phase: .active),
            makeSnapshot(id: "paused-meeting", kind: .meeting, phase: .paused),
            makeSnapshot(id: "paused-timer", kind: .timer, phase: .paused),
            makeSnapshot(id: "paused-download", kind: .download, phase: .paused),
            makeSnapshot(id: "paused-media", kind: .media, phase: .paused),
            makeSnapshot(id: "ambient-timer", kind: .timer, phase: .ambient),
            makeSnapshot(id: "attention-media", kind: .media, phase: .attention)
        ]

        XCTAssertEqual(ActivityRanking.sorted(snapshots).map(\.id.local), [
            "active-timer", "attention-media", "paused-media"
        ])
    }

    func testIndicatorsKeepAllSecondaryActivitiesWhenThereAreAtMostThree() {
        let cases: [(snapshots: [ActivitySnapshot], expectedIDs: [String], hiddenCount: Int)] = [
            ([], [], 0),
            ([makeSnapshot(id: "1", kind: .timer, phase: .active)], ["1"], 0),
            ([
                makeSnapshot(id: "1", kind: .timer, phase: .active),
                makeSnapshot(id: "2", kind: .download, phase: .active)
            ], ["1", "2"], 0),
            ([
                makeSnapshot(id: "1", kind: .timer, phase: .active),
                makeSnapshot(id: "2", kind: .download, phase: .active),
                makeSnapshot(id: "3", kind: .media, phase: .active)
            ], ["1", "2", "3"], 0)
        ]

        for testCase in cases {
            let result = ActivityRanking.indicators(afterPrimary: testCase.snapshots)

            XCTAssertEqual(result.items.map(\.activityID.local), testCase.expectedIDs)
            XCTAssertEqual(result.hiddenCount, testCase.hiddenCount)
        }
    }

    func testFourSecondaryActivitiesUseTwoIndicatorsAndOverflowSlot() {
        let result = ActivityRanking.indicators(afterPrimary: [
            makeSnapshot(id: "1", kind: .timer, phase: .active),
            makeSnapshot(id: "2", kind: .timer, phase: .active),
            makeSnapshot(id: "3", kind: .download, phase: .active),
            makeSnapshot(id: "4", kind: .media, phase: .active)
        ])

        XCTAssertEqual(result.items.map(\.activityID.local), ["1", "2"])
        XCTAssertEqual(result.hiddenCount, 2)
    }

    private func makeSnapshot(_ testCase: PriorityCase) -> ActivitySnapshot {
        makeSnapshot(id: testCase.id, kind: testCase.kind, phase: testCase.phase)
    }

    private func makeSnapshot(
        id: String,
        kind: ActivityKind,
        phase: ActivityPhase,
        deadline: TimeInterval? = nil,
        occurredAt: TimeInterval? = nil
    ) -> ActivitySnapshot {
        ActivitySnapshot(
            id: ActivityID(source: "test", local: id),
            sourceID: "test",
            kind: kind,
            phase: phase,
            title: id,
            subtitle: "",
            progress: nil,
            deadline: deadline.map(Date.init(timeIntervalSince1970:)),
            occurredAt: occurredAt.map(Date.init(timeIntervalSince1970:)),
            availableActions: [],
            containsSensitiveText: false
        )
    }
}

private struct PriorityCase {
    let id: String
    let kind: ActivityKind
    let phase: ActivityPhase
}
