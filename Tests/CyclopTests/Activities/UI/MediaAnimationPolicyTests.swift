import XCTest
@testable import Cyclop

final class MediaAnimationPolicyTests: XCTestCase {
    func testModesRespectPlaybackAndReduceMotion() {
        XCTAssertNil(MediaAnimationPolicy(mode: .static, isPlaying: true, reduceMotion: false).cadence)
        XCTAssertNil(MediaAnimationPolicy(mode: .fluid, isPlaying: true, reduceMotion: false).cadence)
        XCTAssertTrue(MediaAnimationPolicy(mode: .fluid, isPlaying: true, reduceMotion: false).usesDisplayLinkedTimeline)
        XCTAssertNil(MediaAnimationPolicy(mode: .fluid, isPlaying: true, reduceMotion: true).cadence)
        XCTAssertFalse(MediaAnimationPolicy(mode: .fluid, isPlaying: false, reduceMotion: false).usesDisplayLinkedTimeline)
    }
}
