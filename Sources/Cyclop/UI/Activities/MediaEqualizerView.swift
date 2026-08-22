import SwiftUI

struct MediaAnimationPolicy: Equatable {
    let mode: MediaAnimationMode
    let isPlaying: Bool
    let reduceMotion: Bool

    var cadence: TimeInterval? {
        guard isPlaying, !reduceMotion else { return nil }
        switch mode {
        case .static: return nil
        case .slow: return 0.8
        case .fluid: return 0.25
        }
    }
}

struct MediaEqualizerView: View {
    let mode: MediaAnimationMode
    let isPlaying: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let policy = MediaAnimationPolicy(mode: mode, isPlaying: isPlaying, reduceMotion: reduceMotion)
        if let cadence = policy.cadence {
            TimelineView(.periodic(from: .now, by: cadence)) { context in
                bars(phase: context.date.timeIntervalSinceReferenceDate)
            }
        } else {
            bars(phase: 0)
        }
    }

    private func bars(phase: TimeInterval) -> some View {
        HStack(spacing: 2) {
            ForEach(0 ..< 3, id: \.self) { index in
                Capsule().fill(.white.opacity(0.85))
                    .frame(width: 2.5, height: height(index: index, phase: phase))
            }
        }
        .frame(width: 13, height: 14, alignment: .center)
        .accessibilityHidden(true)
    }

    private func height(index: Int, phase: TimeInterval) -> CGFloat {
        guard phase != 0 else { return [6, 12, 8][index] }
        let wave = (sin(phase * 3 + Double(index) * 1.8) + 1) / 2
        return 5 + CGFloat(wave) * 8
    }
}
