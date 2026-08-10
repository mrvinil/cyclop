import Foundation

/// Pure notch layout formulas, independent of `NSScreen` and AppKit state.
struct NotchLayoutMetrics {
    let screenFrame: CGRect
    let notchSize: CGSize
    let notchCenterX: CGFloat
    let isPhysical: Bool

    static let expandedSize = CGSize(width: 620, height: 208)
    static let windowHorizontalPadding: CGFloat = 40
    static let windowBottomPadding: CGFloat = 44

    var windowSize: CGSize {
        CGSize(
            width: Self.expandedSize.width + 2 * Self.windowHorizontalPadding,
            height: Self.expandedSize.height + Self.windowBottomPadding
        )
    }

    var windowFrame: CGRect {
        CGRect(
            x: notchCenterX - windowSize.width / 2,
            y: screenFrame.maxY - windowSize.height,
            width: windowSize.width,
            height: windowSize.height
        )
    }

    var collapsedDepth: CGFloat { isPhysical ? notchSize.height : 8 }

    var collapsedTargetSize: CGSize {
        CGSize(width: notchSize.width, height: collapsedDepth)
    }

    var warmZone: CGRect {
        includingTopEdge(CGRect(
            x: screenFrame.minX,
            y: screenFrame.maxY - 260,
            width: screenFrame.width,
            height: 260
        ))
    }

    func visibleSize(for mode: NotchPresentationMode) -> CGSize {
        switch mode {
        case .idle:
            return notchSize
        case .compact:
            return isPhysical
                ? CGSize(width: clamped(notchSize.width + 136, from: 260, through: 340), height: notchSize.height)
                : CGSize(width: 260, height: notchSize.height + 16)
        case .attention:
            return isPhysical
                ? CGSize(width: clamped(notchSize.width + 160, from: 300, through: 360), height: notchSize.height + 28)
                : CGSize(width: 320, height: notchSize.height + 32)
        case .expanded:
            return Self.expandedSize
        }
    }

    func contentRect(for mode: NotchPresentationMode) -> CGRect {
        contentRect(for: visibleSize(for: mode))
    }

    func contentRect(for size: CGSize) -> CGRect {
        CGRect(
            x: (windowSize.width - size.width) / 2,
            y: windowSize.height - size.height,
            width: size.width,
            height: size.height
        )
    }

    func screenRect(for mode: NotchPresentationMode) -> CGRect {
        screenRect(for: visibleSize(for: mode))
    }

    func screenRect(for size: CGSize) -> CGRect {
        includingTopEdge(contentRect(for: size).offsetBy(dx: windowFrame.minX, dy: windowFrame.minY))
    }

    func hoverRect(for mode: NotchPresentationMode) -> CGRect {
        switch mode {
        case .idle:
            return includingTopEdge(CGRect(
                x: notchCenterX - notchSize.width / 2 - 6,
                y: screenFrame.maxY - collapsedDepth - (isPhysical ? 4 : 0),
                width: notchSize.width + 12,
                height: collapsedDepth + (isPhysical ? 4 : 0)
            ))
        case .compact, .attention:
            return screenRect(for: mode)
        case .expanded:
            return includingTopEdge(CGRect(
                x: notchCenterX - Self.expandedSize.width / 2 - 12,
                y: screenFrame.maxY - Self.expandedSize.height - 12,
                width: Self.expandedSize.width + 24,
                height: Self.expandedSize.height + 12
            ))
        }
    }

    private func includingTopEdge(_ rect: CGRect) -> CGRect {
        guard rect.maxY >= screenFrame.maxY else { return rect }
        return CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height + 2)
    }

    private func clamped(_ value: CGFloat, from lowerBound: CGFloat, through upperBound: CGFloat) -> CGFloat {
        min(max(value, lowerBound), upperBound)
    }
}
