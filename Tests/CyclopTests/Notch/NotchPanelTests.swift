import AppKit
import XCTest
@testable import Cyclop

@MainActor
final class NotchPanelTests: XCTestCase {
    func testPanelDoesNotJoinOtherAppsFullScreenSpaces() {
        let panel = NotchPanel(contentRect: .init(x: 0, y: 0, width: 200, height: 100))

        XCTAssertTrue(panel.collectionBehavior.contains(.fullScreenNone))
    }
}
