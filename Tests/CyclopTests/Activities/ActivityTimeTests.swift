import XCTest
@testable import Cyclop

final class ActivityTimeTests: XCTestCase {
    func testMutableClockAdvancesDeterministically() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let clock = MutableActivityClock(now: start)
        clock.advance(by: 15)
        XCTAssertEqual(clock.now, start.addingTimeInterval(15))
    }
}
