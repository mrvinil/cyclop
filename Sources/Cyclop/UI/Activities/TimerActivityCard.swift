import SwiftUI

struct TimerActivityCard: View {
    let model: ActivityCardModel
    let perform: (ActivityAction) -> Void

    var body: some View {
        ActivityCardShell(
            symbol: "timer",
            tint: .orange,
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
