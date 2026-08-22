import XCTest
@testable import Cyclop

final class CompactMediaPresentationTests: XCTestCase {
    func testMarqueeRunsForEveryTrackEvenWhenPlaybackIsPaused() {
        XCTAssertTrue(MarqueePolicy(isOverflowing: true, isPlaying: true, reduceMotion: false).shouldAnimate)
        XCTAssertTrue(MarqueePolicy(isOverflowing: false, isPlaying: true, reduceMotion: false).shouldAnimate)
        XCTAssertTrue(MarqueePolicy(isOverflowing: true, isPlaying: false, reduceMotion: false).shouldAnimate)
        XCTAssertFalse(MarqueePolicy(isOverflowing: true, isPlaying: true, reduceMotion: true).shouldAnimate)
    }

    func testCompactPresentationUsesResolvedStyleInsteadOfSettingsMode() {
        let presentation = GenreAnimationPresentation(
            style: .metal,
            genreLabel: "Металл",
            isAutomatic: true
        )

        XCTAssertEqual(CompactMediaPresentation.equalizerStyle(for: presentation), .metal)
    }
}
