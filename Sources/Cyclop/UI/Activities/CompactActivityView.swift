import SwiftUI

struct CompactActivityView: View {
    let state: ActivityDisplayState
    let settings: ActivitySettings
    let card: ActivityCardModel?

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .foregroundStyle(tint).font(.system(size: 11, weight: .semibold))
            if let card {
                Text(card.title).lineLimit(1).font(.system(size: 11.5, weight: .medium))
                if let countdown = card.countdown {
                    Text(formatTime(countdown)).monospacedDigit().foregroundStyle(Theme.secondary)
                }
                if card.kind == .media {
                    MediaEqualizerView(mode: settings.mediaAnimationMode, isPlaying: card.phase == .active)
                }
            } else {
                Text(localized("Activities")).font(.system(size: 11.5, weight: .medium))
            }
            Spacer(minLength: 0)
            Text(indicatorText).font(.system(size: 10, weight: .medium).monospacedDigit()).foregroundStyle(Theme.secondary)
        }
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
    }

    private var symbol: String { card?.kind == .timer ? "timer" : card?.kind == .download ? "arrow.down.circle.fill" : "music.note" }
    private var tint: Color { card?.kind == .timer ? .orange : card?.kind == .download ? .blue : .pink }
    private var indicatorText: String {
        let count = state.indicators.count + state.hiddenIndicatorCount
        return count > 0 ? "+\(count)" : ""
    }
}
