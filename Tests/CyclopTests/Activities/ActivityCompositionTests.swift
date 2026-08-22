import XCTest
@testable import Cyclop

@MainActor
final class ActivityCompositionTests: XCTestCase {
    func testIndicatorOpenWiresExactScrollTargetIntoSharedCenter() {
        let composition = ActivityComposition()
        let id = ActivityID(source: "downloads.external", local: "archive.zip")

        composition.presentation.open(activityID: id)

        XCTAssertEqual(composition.center.scrollTarget, id)
    }

    func testLiveCompositionUsesOnlyExternalDownloadSource() {
        let composition = ActivityComposition()

        XCTAssertEqual(
            composition.sourceIDs,
            ["media", "meetings", "timers", "downloads.external"]
        )
        XCTAssertEqual(Set(composition.sourceIDs).count, composition.sourceIDs.count)
    }
}
