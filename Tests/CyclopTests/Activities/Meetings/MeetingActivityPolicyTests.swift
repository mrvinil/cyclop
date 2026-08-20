import Foundation
import XCTest
@testable import Cyclop

final class MeetingActivityPolicyTests: XCTestCase {
    func testMeetingPresentationUsesAmbientAndActivePhasesAtVisibilityBoundaries() {
        let meeting = fixture(start: date(10, 0), end: date(10, 30))
        let policy = MeetingActivityPolicy(leadMinutes: 15)

        let cases: [(now: Date, previousEvaluation: Date?, expected: MeetingPresentation)] = [
            (
                date(9, 44, 59),
                nil,
                MeetingPresentation(
                    isVisible: false,
                    phase: .ambient,
                    milestone: nil,
                    milestoneDate: nil,
                    nextBoundary: date(9, 45)
                )
            ),
            (
                date(9, 45),
                date(9, 44, 59),
                MeetingPresentation(
                    isVisible: true,
                    phase: .active,
                    milestone: .threshold,
                    milestoneDate: date(9, 45),
                    nextBoundary: date(9, 59)
                )
            ),
            (
                date(10, 0),
                date(9, 59, 59),
                MeetingPresentation(
                    isVisible: true,
                    phase: .active,
                    milestone: .started,
                    milestoneDate: date(10, 0),
                    nextBoundary: date(10, 30)
                )
            ),
            (
                date(10, 30),
                date(10, 29, 59),
                MeetingPresentation(
                    isVisible: false,
                    phase: .ambient,
                    milestone: nil,
                    milestoneDate: nil,
                    nextBoundary: nil
                )
            )
        ]

        for testCase in cases {
            XCTAssertEqual(
                policy.presentation(
                    for: meeting,
                    now: testCase.now,
                    previousEvaluation: testCase.previousEvaluation
                ),
                testCase.expected
            )
        }
    }

    func testMilestonesAndNextBoundariesAtEverySupportedLeadBoundary() {
        let start = date(10, 0)
        let end = date(10, 30)
        let meeting = fixture(start: start, end: end)
        let cases: [(leadMinutes: Int, milestone: MeetingMilestone, boundary: Date, nextBoundary: Date)] = [
            (5, .threshold, start.addingTimeInterval(-5 * 60), start.addingTimeInterval(-60)),
            (10, .threshold, start.addingTimeInterval(-10 * 60), start.addingTimeInterval(-60)),
            (15, .threshold, start.addingTimeInterval(-15 * 60), start.addingTimeInterval(-60)),
            (30, .threshold, start.addingTimeInterval(-30 * 60), start.addingTimeInterval(-60))
        ]

        for testCase in cases {
            let policy = MeetingActivityPolicy(leadMinutes: testCase.leadMinutes)
            let oneMinute = start.addingTimeInterval(-60)
            let boundaries: [(milestone: MeetingMilestone?, date: Date, isVisible: Bool, nextBoundary: Date?)] = [
                (testCase.milestone, testCase.boundary, true, testCase.nextBoundary),
                (.oneMinute, oneMinute, true, start),
                (.started, start, true, end),
                (nil, end, false, nil)
            ]

            for boundary in boundaries {
                let presentation = policy.presentation(
                    for: meeting,
                    now: boundary.date,
                    previousEvaluation: boundary.date.addingTimeInterval(-1)
                )

                XCTAssertEqual(presentation.isVisible, boundary.isVisible, "lead=\(testCase.leadMinutes), date=\(boundary.date)")
                XCTAssertEqual(presentation.milestone, boundary.milestone, "lead=\(testCase.leadMinutes), date=\(boundary.date)")
                XCTAssertEqual(presentation.milestoneDate, boundary.milestone == nil ? nil : boundary.date, "lead=\(testCase.leadMinutes), date=\(boundary.date)")
                XCTAssertEqual(presentation.nextBoundary, boundary.nextBoundary, "lead=\(testCase.leadMinutes), date=\(boundary.date)")
            }
        }
    }

    func testExactOneSecondMarginsAroundEveryBoundary() {
        let start = date(10, 0)
        let end = date(10, 30)
        let meeting = fixture(start: start, end: end)

        for leadMinutes in [5, 10, 15, 30] {
            let policy = MeetingActivityPolicy(leadMinutes: leadMinutes)
            let boundaries = [
                start.addingTimeInterval(TimeInterval(-leadMinutes * 60)),
                start.addingTimeInterval(-60),
                start,
                end
            ]

            for boundary in boundaries {
                let before = policy.presentation(for: meeting, now: boundary.addingTimeInterval(-1))
                let at = policy.presentation(for: meeting, now: boundary)
                let after = policy.presentation(for: meeting, now: boundary.addingTimeInterval(1))

                XCTAssertEqual(before.isVisible, boundary > start.addingTimeInterval(TimeInterval(-leadMinutes * 60)), "lead=\(leadMinutes), before=\(boundary)")
                XCTAssertEqual(at.isVisible, boundary < end, "lead=\(leadMinutes), at=\(boundary)")
                XCTAssertEqual(after.isVisible, boundary.addingTimeInterval(1) < end, "lead=\(leadMinutes), after=\(boundary)")
            }
        }
    }

    func testInitialEvaluationDoesNotReplayPastMilestone() {
        let meeting = fixture(start: date(10, 0), end: date(10, 30))
        let presentation = MeetingActivityPolicy(leadMinutes: 15).presentation(
            for: meeting,
            now: date(9, 59)
        )

        XCTAssertTrue(presentation.isVisible)
        XCTAssertNil(presentation.milestone)
        XCTAssertNil(presentation.milestoneDate)
        XCTAssertEqual(presentation.nextBoundary, date(10, 0))
    }

    func testOneMinuteLeadDoesNotDuplicateThresholdMilestone() {
        let meeting = fixture(start: date(10, 0), end: date(10, 30))
        let oneMinute = date(9, 59)
        let presentation = MeetingActivityPolicy(leadMinutes: 1).presentation(
            for: meeting,
            now: oneMinute,
            previousEvaluation: oneMinute.addingTimeInterval(-1)
        )

        XCTAssertEqual(presentation.milestone, .oneMinute)
        XCTAssertEqual(presentation.milestoneDate, oneMinute)
    }

    func testClockJumpReturnsLatestMilestoneAtItsActualBoundaryDate() {
        let meeting = fixture(start: date(10, 0), end: date(10, 30))
        let presentation = MeetingActivityPolicy(leadMinutes: 15).presentation(
            for: meeting,
            now: date(10, 5),
            previousEvaluation: date(9, 44)
        )

        XCTAssertEqual(
            presentation,
            MeetingPresentation(
                isVisible: true,
                phase: .active,
                milestone: .started,
                milestoneDate: date(10, 0),
                nextBoundary: date(10, 30)
            )
        )
    }

    func testClockJumpAfterEndKeepsLatestMilestoneButHidesMeeting() {
        let meeting = fixture(start: date(10, 0), end: date(10, 30))
        let presentation = MeetingActivityPolicy(leadMinutes: 15).presentation(
            for: meeting,
            now: date(10, 31),
            previousEvaluation: date(9, 44)
        )

        XCTAssertEqual(
            presentation,
            MeetingPresentation(
                isVisible: false,
                phase: .ambient,
                milestone: .started,
                milestoneDate: date(10, 0),
                nextBoundary: nil
            )
        )
    }

    func testPreviousEvaluationOnBoundaryDoesNotReemitIt() {
        let meeting = fixture(start: date(10, 0), end: date(10, 30))
        let threshold = date(9, 45)
        let presentation = MeetingActivityPolicy(leadMinutes: 15).presentation(
            for: meeting,
            now: threshold.addingTimeInterval(1),
            previousEvaluation: threshold
        )

        XCTAssertNil(presentation.milestone)
        XCTAssertNil(presentation.milestoneDate)
    }

    func testRollbackOrEqualEvaluationDoesNotEmitMilestone() {
        let meeting = fixture(start: date(10, 0), end: date(10, 30))
        let now = date(9, 45)
        let policy = MeetingActivityPolicy(leadMinutes: 15)

        XCTAssertNil(policy.presentation(for: meeting, now: now, previousEvaluation: now).milestone)
        XCTAssertNil(policy.presentation(for: meeting, now: now, previousEvaluation: now.addingTimeInterval(1)).milestone)
    }

    func testInvalidMeetingFailsClosed() {
        let invalidMeetings = [
            fixture(start: date(10, 0), end: date(10, 0)),
            fixture(start: date(10, 0), end: date(9, 59))
        ]
        let policy = MeetingActivityPolicy(leadMinutes: 15)

        for meeting in invalidMeetings {
            XCTAssertEqual(
                policy.presentation(for: meeting, now: date(10, 0), previousEvaluation: date(9, 44)),
                MeetingPresentation(
                    isVisible: false,
                    phase: .ambient,
                    milestone: nil,
                    milestoneDate: nil,
                    nextBoundary: nil
                )
            )
        }
    }

    func testPresentationIsEquatableForStableInputs() {
        let meeting = fixture(start: date(10, 0), end: date(10, 30))
        let policy = MeetingActivityPolicy(leadMinutes: 15)

        XCTAssertEqual(
            policy.presentation(for: meeting, now: date(9, 45), previousEvaluation: date(9, 44, 59)),
            policy.presentation(for: meeting, now: date(9, 45), previousEvaluation: date(9, 44, 59))
        )
    }

    private func fixture(start: Date, end: Date) -> MeetingActivityInput {
        MeetingActivityInput(
            id: "meeting-42",
            title: "Синхронизация",
            start: start,
            end: end,
            link: URL(string: "https://example.com/meeting"),
            provider: "Google Meet"
        )
    }

    private func date(_ hour: Int, _ minute: Int, _ second: Int = 0) -> Date {
        Date(timeIntervalSince1970: TimeInterval(hour * 3_600 + minute * 60 + second))
    }
}
