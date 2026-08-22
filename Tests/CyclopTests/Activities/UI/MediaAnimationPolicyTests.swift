import XCTest
@testable import Cyclop

final class MediaAnimationPolicyTests: XCTestCase {
    func testModesRespectPlaybackAndReduceMotion() {
        XCTAssertNil(MediaAnimationPolicy(mode: .static, isPlaying: true, reduceMotion: false).cadence)
        XCTAssertEqual(MediaAnimationPolicy(mode: .slow, isPlaying: true, reduceMotion: false).cadence, 0.8)
        XCTAssertEqual(MediaAnimationPolicy(mode: .fluid, isPlaying: true, reduceMotion: false).cadence, 0.25)
        XCTAssertNil(MediaAnimationPolicy(mode: .fluid, isPlaying: true, reduceMotion: true).cadence)
        XCTAssertNil(MediaAnimationPolicy(mode: .slow, isPlaying: false, reduceMotion: false).cadence)
    }
}
