import AppKit
import XCTest
@testable import Cyclop

@MainActor
final class NotchDropPayloadTests: XCTestCase {
    func testActivitiesIsFirstRightRailTabWithoutAutomaticKeyboard() {
        XCTAssertEqual(NotchViewModel.Tab.rightRail, [.activities, .notes, .teleprompter, .settings])
        XCTAssertTrue(NotchViewModel.Tab.activities.supportsKeyboard)
        XCTAssertFalse(NotchViewModel.Tab.activities.autoRequestsKeyboard)
    }

    func testRejectsRemoteURLsBecauseCyclopNoLongerDownloadsLinks() {
        let payload = NotchDropPayload.parse([
            item(.URL, "https://example.com/first.zip"),
            item(.string, "  HTTP://example.com/second.zip  "),
        ])

        XCTAssertNil(payload)
    }

    func testParsesFileURLsInPasteboardOrder() {
        let first = URL(fileURLWithPath: "/tmp/first.txt")
        let second = URL(fileURLWithPath: "/tmp/second.txt")

        let payload = NotchDropPayload.parse([
            item(.fileURL, first.absoluteString),
            item(.fileURL, second.absoluteString),
        ])

        XCTAssertEqual(payload, .files([first, second]))
    }

    func testRejectsWholePayloadWhenAnyItemIsNotAFile() {
        XCTAssertNil(NotchDropPayload.parse([
            item(.URL, "https://example.com/archive.zip"),
            item(.string, "это не ссылка"),
        ]))
    }

    func testRejectsNonFileURLs() {
        XCTAssertNil(NotchDropPayload.parse([
            item(.URL, "ftp://example.com/archive.zip"),
        ]))
    }

    func testAcceptsFileRepresentationWhenPasteboardAlsoContainsRemoteURL() {
        let pasteboardItem = NSPasteboardItem()
        pasteboardItem.setString("https://example.com/archive.zip", forType: .URL)
        pasteboardItem.setString(
            URL(fileURLWithPath: "/tmp/archive.zip").absoluteString,
            forType: .fileURL
        )

        XCTAssertEqual(
            NotchDropPayload.parse([pasteboardItem]),
            .files([URL(fileURLWithPath: "/tmp/archive.zip")])
        )
    }

    private func item(_ type: NSPasteboard.PasteboardType, _ value: String) -> NSPasteboardItem {
        let item = NSPasteboardItem()
        item.setString(value, forType: type)
        return item
    }
}
