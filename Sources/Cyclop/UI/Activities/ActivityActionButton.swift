import SwiftUI

enum ActivityActionPresentation {
    static func labelKey(_ action: ActivityAction) -> String {
        switch action {
        case .play: "Play"
        case .pause: "Pause"
        case .previous: "Previous"
        case .next: "Next"
        case .join: "Join"
        case .resume: "Resume"
        case .cancel: "Cancel"
        case .dismiss: "Dismiss"
        case .retry: "Retry"
        case .restart: "Restart"
        case .open: "Open"
        case .reveal: "Show in Finder"
        }
    }

    static func symbol(_ action: ActivityAction) -> String {
        switch action {
        case .play: "play.fill"
        case .pause: "pause.fill"
        case .previous: "backward.fill"
        case .next: "forward.fill"
        case .join: "video.fill"
        case .resume: "play.fill"
        case .cancel: "xmark"
        case .dismiss: "xmark.circle"
        case .retry: "arrow.clockwise"
        case .restart: "arrow.counterclockwise"
        case .open: "doc"
        case .reveal: "folder"
        }
    }

    static func accessibilityHintKey(_ action: ActivityAction) -> String {
        switch action {
        case .play: "Starts playback"
        case .pause: "Pauses the activity"
        case .previous: "Switches to the previous track"
        case .next: "Switches to the next track"
        case .join: "Opens the meeting link"
        case .resume: "Resumes the activity"
        case .cancel: "Cancels the activity"
        case .dismiss: "Removes the completed activity"
        case .retry: "Retries the failed activity"
        case .restart: "Starts the activity again from the beginning"
        case .open: "Opens the downloaded file"
        case .reveal: "Shows the downloaded file in Finder"
        }
    }

    static func ordered(_ actions: [ActivityAction], for kind: ActivityKind) -> [ActivityAction] {
        let preferred: [ActivityAction]
        switch kind {
        case .media:
            preferred = [.previous, .play, .pause, .next]
        case .meeting:
            preferred = [.join]
        case .timer:
            preferred = [.pause, .resume, .cancel, .dismiss, .restart]
        case .download:
            preferred = [.pause, .resume, .restart, .cancel, .retry, .open, .reveal, .dismiss]
        }

        let available = Set(actions)
        let known = preferred.filter(available.contains)
        let remaining = available.subtracting(preferred).sorted { $0.rawValue < $1.rawValue }
        return known + remaining
    }
}

struct ActivityControlButtonStyle: ButtonStyle {
    var prominent = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 10.5, weight: .medium))
            .foregroundStyle(.white)
            .padding(.horizontal, 9)
            .frame(height: 26)
            .background(
                Capsule().fill(prominent ? Theme.surfaceHover : Theme.surface)
            )
            .contentShape(Capsule())
            .opacity(configuration.isPressed ? 0.55 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

struct ActivityActionButton: View {
    let action: ActivityAction
    let perform: (ActivityAction) -> Void

    var body: some View {
        let label = localized(ActivityActionPresentation.labelKey(action))
        Button {
            perform(action)
        } label: {
            Label(label, systemImage: ActivityActionPresentation.symbol(action))
                .lineLimit(1)
        }
        .buttonStyle(ActivityControlButtonStyle())
        .help(Text(label))
        .accessibilityLabel(Text(label))
        .accessibilityHint(Text(localized(ActivityActionPresentation.accessibilityHintKey(action))))
    }
}

struct ActivityActionRow: View {
    let model: ActivityCardModel
    let perform: (ActivityAction) -> Void

    var body: some View {
        HStack(spacing: 6) {
            ForEach(ActivityActionPresentation.ordered(model.actions, for: model.kind), id: \.self) { action in
                ActivityActionButton(action: action, perform: perform)
            }
        }
    }
}
