import AppKit
import Combine
import Foundation
import OSLog

@MainActor
final class OwnDownloadActivitySource: ActivitySource {
    let sourceID = "downloads.own"

    var statePublisher: AnyPublisher<ActivitySourceState, Never> {
        state.eraseToAnyPublisher()
    }

    private static let missingFileMessage = "Файл загрузки недоступен"

    private let manager: DownloadManager
    private let state: CurrentValueSubject<ActivitySourceState, Never>
    private let logger = Logger(subsystem: "Cyclop", category: "Собственные загрузки")
    private var cancellables = Set<AnyCancellable>()

    init(manager: DownloadManager) {
        self.manager = manager
        state = CurrentValueSubject(Self.makeState(
            downloads: manager.downloads,
            health: manager.health
        ))

        manager.$downloads
            .sink { [weak self] downloads in
                MainActor.assumeIsolated {
                    self?.receive(downloads: downloads)
                }
            }
            .store(in: &cancellables)

        manager.$health
            .sink { [weak self] health in
                MainActor.assumeIsolated {
                    self?.publish(downloads: manager.downloads, health: health)
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
                manager.open(downloadID)
            } else {
                manager.reveal(downloadID)
            }
        default:
            logger.notice("Источник собственных загрузок проигнорировал неподдерживаемое действие")
        }
    }

    private func receive(downloads: [CyclopDownload]) {
        guard manager.health == .available else { return }
        publish(downloads: downloads, health: .available)
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
            actions = [.resume, .cancel]
            occurredAt = download.createdAt
        case .failed:
            phase = .failed
            actions = [.retry, .cancel]
            occurredAt = download.completedAt ?? download.createdAt
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
        state.eraseToAnyPublisher()
    }

    private let watcher: DownloadsFolderWatcher
    private let openHandler: (URL) -> Void
    private let revealHandler: (URL) -> Void
    private let state: CurrentValueSubject<ActivitySourceState, Never>
    private let logger = Logger(subsystem: "Cyclop", category: "Внешние загрузки")
    private var cancellables = Set<AnyCancellable>()

    init(
        watcher: DownloadsFolderWatcher,
        openHandler: @escaping (URL) -> Void = { NSWorkspace.shared.open($0) },
        revealHandler: @escaping (URL) -> Void = {
            NSWorkspace.shared.activateFileViewerSelecting([$0])
        }
    ) {
        self.watcher = watcher
        self.openHandler = openHandler
        self.revealHandler = revealHandler
        state = CurrentValueSubject(Self.makeState(
            completions: watcher.completions,
            health: watcher.health
        ))

        watcher.$completions
            .sink { [weak self] completions in
                MainActor.assumeIsolated {
                    self?.receive(completions: completions)
                }
            }
            .store(in: &cancellables)

        watcher.$health
            .sink { [weak self] health in
                MainActor.assumeIsolated {
                    self?.publish(completions: watcher.completions, health: health)
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
            openHandler(completion.fileURL)
        case .reveal:
            revealHandler(completion.fileURL)
        case .dismiss:
            watcher.dismiss(completion.id)
        default:
            logger.notice("Источник внешних загрузок проигнорировал неподдерживаемое действие")
        }
    }

    private func receive(completions: [ExternalDownloadCompletion]) {
        guard watcher.health == .available else { return }
        publish(completions: completions, health: .available)
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
