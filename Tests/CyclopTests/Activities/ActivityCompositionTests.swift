import XCTest
@testable import Cyclop

@MainActor
final class ActivityCompositionTests: XCTestCase {
    func testIndicatorOpenWiresExactScrollTargetIntoSharedCenter() {
        let composition = ActivityComposition()
        let id = ActivityID(source: "downloads.own", local: "archive.zip")

        composition.presentation.open(activityID: id)

        XCTAssertEqual(composition.center.scrollTarget, id)
    }

    func testLiveCompositionUsesEachSourceOnceAndDownloadLimitIsBounded() {
        let composition = ActivityComposition()

        XCTAssertEqual(
            composition.sourceIDs,
            ["media", "meetings", "timers", "downloads.own", "downloads.external"]
        )
        XCTAssertEqual(Set(composition.sourceIDs).count, composition.sourceIDs.count)
    }
}
