import AppKit
import SwiftUI

struct MarqueePolicy: Equatable {
    let isOverflowing: Bool
    let isPlaying: Bool
    let reduceMotion: Bool

    /// Название всегда проходит через компактное окно целиком, в том числе
    /// когда начало короткого названия уже помещается в него. О состоянии
    /// воспроизведения говорит эквалайзер справа.
    var shouldAnimate: Bool { !reduceMotion }
}

struct MarqueeText: View {
    let title: String
    let isPlaying: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var animationStart = Date()

    private let speed: CGFloat = 18
    private let gap: CGFloat = 26

    var body: some View {
        GeometryReader { geometry in
            let policy = MarqueePolicy(
                isOverflowing: measuredTitleWidth > geometry.size.width,
                isPlaying: isPlaying,
                reduceMotion: reduceMotion
            )
            Color.clear
                .overlay(alignment: .leading) {
                    if policy.shouldAnimate {
                        TimelineView(.animation) { context in
                            scrollingText(in: geometry.size.width, at: context.date)
                        }
                    } else {
                        trackLabel.frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
        }
        .clipped()
        .frame(height: 18)
        .onChange(of: title) { _, _ in animationStart = .now }
        .accessibilityLabel(Text(title))
    }

    private var trackLabel: some View {
        Text(title)
            .font(.system(size: 12, weight: .semibold))
            .fixedSize(horizontal: true, vertical: false)
    }

    /// Измерение должно быть независимо от ширины острова: GeometryReader в
    /// overlay получал ширину всей зоны, отчего между повторами появлялась
    /// длинная пустота вместо заданного промежутка.
    private var measuredTitleWidth: CGFloat {
        (title as NSString).size(withAttributes: [
            .font: NSFont.systemFont(ofSize: 12, weight: .semibold)
        ]).width
    }

    private func scrollingText(in availableWidth: CGFloat, at date: Date) -> some View {
        let travel = measuredTitleWidth + gap
        let period = max(3, Double(travel / speed) + 1.2)
        let elapsed = date.timeIntervalSince(animationStart).truncatingRemainder(dividingBy: period)
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
            trackLabel
            trackLabel
        }
        .offset(x: offset)
        .frame(width: availableWidth, alignment: .leading)
    }
}
