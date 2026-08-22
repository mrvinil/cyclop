import Combine
import Foundation

/// Единственный владелец live-сервисов активностей. Окно может пересоздаваться
/// при смене экрана, но таймеры, наблюдение за загрузками и их источники остаются теми
/// же объектами.
@MainActor
final class ActivityComposition {
    let settings: ActivitySettings
    let privacy: PrivacyMode
    let media: MediaController
    let calendar: CalendarStore
    let timerStore: TimerStore
    let folderWatcher: DownloadsFolderWatcher
    let coordinator: ActivityCoordinator
    let center: ActivityCenterViewModel
    let presentation: NotchPresentationModel
    let sourceIDs: [String]

    private var hasStarted = false
    private var cancellables = Set<AnyCancellable>()
    private let retiredDownloadCleanup: RetiredOwnDownloadCleanup

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

        let folderWatcher = DownloadsFolderWatcher(
            settings: settings,
            clock: clock,
            scheduler: scheduler
        )
        self.folderWatcher = folderWatcher
        retiredDownloadCleanup = RetiredOwnDownloadCleanup()

        let sources: [ActivitySource] = [
            MediaActivitySource(controller: media, clock: clock, scheduler: scheduler),
            MeetingActivitySource(
                calendar: calendar,
                settings: settings,
                clock: clock,
                scheduler: scheduler
            ),
            TimerActivitySource(store: timerStore),
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
        do { try timerStore.start() } catch { }
        retiredDownloadCleanup.runIfNeeded { [weak self] in
            guard let self, self.hasStarted else { return }
            self.folderWatcher.start()
        }
        presentation.receive(display: coordinator.displayState)
    }

    func stop() {
        guard hasStarted else { return }
        hasStarted = false
        folderWatcher.stop()
        timerStore.stop()
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
