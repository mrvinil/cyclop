import SwiftUI

struct MediaActivityCard: View {
    let model: ActivityCardModel
    let perform: (ActivityAction) -> Void

    var body: some View {
        ActivityCardShell(
            symbol: "music.note",
            tint: .pink,
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
