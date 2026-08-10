import Foundation
import XCTest
@testable import Cyclop

final class NotchLayoutMetricsTests: XCTestCase {
    func testPhysicalVisibleSizesCoverAllPresentationModes() {
        let metrics = NotchLayoutMetrics(
            screenFrame: CGRect(x: 0, y: 0, width: 1512, height: 982),
            notchSize: CGSize(width: 179, height: 32),
            notchCenterX: 756,
            isPhysical: true
        )

        XCTAssertEqual(metrics.visibleSize(for: .idle), CGSize(width: 179, height: 32))
        XCTAssertEqual(metrics.visibleSize(for: .compact), CGSize(width: 315, height: 32))
        XCTAssertEqual(metrics.visibleSize(for: .attention), CGSize(width: 339, height: 60))
        XCTAssertEqual(metrics.visibleSize(for: .expanded), CGSize(width: 620, height: 208))
    }

    func testSyntheticVisibleSizesCoverAllPresentationModes() {
        let metrics = NotchLayoutMetrics(
            screenFrame: CGRect(x: 0, y: 0, width: 1440, height: 900),
            notchSize: CGSize(width: 180, height: 24),
            notchCenterX: 720,
            isPhysical: false
        )

        XCTAssertEqual(metrics.visibleSize(for: .idle), CGSize(width: 180, height: 24))
        XCTAssertEqual(metrics.visibleSize(for: .compact), CGSize(width: 260, height: 40))
        XCTAssertEqual(metrics.visibleSize(for: .attention), CGSize(width: 320, height: 56))
        XCTAssertEqual(metrics.visibleSize(for: .expanded), CGSize(width: 620, height: 208))
    }

    func testPhysicalWidthsClampAtSpecifiedBoundaries() {
        let screenFrame = CGRect(x: 0, y: 0, width: 1512, height: 982)

        let belowMinimum = NotchLayoutMetrics(
            screenFrame: screenFrame,
            notchSize: CGSize(width: 100, height: 32),
            notchCenterX: 756,
            isPhysical: true
        )
        XCTAssertEqual(belowMinimum.visibleSize(for: .compact).width, 260)
        XCTAssertEqual(belowMinimum.visibleSize(for: .attention).width, 300)

        let compactBoundaries = [
            NotchLayoutMetrics(
                screenFrame: screenFrame,
                notchSize: CGSize(width: 124, height: 32),
                notchCenterX: 756,
                isPhysical: true
            ),
            NotchLayoutMetrics(
                screenFrame: screenFrame,
                notchSize: CGSize(width: 204, height: 32),
                notchCenterX: 756,
                isPhysical: true
            ),
        ]
        XCTAssertEqual(compactBoundaries[0].visibleSize(for: .compact).width, 260)
        XCTAssertEqual(compactBoundaries[1].visibleSize(for: .compact).width, 340)

        let attentionBoundaries = [
            NotchLayoutMetrics(
                screenFrame: screenFrame,
                notchSize: CGSize(width: 140, height: 32),
                notchCenterX: 756,
                isPhysical: true
            ),
            NotchLayoutMetrics(
                screenFrame: screenFrame,
                notchSize: CGSize(width: 200, height: 32),
                notchCenterX: 756,
                isPhysical: true
            ),
        ]
        XCTAssertEqual(attentionBoundaries[0].visibleSize(for: .attention).width, 300)
        XCTAssertEqual(attentionBoundaries[1].visibleSize(for: .attention).width, 360)

        let aboveMaximum = NotchLayoutMetrics(
            screenFrame: screenFrame,
            notchSize: CGSize(width: 250, height: 32),
            notchCenterX: 756,
            isPhysical: true
        )
        XCTAssertEqual(aboveMaximum.visibleSize(for: .compact).width, 340)
        XCTAssertEqual(aboveMaximum.visibleSize(for: .attention).width, 360)
    }

    func testContentAndScreenRectsConvertNonZeroScreenOrigin() {
        let metrics = NotchLayoutMetrics(
            screenFrame: CGRect(x: 2560, y: 100, width: 1440, height: 900),
            notchSize: CGSize(width: 180, height: 24),
            notchCenterX: 3280,
            isPhysical: false
        )

        XCTAssertEqual(
            metrics.contentRect(for: .compact),
            CGRect(x: 220, y: 212, width: 260, height: 40)
        )
        XCTAssertEqual(
            metrics.screenRect(for: .compact),
            CGRect(x: 3150, y: 960, width: 260, height: 42)
        )
        XCTAssertEqual(
            metrics.contentRect(for: .expanded),
            CGRect(x: 40, y: 44, width: 620, height: 208)
        )
        XCTAssertEqual(
            metrics.screenRect(for: .expanded),
            CGRect(x: 2970, y: 792, width: 620, height: 210)
        )
    }

    func testRectsStayWithinFixedWindowAndDisplayHorizontalBounds() {
        let metrics = NotchLayoutMetrics(
            screenFrame: CGRect(x: -1728, y: -120, width: 1728, height: 1117),
            notchSize: CGSize(width: 179, height: 32),
            notchCenterX: -864,
            isPhysical: true
        )
        let windowBounds = CGRect(x: 0, y: 0, width: 700, height: 252)
        let screenFrame = CGRect(x: -1728, y: -120, width: 1728, height: 1117)

        for mode in allModes {
            let contentRect = metrics.contentRect(for: mode)
            XCTAssertGreaterThanOrEqual(contentRect.minX, windowBounds.minX)
            XCTAssertLessThanOrEqual(contentRect.maxX, windowBounds.maxX)
            XCTAssertGreaterThanOrEqual(contentRect.minY, windowBounds.minY)
            XCTAssertLessThanOrEqual(contentRect.maxY, windowBounds.maxY)

            let screenRect = metrics.screenRect(for: mode)
            XCTAssertGreaterThanOrEqual(screenRect.minX, screenFrame.minX)
            XCTAssertLessThanOrEqual(screenRect.maxX, screenFrame.maxX)
            XCTAssertGreaterThanOrEqual(screenRect.minY, screenFrame.minY)
            XCTAssertEqual(screenRect.maxY, screenFrame.maxY + 2)

            let hoverRect = metrics.hoverRect(for: mode)
            XCTAssertGreaterThanOrEqual(hoverRect.minX, screenFrame.minX)
            XCTAssertLessThanOrEqual(hoverRect.maxX, screenFrame.maxX)
            XCTAssertGreaterThanOrEqual(hoverRect.minY, screenFrame.minY)
            XCTAssertEqual(hoverRect.maxY, screenFrame.maxY + 2)
        }
    }

    func testPhysicalIdleAndExpandedHoverRectsPreserveExistingPadding() {
        let metrics = NotchLayoutMetrics(
            screenFrame: CGRect(x: 0, y: 0, width: 1512, height: 982),
            notchSize: CGSize(width: 179, height: 32),
            notchCenterX: 756,
            isPhysical: true
        )

        XCTAssertEqual(
            metrics.hoverRect(for: .idle),
            CGRect(x: 660.5, y: 946, width: 191, height: 38)
        )
        XCTAssertTrue(metrics.hoverRect(for: .idle).contains(metrics.screenRect(for: .idle)))
        XCTAssertEqual(
            metrics.hoverRect(for: .expanded),
            CGRect(x: 434, y: 762, width: 644, height: 222)
        )
        XCTAssertTrue(metrics.hoverRect(for: .expanded).contains(metrics.screenRect(for: .expanded)))
    }

    func testSyntheticIdleKeepsVisibleMenuBarDepthButUsesNarrowHoverTarget() {
        let metrics = NotchLayoutMetrics(
            screenFrame: CGRect(x: 0, y: 0, width: 1440, height: 900),
            notchSize: CGSize(width: 180, height: 24),
            notchCenterX: 720,
            isPhysical: false
        )

        XCTAssertEqual(metrics.visibleSize(for: .idle), CGSize(width: 180, height: 24))
        XCTAssertEqual(
            metrics.screenRect(for: .idle),
            CGRect(x: 630, y: 876, width: 180, height: 26)
        )
        XCTAssertEqual(
            metrics.hoverRect(for: .idle),
            CGRect(x: 624, y: 892, width: 192, height: 10)
        )
        XCTAssertFalse(metrics.hoverRect(for: .idle).contains(CGPoint(x: 720, y: 880)))
        XCTAssertTrue(metrics.hoverRect(for: .idle).contains(CGPoint(x: 720, y: 896)))
    }

    func testSyntheticCompactAndAttentionHoverBoundsMatchVisibleIsland() {
        let metrics = NotchLayoutMetrics(
            screenFrame: CGRect(x: 0, y: 0, width: 1440, height: 900),
            notchSize: CGSize(width: 180, height: 24),
            notchCenterX: 720,
            isPhysical: false
        )

        for mode in [NotchPresentationMode.compact, .attention] {
            let screenRect = metrics.screenRect(for: mode)
            let hoverRect = metrics.hoverRect(for: mode)
            XCTAssertEqual(hoverRect, screenRect)
            XCTAssertTrue(hoverRect.contains(CGPoint(x: hoverRect.midX, y: hoverRect.midY)))
            XCTAssertFalse(hoverRect.contains(CGPoint(x: hoverRect.minX - 0.5, y: hoverRect.midY)))
            XCTAssertFalse(hoverRect.contains(CGPoint(x: hoverRect.maxX + 0.5, y: hoverRect.midY)))
        }
    }

    private var allModes: [NotchPresentationMode] {
        [.idle, .compact, .attention, .expanded]
    }
}
