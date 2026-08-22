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

    func testDownloadComposerTrimsOnePastedHTTPOrHTTPSURL() throws {
        let http = DownloadComposerDraft(urlText: " \nhttp://example.com/archive.zip\t ")
        let https = DownloadComposerDraft(urlText: " https://example.com/archive.zip ")

        XCTAssertEqual(http.trimmedURL, "http://example.com/archive.zip")
        XCTAssertEqual(https.trimmedURL, "https://example.com/archive.zip")
        XCTAssertNoThrow(try DownloadRequestParser.parse(http.trimmedURL))
        XCTAssertNoThrow(try DownloadRequestParser.parse(https.trimmedURL))
    }

    func testDownloadComposerRejectsMultipleLinesFileURLsAndMissingSchemes() {
        for value in [
            "https://example.com/first.zip\nhttps://example.com/second.zip",
            "file:///tmp/archive.zip",
            "example.com/archive.zip",
        ] {
            XCTAssertThrowsError(try DownloadRequestParser.parse(DownloadComposerDraft(urlText: value).trimmedURL))
        }
    }
}
