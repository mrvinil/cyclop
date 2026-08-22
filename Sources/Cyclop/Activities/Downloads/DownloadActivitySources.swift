import Combine
import Foundation
import OSLog

@MainActor
final class ExternalDownloadActivitySource: ActivitySource {
    let sourceID = "downloads.external"

    var statePublisher: AnyPublisher<ActivitySourceState, Never> {
        state.publisher
    }

    private static let fileActionFailureMessage = "Не удалось выполнить действие с файлом загрузки"
    private let watcher: DownloadsFolderWatcher
    private let fileActions: DownloadFileActions
    private let state: NonReentrantCurrentValueSubject<ActivitySourceState>
    private let logger = Logger(subsystem: "Cyclop", category: "Внешние загрузки")
    private var cancellables = Set<AnyCancellable>()
    private var hasFileActionFailure = false

    init(watcher: DownloadsFolderWatcher, fileActions: DownloadFileActions = .live()) {
        self.watcher = watcher
        self.fileActions = fileActions
        state = NonReentrantCurrentValueSubject(Self.makeState(
            completions: watcher.completions,
            health: watcher.health
        ))

        watcher.completionsStatePublisher
            .sink { [weak self] completions in
                MainActor.assumeIsolated { self?.receive(completions: completions) }
            }
            .store(in: &cancellables)
        watcher.$health
            .sink { [weak self] health in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.publish(
                        completions: self.watcher.completions,
                        health: self.hasFileActionFailure && health == .available
                            ? .unavailable(message: Self.fileActionFailureMessage)
                            : health
                    )
                }
            }
            .store(in: &cancellables)
    }

    func perform(_ action: ActivityAction, activityID: ActivityID) {
        guard activityID.source == sourceID,
              let completion = watcher.completions.first(where: { $0.id == activityID.local }) else {
            logger.notice("Источник внешних загрузок проигнорировал недоступное действие")
            return
        }
        switch action {
        case .open:
            handleFileActionResult(fileActions.open(completion.fileURL))
        case .reveal:
            handleFileActionResult(fileActions.reveal(completion.fileURL))
        case .dismiss:
            watcher.dismiss(completion.id)
        default:
            logger.notice("Источник внешних загрузок проигнорировал неподдерживаемое действие")
        }
    }

    private func receive(completions: [ExternalDownloadCompletion]) {
        guard watcher.health == .available else { return }
        publish(
            completions: completions,
            health: hasFileActionFailure ? .unavailable(message: Self.fileActionFailureMessage) : .available
        )
    }

    private func handleFileActionResult(_ result: Result<Void, DownloadFileActionError>) {
        switch result {
        case .success:
            hasFileActionFailure = false
            publish(completions: watcher.completions, health: watcher.health)
        case .failure:
            hasFileActionFailure = true
            logger.error("Не удалось выполнить действие с файлом загрузки")
            publish(
                completions: watcher.completions,
                health: .unavailable(message: Self.fileActionFailureMessage)
            )
        }
    }

    private func publish(completions: [ExternalDownloadCompletion], health: ActivitySourceHealth) {
        let updated = Self.makeState(completions: completions, health: health)
        if state.value != updated { state.send(updated) }
    }

    private static func makeState(
        completions: [ExternalDownloadCompletion],
        health: ActivitySourceHealth
    ) -> ActivitySourceState {
        ActivitySourceState(snapshots: completions.map(snapshot), health: health)
    }

    private static func snapshot(for completion: ExternalDownloadCompletion) -> ActivitySnapshot {
        ActivitySnapshot(
            id: ActivityID(source: "downloads.external", local: completion.id),
            sourceID: "downloads.external",
            kind: .download,
            phase: .completed,
            title: completion.fileURL.lastPathComponent,
            subtitle: "",
            progress: nil,
            deadline: nil,
            occurredAt: completion.occurredAt,
            availableActions: [.open, .reveal, .dismiss],
            containsSensitiveText: true
        )
    }
}
