import Combine
import Foundation
import OSLog

@MainActor
final class OwnDownloadActivitySource: ActivitySource {
    let sourceID = "downloads.own"

    var statePublisher: AnyPublisher<ActivitySourceState, Never> {
        state.publisher
    }

    private static let missingFileMessage = "Файл загрузки недоступен"
    private static let fileActionFailureMessage =
        "Не удалось выполнить действие с файлом загрузки"

    private let manager: DownloadManager
    private let state: NonReentrantCurrentValueSubject<ActivitySourceState>
    private let logger = Logger(subsystem: "Cyclop", category: "Собственные загрузки")
    private var cancellables = Set<AnyCancellable>()
    private var hasFileActionFailure = false

    init(manager: DownloadManager) {
        self.manager = manager
        state = NonReentrantCurrentValueSubject(Self.makeState(
            downloads: manager.downloads,
            health: manager.health
        ))

        manager.downloadsStatePublisher
            .sink { [weak self] downloads in
                MainActor.assumeIsolated {
                    self?.receive(downloads: downloads)
                }
            }
            .store(in: &cancellables)

        manager.$health
            .sink { [weak self] health in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.publish(
                        downloads: manager.downloads,
                        health: self.hasFileActionFailure && health == .available
                            ? .unavailable(message: Self.fileActionFailureMessage)
                            : health
                    )
                }
            }
            .store(in: &cancellables)
    }

    func perform(_ action: ActivityAction, activityID: ActivityID) {
        guard activityID.source == sourceID else {
            logger.notice("Источник собственных загрузок проигнорировал действие для чужой активности")
            return
        }
        guard let downloadID = UUID(uuidString: activityID.local) else {
            logger.notice("Источник собственных загрузок проигнорировал действие с некорректным идентификатором")
            return
        }

        switch action {
        case .pause:
            manager.pause(downloadID)
        case .resume:
            manager.resume(downloadID)
        case .restart:
            manager.restart(downloadID)
        case .cancel:
            manager.cancel(downloadID)
        case .retry:
            manager.retry(downloadID)
        case .dismiss:
            manager.dismiss(downloadID)
        case .open, .reveal:
            guard let record = manager.downloads.first(where: { $0.id == downloadID }),
                  record.phase == .completed else {
                logger.notice("Источник собственных загрузок проигнорировал действие для недоступной загрузки")
                return
            }
            guard record.destinationURL != nil else {
                logger.error("Не удалось открыть файл загрузки: файл недоступен")
                publish(downloads: manager.downloads, health: .unavailable(
                    message: Self.missingFileMessage
                ))
                return
            }
            if action == .open {
                handleFileActionResult(manager.open(downloadID))
            } else {
                handleFileActionResult(manager.reveal(downloadID))
            }
        default:
            logger.notice("Источник собственных загрузок проигнорировал неподдерживаемое действие")
        }
    }

    private func receive(downloads: [CyclopDownload]) {
        guard manager.health == .available else { return }
        publish(
            downloads: downloads,
            health: hasFileActionFailure
                ? .unavailable(message: Self.fileActionFailureMessage)
                : .available
        )
    }

    private func handleFileActionResult(
        _ result: Result<Void, DownloadFileActionError>
    ) {
        switch result {
        case .success:
            hasFileActionFailure = false
            publish(downloads: manager.downloads, health: manager.health)
        case .failure:
            hasFileActionFailure = true
            logger.error("Не удалось выполнить действие с файлом загрузки")
            publish(downloads: manager.downloads, health: .unavailable(
                message: Self.fileActionFailureMessage
            ))
        }
    }

    private func publish(
        downloads: [CyclopDownload],
        health: ActivitySourceHealth
    ) {
        let updated = Self.makeState(downloads: downloads, health: health)
        if state.value != updated {
            state.send(updated)
        }
    }

    private static func makeState(
        downloads: [CyclopDownload],
        health: ActivitySourceHealth
    ) -> ActivitySourceState {
        ActivitySourceState(
            snapshots: downloads.compactMap(snapshot),
            health: health
        )
    }

    private static func snapshot(for download: CyclopDownload) -> ActivitySnapshot? {
        let phase: ActivityPhase
        let actions: Set<ActivityAction>
        let occurredAt: Date

        switch download.phase {
        case .queued:
            phase = .ambient
            actions = [.cancel]
            occurredAt = download.createdAt
        case .downloading:
            phase = .active
            actions = [.pause, .cancel]
            occurredAt = download.createdAt
        case .paused:
            phase = .paused
            actions = download.resumeData?.isEmpty == false
                ? [.resume, .cancel]
                : [.restart, .cancel]
            occurredAt = download.createdAt
        case .failed:
            phase = .failed
            actions = [.retry, .cancel]
            occurredAt = download.failedAt ?? download.createdAt
        case .completed:
            phase = .completed
            actions = [.open, .reveal, .dismiss]
            occurredAt = download.completedAt ?? download.createdAt
        case .cancelled:
            return nil
        }

        return ActivitySnapshot(
            id: ActivityID(source: "downloads.own", local: download.id.uuidString),
            sourceID: "downloads.own",
            kind: .download,
            phase: phase,
            title: download.displayName,
            subtitle: "",
            progress: download.progress,
            deadline: nil,
            occurredAt: occurredAt,
            availableActions: actions,
            containsSensitiveText: true
        )
    }
}

@MainActor
final class ExternalDownloadActivitySource: ActivitySource {
    let sourceID = "downloads.external"

    var statePublisher: AnyPublisher<ActivitySourceState, Never> {
        state.publisher
    }

    private let watcher: DownloadsFolderWatcher
    private static let fileActionFailureMessage =
        "Не удалось выполнить действие с файлом загрузки"
    private let fileActions: DownloadFileActions
    private let state: NonReentrantCurrentValueSubject<ActivitySourceState>
    private let logger = Logger(subsystem: "Cyclop", category: "Внешние загрузки")
    private var cancellables = Set<AnyCancellable>()
    private var hasFileActionFailure = false

    init(
        watcher: DownloadsFolderWatcher,
        fileActions: DownloadFileActions = .live()
    ) {
        self.watcher = watcher
        self.fileActions = fileActions
        state = NonReentrantCurrentValueSubject(Self.makeState(
            completions: watcher.completions,
            health: watcher.health
        ))

        watcher.completionsStatePublisher
            .sink { [weak self] completions in
                MainActor.assumeIsolated {
                    self?.receive(completions: completions)
                }
            }
            .store(in: &cancellables)

        watcher.$health
            .sink { [weak self] health in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.publish(
                        completions: watcher.completions,
                        health: self.hasFileActionFailure && health == .available
                            ? .unavailable(message: Self.fileActionFailureMessage)
                            : health
                    )
                }
            }
            .store(in: &cancellables)
    }

    func perform(_ action: ActivityAction, activityID: ActivityID) {
        guard activityID.source == sourceID else {
            logger.notice("Источник внешних загрузок проигнорировал действие для чужой активности")
            return
        }
        guard let completion = watcher.completions.first(where: {
            $0.id == activityID.local
        }) else {
            logger.notice("Источник внешних загрузок проигнорировал действие для неизвестной активности")
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
            health: hasFileActionFailure
                ? .unavailable(message: Self.fileActionFailureMessage)
                : .available
        )
    }

    private func handleFileActionResult(
        _ result: Result<Void, DownloadFileActionError>
    ) {
        switch result {
        case .success:
            hasFileActionFailure = false
            publish(completions: watcher.completions, health: watcher.health)
        case .failure:
            hasFileActionFailure = true
            logger.error("Не удалось выполнить действие с файлом загрузки")
            publish(completions: watcher.completions, health: .unavailable(
                message: Self.fileActionFailureMessage
            ))
        }
    }

    private func publish(
        completions: [ExternalDownloadCompletion],
        health: ActivitySourceHealth
    ) {
        let updated = Self.makeState(completions: completions, health: health)
        if state.value != updated {
            state.send(updated)
        }
    }

    private static func makeState(
        completions: [ExternalDownloadCompletion],
        health: ActivitySourceHealth
    ) -> ActivitySourceState {
        ActivitySourceState(
            snapshots: completions.map(snapshot),
            health: health
        )
    }

    private static func snapshot(
        for completion: ExternalDownloadCompletion
    ) -> ActivitySnapshot {
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
