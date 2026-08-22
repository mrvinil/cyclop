import SwiftUI

struct ActivityCenterPane: View {
    @ObservedObject var model: ActivityCenterViewModel
    @Binding var wantsKeyboard: Bool
    @State private var downloadComposerPresented = false

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

                    composerControls

                    if model.timerComposerPresented {
                        TimerComposer(model: model, wantsKeyboard: $wantsKeyboard)
                    }

                    if downloadComposerPresented {
                        DownloadComposer(
                            model: model,
                            wantsKeyboard: $wantsKeyboard,
                            isPresented: $downloadComposerPresented
                        )
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

            Button {
                wantsKeyboard = true
                downloadComposerPresented = true
            } label: {
                Label(localized("Download from Link"), systemImage: "link.badge.plus")
            }
            .buttonStyle(ActivityControlButtonStyle())
            .accessibilityHint(Text(localized("Focuses the download link field")))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
