import XCTest
@testable import Cyclop

final class MediaAnimationPolicyTests: XCTestCase {
    func testOnlyActivePresetsUseDisplayLinkedTimelineDuringPlayback() {
        XCTAssertFalse(MediaAnimationPolicy(mode: .off, isPlaying: true, reduceMotion: false).usesDisplayLinkedTimeline)

        for mode in [MediaAnimationMode.universal, .rockRiff, .rockWall, .electronic, .lofi] {
            XCTAssertTrue(MediaAnimationPolicy(mode: mode, isPlaying: true, reduceMotion: false).usesDisplayLinkedTimeline)
            XCTAssertFalse(MediaAnimationPolicy(mode: mode, isPlaying: false, reduceMotion: false).usesDisplayLinkedTimeline)
            XCTAssertFalse(MediaAnimationPolicy(mode: mode, isPlaying: true, reduceMotion: true).usesDisplayLinkedTimeline)
        }
    }
}
