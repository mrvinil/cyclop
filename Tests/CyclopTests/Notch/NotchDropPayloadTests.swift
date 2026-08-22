import AppKit
import XCTest
@testable import Cyclop

@MainActor
final class NotchDropPayloadTests: XCTestCase {
    func testActivitiesIsFirstRightRailTabWithoutAutomaticKeyboard() {
        XCTAssertEqual(NotchViewModel.Tab.rightRail, [.activities, .notes, .settings])
        XCTAssertTrue(NotchViewModel.Tab.activities.supportsKeyboard)
        XCTAssertFalse(NotchViewModel.Tab.activities.autoRequestsKeyboard)
    }

    func testParsesRemoteURLsInPasteboardOrder() {
        let payload = NotchDropPayload.parse([
            item(.URL, "https://example.com/first.zip"),
            item(.string, "  HTTP://example.com/second.zip  "),
        ])

        XCTAssertEqual(payload, .remoteURLs([
            URL(string: "https://example.com/first.zip")!,
            URL(string: "HTTP://example.com/second.zip")!,
        ]))
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

    func testRejectsMixedFileAndRemoteURLPayloadAtomically() {
        XCTAssertNil(NotchDropPayload.parse([
            item(.fileURL, URL(fileURLWithPath: "/tmp/archive.zip").absoluteString),
            item(.URL, "https://example.com/archive.zip"),
        ]))
    }

    func testRejectsWholePayloadWhenAnyItemIsInvalid() {
        XCTAssertNil(NotchDropPayload.parse([
            item(.URL, "https://example.com/archive.zip"),
            item(.string, "это не ссылка"),
        ]))
    }

    func testRejectsUnsupportedRemoteSchemes() {
        XCTAssertNil(NotchDropPayload.parse([
            item(.URL, "ftp://example.com/archive.zip"),
        ]))
    }

    func testPrefersValidRemoteRepresentationBeforeFileRepresentation() {
        let pasteboardItem = NSPasteboardItem()
        pasteboardItem.setString("https://example.com/archive.zip", forType: .URL)
        pasteboardItem.setString(
            URL(fileURLWithPath: "/tmp/archive.zip").absoluteString,
            forType: .fileURL
        )

        XCTAssertEqual(
            NotchDropPayload.parse([pasteboardItem]),
            .remoteURLs([URL(string: "https://example.com/archive.zip")!])
        )
    }

    private func item(_ type: NSPasteboard.PasteboardType, _ value: String) -> NSPasteboardItem {
        let item = NSPasteboardItem()
        item.setString(value, forType: type)
        return item
    }
}
