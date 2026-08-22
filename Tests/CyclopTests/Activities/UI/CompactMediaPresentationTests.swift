import XCTest
@testable import Cyclop

final class CompactMediaPresentationTests: XCTestCase {
    func testMarqueeRunsForOverflowingTrackEvenWhenPlaybackIsPaused() {
        XCTAssertTrue(MarqueePolicy(isOverflowing: true, isPlaying: true, reduceMotion: false).shouldAnimate)
        XCTAssertFalse(MarqueePolicy(isOverflowing: false, isPlaying: true, reduceMotion: false).shouldAnimate)
        XCTAssertTrue(MarqueePolicy(isOverflowing: true, isPlaying: false, reduceMotion: false).shouldAnimate)
        XCTAssertFalse(MarqueePolicy(isOverflowing: true, isPlaying: true, reduceMotion: true).shouldAnimate)
    }
}
