import SwiftUI

struct MeetingActivityCard: View {
    let model: ActivityCardModel
    let perform: (ActivityAction) -> Void

    var body: some View {
        ActivityCardShell(
            symbol: "calendar",
            tint: .blue,
            title: model.title,
            subtitle: model.subtitle,
            progress: model.progress
        ) {
            if let start = model.start {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    HStack(spacing: 7) {
                        Text(start, style: .time)
                        Text(ActivityCardPresentation.countdown(
                            ActivityCardPresentation.meetingRemaining(
                                until: start,
                                now: context.date
                            )
                        ))
                        .monospacedDigit()
                    }
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(Theme.secondary)
                }
            }
            ActivityCardStatus(model: model)
        } actions: {
            ActivityActionRow(model: model, perform: perform)
        }
    }
}
