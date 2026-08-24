import AppKit
import QuickLookUI
import XCTest
@testable import Cyclop

@MainActor
final class ShelfPreviewSystemAdapterTests: XCTestCase {
    func testShownPanelDisplaysRequestedItemInQuickLookView() throws {
        _ = NSApplication.shared
        let screenshot = try makeScreenshot(prefix: "cyclop-preview")
        defer { try? FileManager.default.removeItem(at: screenshot) }

        let presenter = QuickLookShelfPreviewPresenter()
        presenter.show(screenshot)
        defer { presenter.close() }
        let previewView = try XCTUnwrap(
            NSApp.windows
                .filter(\.isVisible)
                .compactMap { $0.contentView as? QLPreviewView }
                .first
        )

        let item = previewView.previewItem as? NSURL
        XCTAssertEqual(item as URL?, screenshot)
    }

    func testClosingPanelWithWindowButtonKeepsPresenterReusable() throws {
        _ = NSApplication.shared
        let screenshot = try makeScreenshot(prefix: "cyclop-preview-close")
        defer { try? FileManager.default.removeItem(at: screenshot) }

        let presenter = QuickLookShelfPreviewPresenter()
        presenter.show(screenshot)
        let panel = try XCTUnwrap(
            NSApp.windows.first { $0.isVisible && $0.contentView is QLPreviewView }
        )

        let closeButton = try XCTUnwrap(panel.standardWindowButton(.closeButton))
        closeButton.performClick(nil)

        XCTAssertFalse(presenter.isVisible)
        presenter.show(screenshot)
        XCTAssertTrue(presenter.isVisible)
        presenter.close()
    }

    private func makeScreenshot(prefix: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString).png")
        let png = try XCTUnwrap(Data(base64Encoded:
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
        ))
        try png.write(to: url)
        return url
    }
}
