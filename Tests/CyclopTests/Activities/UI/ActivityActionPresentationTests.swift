import XCTest
@testable import Cyclop

final class ActivityActionPresentationTests: XCTestCase {
    func testEveryActionHasExactLocalizedLabelAndSystemSymbol() throws {
        let expected: [ActivityAction: (key: String, symbol: String)] = [
            .play: ("Play", "play.fill"),
            .pause: ("Pause", "pause.fill"),
            .previous: ("Previous", "backward.fill"),
            .next: ("Next", "forward.fill"),
            .join: ("Join", "video.fill"),
            .resume: ("Resume", "play.fill"),
            .cancel: ("Cancel", "xmark"),
            .dismiss: ("Dismiss", "xmark.circle"),
            .retry: ("Retry", "arrow.clockwise"),
            .restart: ("Restart", "arrow.counterclockwise"),
            .open: ("Open", "doc"),
            .reveal: ("Show in Finder", "folder")
        ]

        XCTAssertEqual(expected.count, ActivityAction.allCases.count)
        for action in ActivityAction.allCases {
            let presentation = try XCTUnwrap(expected[action])
            XCTAssertEqual(ActivityActionPresentation.labelKey(action), presentation.key)
            XCTAssertEqual(ActivityActionPresentation.symbol(action), presentation.symbol)
            XCTAssertFalse(ActivityActionPresentation.accessibilityHintKey(action).isEmpty)
        }
    }

    func testCardActionOrderFollowsVisualAndFocusOrder() {
        XCTAssertEqual(
            ActivityActionPresentation.ordered(
                [.next, .pause, .previous],
                for: .media
            ),
            [.previous, .pause, .next]
        )
        XCTAssertEqual(
            ActivityActionPresentation.ordered(
                [.restart, .dismiss],
                for: .timer
            ),
            [.dismiss, .restart]
        )
        XCTAssertEqual(
            ActivityActionPresentation.ordered(
                [.dismiss, .open, .reveal],
                for: .download
            ),
            [.open, .reveal, .dismiss]
        )
    }
}
