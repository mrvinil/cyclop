import Foundation
import XCTest
@testable import Cyclop

@MainActor
final class ShelfPreviewCoordinatorTests: XCTestCase {
    func testHoveringCardEnablesSpaceHotKey() {
        let hotKey = ShelfPreviewHotKeyDouble()
        let preview = ShelfPreviewPresenterDouble()
        let coordinator = ShelfPreviewCoordinator(hotKey: hotKey, presenter: preview)

        coordinator.setHoveredURL(URL(fileURLWithPath: "/tmp/screenshot.png"))

        XCTAssertTrue(hotKey.isEnabled)
    }

    func testSpaceShowsHoveredCard() {
        let hotKey = ShelfPreviewHotKeyDouble()
        let preview = ShelfPreviewPresenterDouble()
        let coordinator = ShelfPreviewCoordinator(hotKey: hotKey, presenter: preview)
        let screenshot = URL(fileURLWithPath: "/tmp/screenshot.png")
        coordinator.setHoveredURL(screenshot)

        hotKey.press()

        XCTAssertEqual(preview.presentedURL, screenshot)
    }

    func testSecondSpaceClosesVisiblePreview() {
        let hotKey = ShelfPreviewHotKeyDouble()
        let preview = ShelfPreviewPresenterDouble()
        let coordinator = ShelfPreviewCoordinator(hotKey: hotKey, presenter: preview)
        coordinator.setHoveredURL(URL(fileURLWithPath: "/tmp/screenshot.png"))
        hotKey.press()

        hotKey.press()

        XCTAssertFalse(preview.isVisible)
        XCTAssertEqual(preview.closeCount, 1)
    }

    func testPreviewKeepsSpaceHotKeyAfterPointerLeaves() {
        let hotKey = ShelfPreviewHotKeyDouble()
        let preview = ShelfPreviewPresenterDouble()
        let coordinator = ShelfPreviewCoordinator(hotKey: hotKey, presenter: preview)
        coordinator.setHoveredURL(URL(fileURLWithPath: "/tmp/screenshot.png"))
        hotKey.press()

        coordinator.setHoveredURL(nil)

        XCTAssertTrue(hotKey.isEnabled)
        hotKey.press()
        XCTAssertFalse(preview.isVisible)
        XCTAssertFalse(hotKey.isEnabled)
    }

    func testMovingAcrossCardsDoesNotReplaceVisiblePreview() {
        let hotKey = ShelfPreviewHotKeyDouble()
        let preview = ShelfPreviewPresenterDouble()
        let coordinator = ShelfPreviewCoordinator(hotKey: hotKey, presenter: preview)
        let first = URL(fileURLWithPath: "/tmp/first.png")
        coordinator.setHoveredURL(first)
        hotKey.press()

        coordinator.setHoveredURL(URL(fileURLWithPath: "/tmp/second.png"))

        XCTAssertEqual(preview.presentedURL, first)
        XCTAssertEqual(preview.showCount, 1)
    }

    func testStopClosesPreviewAndReleasesSpaceHotKey() {
        let hotKey = ShelfPreviewHotKeyDouble()
        let preview = ShelfPreviewPresenterDouble()
        let coordinator = ShelfPreviewCoordinator(hotKey: hotKey, presenter: preview)
        coordinator.setHoveredURL(URL(fileURLWithPath: "/tmp/screenshot.png"))
        hotKey.press()

        coordinator.stop()

        XCTAssertFalse(preview.isVisible)
        XCTAssertFalse(hotKey.isEnabled)
    }

    func testRemovingHoveredItemReleasesSpaceHotKey() {
        let hotKey = ShelfPreviewHotKeyDouble()
        let preview = ShelfPreviewPresenterDouble()
        let coordinator = ShelfPreviewCoordinator(hotKey: hotKey, presenter: preview)
        let screenshot = URL(fileURLWithPath: "/tmp/screenshot.png")
        coordinator.setHoveredURL(screenshot)

        coordinator.updateAvailableURLs([])

        XCTAssertFalse(hotKey.isEnabled)
    }
}

@MainActor
private final class ShelfPreviewHotKeyDouble: ShelfPreviewHotKeyHandling {
    var onPress: (() -> Void)?
    private(set) var isEnabled = false

    func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
    }

    func press() {
        guard isEnabled else { return }
        onPress?()
    }
}

@MainActor
private final class ShelfPreviewPresenterDouble: ShelfPreviewPresenting {
    var onClose: (() -> Void)?
    private(set) var presentedURL: URL?
    private(set) var isVisible = false
    private(set) var showCount = 0
    private(set) var closeCount = 0

    func show(_ url: URL) {
        presentedURL = url
        isVisible = true
        showCount += 1
    }

    func close() {
        guard isVisible else { return }
        isVisible = false
        closeCount += 1
        onClose?()
    }
}
