import Combine
import Foundation

/// Единственный владелец live-сервисов активностей. Окно может пересоздаваться
/// при смене экрана, но таймеры, фоновые загрузки и их источники остаются теми
/// же объектами.
@MainActor
final class ActivityComposition {
    let settings: ActivitySettings
    let privacy: PrivacyMode
    let media: MediaController
    let calendar: CalendarStore
    let timerStore: TimerStore
    let downloadManager: DownloadManager
    let folderWatcher: DownloadsFolderWatcher
    let coordinator: ActivityCoordinator
    let center: ActivityCenterViewModel
    let presentation: NotchPresentationModel
    let sourceIDs: [String]

    private var hasStarted = false
    private var cancellables = Set<AnyCancellable>()

    convenience init() {
        self.init(
            settings: ActivitySettings(),
            privacy: PrivacyMode(),
            media: MediaController(),
            calendar: CalendarStore(),
            clock: SystemActivityClock(),
            scheduler: SystemActivityScheduler()
        )
    }

    init(
        settings: ActivitySettings,
        privacy: PrivacyMode,
        media: MediaController,
        calendar: CalendarStore,
        clock: ActivityClock,
        scheduler: ActivityScheduling
    ) {
        self.settings = settings
        self.privacy = privacy
        self.media = media
        self.calendar = calendar

        let timerSound = SettingsTimerSoundPlayer(settings: settings)
        let timerStore = TimerStore(
            clock: clock,
            scheduler: scheduler,
            persistence: JSONTimerPersistence.live(),
            soundPlayer: timerSound
        )
        self.timerStore = timerStore

        let transport = URLSessionDownloadTransport()
        let downloadManager = DownloadManager(
            clock: clock,
            scheduler: scheduler,
            persistence: JSONDownloadPersistence.live(),
            transport: transport,
            settings: settings,
            maxConcurrent: 3
        )
        self.downloadManager = downloadManager

        let folderWatcher = DownloadsFolderWatcher(
            settings: settings,
            clock: clock,
            scheduler: scheduler,
            ownFileMovePublisher: downloadManager.ownFileMovePublisher
        )
        self.folderWatcher = folderWatcher

        let sources: [ActivitySource] = [
            MediaActivitySource(controller: media, clock: clock, scheduler: scheduler),
            MeetingActivitySource(
                calendar: calendar,
                settings: settings,
                clock: clock,
                scheduler: scheduler
            ),
            TimerActivitySource(store: timerStore),
            OwnDownloadActivitySource(manager: downloadManager),
            ExternalDownloadActivitySource(watcher: folderWatcher),
        ]
        sourceIDs = sources.map(\.sourceID)

        let coordinator = ActivityCoordinator(
            sources: sources,
            settings: settings,
            attentionLedger: ActivityAttentionLedger(defaults: .standard, clock: clock),
            clock: clock
        )
        self.coordinator = coordinator

        let center = ActivityCenterViewModel(
            coordinator: coordinator,
            timers: timerStore,
            downloads: downloadManager,
            privacy: privacy
        )
        self.center = center
        presentation = NotchPresentationModel(
            clock: clock,
            scheduler: scheduler,
            onActivityOpen: { [weak center] id in center?.reveal(id) },
            onAttentionExpired: { [weak coordinator] event in coordinator?.settleAttention(event) }
        )
        coordinator.$displayState
            .sink { [weak presentation] display in
                presentation?.receive(display: display)
            }
            .store(in: &cancellables)
    }

    func start() {
        guard !hasStarted else { return }
        hasStarted = true
        // Restore manager before watcher: a finished own download must be
        // suppressed before a folder event can be interpreted as external.
        do { try timerStore.start() } catch { }
        do { try downloadManager.start() } catch { }
        folderWatcher.start()
        presentation.receive(display: coordinator.displayState)
    }

    func stop() {
        guard hasStarted else { return }
        hasStarted = false
        folderWatcher.stop()
        downloadManager.stop()
        timerStore.stop()
    }

    @discardableResult
    func acceptRemoteURLs(_ urls: [URL]) -> Bool {
        guard !urls.isEmpty else { return false }
        center.presentDownloadComposer()
        for url in urls {
            do {
                try center.enqueueDownload(url: url)
            } catch {
                return false
            }
        }
        return true
    }
}

@MainActor
private final class SettingsTimerSoundPlayer: @preconcurrency TimerSoundPlaying {
    private weak var settings: ActivitySettings?
    private let player: any TimerSoundPlaying

    init(settings: ActivitySettings, player: any TimerSoundPlaying = SystemTimerSoundPlayer()) {
        self.settings = settings
        self.player = player
    }

    func playCompletion() {
        guard settings?.timerSoundEnabled != false else { return }
        player.playCompletion()
    }
}
