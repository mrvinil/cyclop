import SwiftUI

struct ActivityCenterPane: View {
    @ObservedObject var model: ActivityCenterViewModel
    @Binding var wantsKeyboard: Bool

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(model.diagnostics) { diagnostic in
                        diagnosticCard(diagnostic)
                    }

                    ForEach(model.cards) { card in
                        activityCard(card)
                            .id(card.id)
                    }

                    if model.cards.isEmpty {
                        emptyState
                    }

                    if model.canClearDownloadHistory {
                        clearDownloadHistoryControl
                    }

                    composerControls

                    if model.timerComposerPresented {
                        TimerComposer(model: model, wantsKeyboard: $wantsKeyboard)
                    }

                }
                .padding(.top, 2)
                .padding(.trailing, 4)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .onAppear {
                model.setVisible(true)
                scroll(to: model.scrollTarget, using: proxy)
            }
            .onDisappear { model.setVisible(false) }
            .onChange(of: model.scrollTarget) { _, target in
                scroll(to: target, using: proxy)
            }
        }
    }

    private func scroll(to target: ActivityID?, using proxy: ScrollViewProxy) {
        guard let target else { return }
        DispatchQueue.main.async {
            withAnimation(Theme.contentAnimation) {
                proxy.scrollTo(target, anchor: .center)
            }
            model.clearScrollTarget()
        }
    }

    @ViewBuilder
    private func activityCard(_ card: ActivityCardModel) -> some View {
        let perform: (ActivityAction) -> Void = { action in
            model.perform(action, on: card.id)
        }

        switch card.kind {
        case .media:
            MediaActivityCard(model: card, perform: perform)
        case .meeting:
            MeetingActivityCard(model: card, perform: perform)
        case .timer:
            TimerActivityCard(model: card, perform: perform)
        case .download:
            DownloadActivityCard(model: card, perform: perform)
        }
    }

    private func diagnosticCard(_ diagnostic: ActivityDiagnosticModel) -> some View {
        ActivityCardShell(
            symbol: "exclamationmark.triangle.fill",
            tint: .orange,
            title: localized("Activity source unavailable"),
            subtitle: diagnostic.message,
            progress: nil
        ) {
            EmptyView()
        } actions: {
            EmptyView()
        }
        .id("diagnostic-\(diagnostic.id)")
    }

    private var emptyState: some View {
        VStack(spacing: 7) {
            Image(systemName: "sparkles")
                .font(.system(size: 20, weight: .light))
                .foregroundStyle(Theme.tertiary)
                .accessibilityHidden(true)
            Text(localized("No activities yet"))
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .accessibilityElement(children: .combine)
    }

    private var composerControls: some View {
        HStack(spacing: 7) {
            Button {
                model.timerComposerPresented = true
                wantsKeyboard = true
            } label: {
                Label(localized("New Timer"), systemImage: "timer")
            }
            .buttonStyle(ActivityControlButtonStyle(prominent: true))
            .accessibilityHint(Text(localized("Opens timer creation")))

        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var clearDownloadHistoryControl: some View {
        Button {
            model.clearDownloadHistory()
        } label: {
            Label(localized("Clear Download History"), systemImage: "trash")
        }
        .buttonStyle(ActivityControlButtonStyle())
        .accessibilityHint(Text(localized("Removes completed and failed downloads")))
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
