import SwiftUI

struct MediaAnimationPolicy: Equatable {
    let style: MediaAnimationStyle?
    let isPlaying: Bool
    let reduceMotion: Bool

    var usesDisplayLinkedTimeline: Bool {
        style != nil && isPlaying && !reduceMotion
    }
}

struct MediaEqualizerView: View {
    let style: MediaAnimationStyle
    let isPlaying: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let policy = MediaAnimationPolicy(style: style, isPlaying: isPlaying, reduceMotion: reduceMotion)
        if policy.usesDisplayLinkedTimeline {
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

        switch style {
        case .universal:
            level = normalized(sin(phase * 4.2 + offset) + sin(phase * 7.2 + offset * 1.7) * 0.28)
            minimum = 6
            amplitude = 13
        case .rockRiff:
            let riff = normalized(sin(phase * 10.8 + offset * 1.55) + sin(phase * 17.4 + offset * 0.8) * 0.34)
            let chug = (sin(phase * 7.2 + offset * 0.4) + 1) / 2
            level = min(riff * 0.72 + chug * 0.38, 1)
            minimum = 7
            amplitude = 14
        case .rockWall:
            level = normalized(sin(phase * 9.7 + offset * 1.4) + sin(phase * 17.2 + offset) * 0.48)
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
        case .punk:
            level = pulse(phase, speed: 12.5, offset: offset, sync: 3.0)
            minimum = 6
            amplitude = 15
        case .metal:
            level = min(1, 0.32 + pulse(phase, speed: 14.0, offset: offset, sync: 5.0))
            minimum = 9
            amplitude = 13
        case .alternativeIndie:
            level = normalized(sin(phase * 5.8 + offset) + sin(phase * 9.1 + offset * 0.55) * 0.42)
            minimum = 7
            amplitude = 12
        case .pop:
            level = normalized(sin(phase * 3.5 + offset * 0.65) + sin(phase * 6.0 + offset) * 0.20)
            minimum = 7
            amplitude = 11
        case .dance:
            level = pulse(phase, speed: 6.8, offset: offset, sync: 1.0)
            minimum = 6
            amplitude = 14
        case .techno:
            level = pulse(phase, speed: 7.2, offset: offset * 0.2, sync: 0.0)
            minimum = 7
            amplitude = 14
        case .breakbeat:
            level = brokenBeat(phase, offset: offset)
            minimum = 6
            amplitude = 15
        case .rap:
            level = pulse(phase, speed: 4.4, offset: offset * 1.4, sync: 0.0)
            minimum = 8
            amplitude = 12
        case .jazzBlues:
            level = normalized(sin(phase * 3.1 + offset * 1.35) + sin(phase * 5.3 + offset) * 0.30)
            minimum = 7
            amplitude = 10
        case .classical:
            level = normalized(sin(phase * 1.9 + offset * 0.52) + sin(phase * 3.0 + offset) * 0.18)
            minimum = 6
            amplitude = 12
        case .folk:
            level = normalized(sin(phase * 3.0 + offset * 0.9) + sin(phase * 4.6 + offset * 0.33) * 0.20)
            minimum = 7
            amplitude = 10
        case .cinematic:
            level = normalized(sin(phase * 2.2 + offset * 0.4) + sin(phase * 1.1) * 0.48)
            minimum = 8
            amplitude = 13
        }

        return minimum + CGFloat(level) * amplitude
    }

    private func normalized(_ value: Double) -> Double {
        min(max((value + 1) / 2, 0), 1)
    }

    private func pulse(_ phase: TimeInterval, speed: Double, offset: Double, sync: Double) -> Double {
        let kick = max(0, sin(phase * speed + sync))
        let bar = (sin(phase * speed * 0.5 + offset) + 1) / 2
        return min(max(kick * 0.72 + bar * 0.28, 0), 1)
    }

    private func brokenBeat(_ phase: TimeInterval, offset: Double) -> Double {
        let pattern: [Double] = [1, 0.28, 0.72, 0.14, 0.88, 0.38, 0.62]
        let index = Int(floor(phase * 5.6 + offset * 0.35)).quotientAndRemainder(dividingBy: pattern.count).remainder
        let swung = (sin(phase * 12.0 + offset) + 1) / 2
        return min(max(pattern[index] * 0.78 + swung * 0.22, 0), 1)
    }
}
