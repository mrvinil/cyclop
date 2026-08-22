import SwiftUI

struct DownloadActivityCard: View {
    let model: ActivityCardModel
    let perform: (ActivityAction) -> Void

    var body: some View {
        ActivityCardShell(
            symbol: "arrow.down.circle",
            tint: model.phase == .failed ? .red : .green,
            title: model.title,
            subtitle: model.subtitle,
            progress: model.progress,
            showsIndeterminateProgress: model.phase == .active && model.progress == nil
        ) {
            if let bytesReceived = model.bytesReceived {
                Text(ActivityCardPresentation.downloadBytes(
                    bytesReceived,
                    totalBytes: model.totalBytes
                ))
                .font(.system(size: 10.5, weight: .medium).monospacedDigit())
                .foregroundStyle(Theme.secondary)
            }
            ActivityCardStatus(model: model, showsProgressText: true)
        } actions: {
            ActivityActionRow(model: model, perform: perform)
        }
    }
}
