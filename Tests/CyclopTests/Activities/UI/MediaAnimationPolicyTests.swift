import XCTest
@testable import Cyclop

final class MediaAnimationPolicyTests: XCTestCase {
    func testEveryStyleUsesDisplayTimelineOnlyDuringActivePlayback() {
        for style in MediaAnimationStyle.allCases {
            XCTAssertTrue(MediaAnimationPolicy(style: style, isPlaying: true, reduceMotion: false).usesDisplayLinkedTimeline)
            XCTAssertFalse(MediaAnimationPolicy(style: style, isPlaying: false, reduceMotion: false).usesDisplayLinkedTimeline)
            XCTAssertFalse(MediaAnimationPolicy(style: style, isPlaying: true, reduceMotion: true).usesDisplayLinkedTimeline)
        }
    }

    func testNilStyleNeverAllocatesTimeline() {
        XCTAssertFalse(MediaAnimationPolicy(style: nil, isPlaying: true, reduceMotion: false).usesDisplayLinkedTimeline)
    }
}
