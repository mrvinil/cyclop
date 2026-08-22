import SwiftUI

struct MediaAnimationPolicy: Equatable {
    let mode: MediaAnimationMode
    let isPlaying: Bool
    let reduceMotion: Bool

    var cadence: TimeInterval? {
        guard isPlaying, !reduceMotion else { return nil }
        switch mode {
        case .off, .universal, .rockHits, .rockWall, .electronic, .lofi: return nil
        }
    }

    var usesDisplayLinkedTimeline: Bool {
        mode != .off && isPlaying && !reduceMotion
    }
}

struct MediaEqualizerView: View {
    let mode: MediaAnimationMode
    let isPlaying: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let policy = MediaAnimationPolicy(mode: mode, isPlaying: isPlaying, reduceMotion: reduceMotion)
        if mode == .off {
            EmptyView()
        } else if let cadence = policy.cadence {
            TimelineView(.periodic(from: .now, by: cadence)) { context in
                bars(phase: context.date.timeIntervalSinceReferenceDate)
            }
        } else if policy.usesDisplayLinkedTimeline {
            TimelineView(.animation) { context in
                bars(phase: context.date.timeIntervalSinceReferenceDate)
            }
        } else {
            bars(phase: 0)
        }
    }

    private func bars(phase: TimeInterval) -> some View {
        HStack(spacing: 3) {
            ForEach(0 ..< 4, id: \.self) { index in
                Capsule().fill(.pink.opacity(0.95))
                    .frame(width: 3, height: height(index: index, phase: phase))
            }
        }
        .frame(width: 24, height: 22, alignment: .center)
        .accessibilityHidden(true)
    }

    private func height(index: Int, phase: TimeInterval) -> CGFloat {
        guard phase != 0 else { return [8, 16, 11, 18][index] }

        let offset = Double(index) * 1.8
        let level: Double
        let minimum: CGFloat
        let amplitude: CGFloat

        switch mode {
        case .off:
            return 0
        case .universal:
            level = normalized(sin(phase * 4.2 + offset) + sin(phase * 7.2 + offset * 1.7) * 0.28)
            minimum = 6
            amplitude = 13
        case .rockHits:
            let strike = pow(max(0, sin(phase * 12.5)), 4)
            let variation = (sin(phase * 25 + offset * 2.1) + 1) / 2
            level = min(strike * 0.86 + variation * 0.28, 1)
            minimum = 4
            amplitude = 17
        case .rockWall:
            level = normalized(sin(phase * 6.9 + offset * 1.4) + sin(phase * 12.2 + offset) * 0.48)
            minimum = 9
            amplitude = 12
        case .electronic:
            let beat = (sin(phase * 5.2) + 1) / 2
            let wave = (sin(phase * 4.5 + offset * 0.8) + 1) / 2
            level = beat * 0.62 + wave * 0.38
            minimum = 6
            amplitude = 14
        case .lofi:
            level = normalized(sin(phase * 2.7 + offset * 0.72) + sin(phase * 4.1 + offset) * 0.16)
            minimum = 8
            amplitude = 9
        }

        return minimum + CGFloat(level) * amplitude
    }

    private func normalized(_ value: Double) -> Double {
        min(max((value + 1) / 2, 0), 1)
    }
}
