import SwiftUI

struct MediaAnimationPolicy: Equatable {
    let mode: MediaAnimationMode
    let isPlaying: Bool
    let reduceMotion: Bool

    var cadence: TimeInterval? {
        guard isPlaying, !reduceMotion else { return nil }
        switch mode {
        case .static: return nil
        case .fluid: return nil
        }
    }

    var usesDisplayLinkedTimeline: Bool {
        mode == .fluid && isPlaying && !reduceMotion
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
        let wave = (sin(phase * 3 + Double(index) * 1.8) + 1) / 2
        return 7 + CGFloat(wave) * 12
    }
}
