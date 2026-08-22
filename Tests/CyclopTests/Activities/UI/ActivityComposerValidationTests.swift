import XCTest
@testable import Cyclop

final class ActivityComposerValidationTests: XCTestCase {
    func testTimerComposerOffersTheApprovedMinutePresets() {
        XCTAssertEqual(TimerComposerDraft.presetMinutes, [5, 10, 25, 45, 60])
    }

    func testTimerComposerNormalizesCustomHoursMinutesAndSeconds() throws {
        let draft = TimerComposerDraft(name: "Фокус", hours: "1", minutes: "2", seconds: "3")

        XCTAssertEqual(try draft.duration(), 3_723)
    }

    func testTimerComposerRejectsZeroAndOverLimitDurations() {
        XCTAssertThrowsError(try TimerComposerDraft().duration()) {
            XCTAssertEqual($0 as? TimerComposerDraftError, .invalidDuration)
        }
        XCTAssertThrowsError(
            try TimerComposerDraft(hours: "100", minutes: "0", seconds: "0").duration()
        ) {
            XCTAssertEqual($0 as? TimerComposerDraftError, .invalidDuration)
        }
    }

    func testTimerComposerUsesLocalizedDefaultForWhitespaceOnlyName() {
        let draft = TimerComposerDraft(name: " \n\t ", hours: "0", minutes: "5", seconds: "0")

        XCTAssertEqual(draft.normalizedName, localized("Timer"))
    }

}
