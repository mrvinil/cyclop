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
            ActivityCardStatus(model: model)
        } actions: {
            ActivityActionRow(model: model, perform: perform)
        }
    }
}
