import SwiftUI

struct AttentionActivityView: View {
    let event: AttentionEvent
    let card: ActivityCardModel?

    var body: some View {
        VStack(spacing: 3) {
            Text(card?.title ?? localized("Activities")).lineLimit(1).font(.system(size: 12, weight: .semibold))
            Text(status).font(.system(size: 10.5, weight: .medium)).foregroundStyle(Theme.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
    }

    private var status: String {
        switch event.kind {
        case .timerCompleted: localized("Timer completed")
        case .meetingThreshold: localized("Meeting soon")
        case .meetingOneMinute: localized("Meeting in one minute")
        case .meetingStarted: localized("Meeting started")
        case .downloadCompleted: localized("Download completed")
        case .downloadFailed: localized("Download failed")
        }
    }
}
