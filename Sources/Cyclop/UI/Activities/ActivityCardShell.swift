import SwiftUI

struct ActivityCardShell<Content: View, Actions: View>: View {
    let symbol: String
    let tint: Color
    let title: String
    let subtitle: String
    let progress: Double?
    let showsIndeterminateProgress: Bool
    @ViewBuilder let content: () -> Content
    @ViewBuilder let actions: () -> Actions

    init(
        symbol: String,
        tint: Color,
        title: String,
        subtitle: String,
        progress: Double?,
        showsIndeterminateProgress: Bool = false,
        @ViewBuilder content: @escaping () -> Content,
        @ViewBuilder actions: @escaping () -> Actions
    ) {
        self.symbol = symbol
        self.tint = tint
        self.title = title
        self.subtitle = subtitle
        self.progress = progress
        self.showsIndeterminateProgress = showsIndeterminateProgress
        self.content = content
        self.actions = actions
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            VStack(alignment: .leading, spacing: 7) {
                HStack(alignment: .top, spacing: 9) {
                    Image(systemName: symbol)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(tint)
                        .frame(width: 20, height: 20)
                        .background(Circle().fill(tint.opacity(0.14)))
                        .accessibilityHidden(true)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(title)
                            .font(.system(size: 12.5, weight: .semibold))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                        if !subtitle.isEmpty {
                            Text(subtitle)
                                .font(.system(size: 10.5))
                                .foregroundStyle(Theme.secondary)
                                .lineLimit(1)
                        }
                    }
                    Spacer(minLength: 4)
                }

                content()

                if let progress {
                    ProgressView(value: min(max(progress, 0), 1))
                        .progressViewStyle(.linear)
                        .tint(tint)
                        .accessibilityLabel(Text(localized("Progress")))
                        .accessibilityValue(Text(Self.progressValue(progress)))
                } else if showsIndeterminateProgress {
                    ProgressView()
                        .controlSize(.small)
                        .tint(tint)
                        .accessibilityLabel(Text(localized("Progress")))
                        .accessibilityValue(Text(localized("In progress")))
                }
            }
            .accessibilityElement(children: .combine)

            actions()
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(Theme.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .strokeBorder(Theme.hairline, lineWidth: 1)
                .allowsHitTesting(false)
        )
    }

    private static func progressValue(_ progress: Double) -> String {
        let percent = Int((min(max(progress, 0), 1) * 100).rounded())
        return localized("%d%%", percent)
    }
}

enum ActivityCardPresentation {
    static func phaseLabelKey(_ phase: ActivityPhase, kind: ActivityKind) -> String {
        switch (kind, phase) {
        case (.media, .active): "Playing"
        case (.meeting, .active): "Meeting in progress"
        case (.timer, .active): "Timer is running"
        case (.download, .active): "Downloading"
        case (_, .ambient): "Queued"
        case (_, .attention): "Needs attention"
        case (_, .completed): "Completed"
        case (_, .failed): "Failed"
        case (_, .paused): "Paused"
        }
    }

    static func countdown(_ interval: TimeInterval) -> String {
        formatTime(max(0, interval))
    }
}

struct ActivityCardStatus: View {
    let model: ActivityCardModel
    var showsProgressText = false

    var body: some View {
        HStack(spacing: 7) {
            Text(localized(ActivityCardPresentation.phaseLabelKey(model.phase, kind: model.kind)))
                .foregroundStyle(Theme.secondary)

            if let countdown = model.countdown {
                Text(ActivityCardPresentation.countdown(countdown))
                    .font(.system(size: 10.5, weight: .medium).monospacedDigit())
                    .foregroundStyle(.white)
            }

            if showsProgressText, let progress = model.progress {
                Text(localized("%d%%", Int((min(max(progress, 0), 1) * 100).rounded())))
                    .font(.system(size: 10.5, weight: .medium).monospacedDigit())
                    .foregroundStyle(Theme.secondary)
            }
        }
        .font(.system(size: 10.5, weight: .medium))
    }
}
