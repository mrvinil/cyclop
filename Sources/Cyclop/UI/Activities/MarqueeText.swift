import SwiftUI

struct MarqueePolicy: Equatable {
    let isOverflowing: Bool
    let isPlaying: Bool
    let reduceMotion: Bool

    var shouldAnimate: Bool { isOverflowing && isPlaying && !reduceMotion }
}

struct MarqueeText: View {
    let title: String
    let isPlaying: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var titleWidth: CGFloat = 0

    private let speed: CGFloat = 18
    private let gap: CGFloat = 26

    var body: some View {
        GeometryReader { geometry in
            let policy = MarqueePolicy(
                isOverflowing: titleWidth > geometry.size.width,
                isPlaying: isPlaying,
                reduceMotion: reduceMotion
            )
            if policy.shouldAnimate {
                TimelineView(.periodic(from: .now, by: 1 / 30)) { context in
                    scrollingText(in: geometry.size.width, at: context.date)
                }
            } else {
                measuredText
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .clipped()
        .frame(height: 18)
        .accessibilityLabel(Text(title))
    }

    private var measuredText: some View {
        Text(title)
            .font(.system(size: 12, weight: .semibold))
            .fixedSize(horizontal: true, vertical: false)
            .background(
                GeometryReader { proxy in
                    Color.clear.preference(key: MarqueeTitleWidthKey.self, value: proxy.size.width)
                }
            )
            .onPreferenceChange(MarqueeTitleWidthKey.self) { titleWidth = $0 }
    }

    private func scrollingText(in availableWidth: CGFloat, at date: Date) -> some View {
        let travel = titleWidth + gap
        let period = max(3, Double(travel / speed) + 1.2)
        let elapsed = date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: period)
        let movingDuration = period - 1.2
        let offset: CGFloat
        if elapsed < 0.6 {
            offset = 0
        } else if elapsed > 0.6 + movingDuration {
            offset = -travel
        } else {
            offset = -CGFloat((elapsed - 0.6) / movingDuration) * travel
        }
        return HStack(spacing: gap) {
            measuredText.fixedSize(horizontal: true, vertical: false)
            measuredText.fixedSize(horizontal: true, vertical: false)
        }
        .offset(x: offset)
        .frame(width: availableWidth, alignment: .leading)
    }
}

private struct MarqueeTitleWidthKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}
