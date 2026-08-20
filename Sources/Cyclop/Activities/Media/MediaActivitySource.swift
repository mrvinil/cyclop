import Combine
import Foundation

@MainActor
protocol MediaActivityControlling: AnyObject {
    func togglePlayPause()
    func next()
    func previous()
}

extension MediaController: MediaActivityControlling {}

@MainActor
final class MediaActivitySource: ActivitySource {
    let sourceID = "media"

    var statePublisher: AnyPublisher<ActivitySourceState, Never> {
        state.publisher
    }

    private let controller: any MediaActivityControlling
    private let clock: ActivityClock
    private let scheduler: ActivityScheduling
    private let state: NonReentrantCurrentValueSubject<ActivitySourceState>
    private var cancellables = Set<AnyCancellable>()
    private var pauseGeneration = 0
    private var pauseWakeGeneration = 0
    private var pauseGraceState = PauseGraceState.idle
    private var pauseCancellation: ActivityCancellation?
    private var currentHealth: ActivitySourceHealth = .available

    convenience init(controller: MediaController) {
        self.init(
            controller: controller,
            clock: SystemActivityClock(),
            scheduler: SystemActivityScheduler()
        )
    }

    init(
        controller: MediaController,
        clock: ActivityClock,
        scheduler: ActivityScheduling
    ) {
        self.controller = controller
        self.clock = clock
        self.scheduler = scheduler
        state = NonReentrantCurrentValueSubject(.init(snapshots: [], health: .available))

        controller.mediaStatePublisher
            .sink { [weak self] mediaState in
                self?.publish(
                    Self.payload(mediaState),
                    health: Self.health(for: mediaState)
                )
            }
            .store(in: &cancellables)
    }

    convenience init(
        payloadPublisher: AnyPublisher<MediaActivityPayload?, Never>,
        controller: any MediaActivityControlling
    ) {
        self.init(
            payloadPublisher: payloadPublisher,
            controller: controller,
            clock: SystemActivityClock(),
            scheduler: SystemActivityScheduler()
        )
    }

    init(
        payloadPublisher: AnyPublisher<MediaActivityPayload?, Never>,
        controller: any MediaActivityControlling,
        clock: ActivityClock,
        scheduler: ActivityScheduling
    ) {
        self.controller = controller
        self.clock = clock
        self.scheduler = scheduler
        state = NonReentrantCurrentValueSubject(.init(snapshots: [], health: .available))

        payloadPublisher
            .sink { [weak self] payload in
                self?.publish(payload, health: .available)
            }
            .store(in: &cancellables)
    }

    deinit {
        let cancellation = pauseCancellation
        Task { @MainActor in
            cancellation?.cancel()
        }
    }

    func perform(_ action: ActivityAction, activityID: ActivityID) {
        guard activityID.source == sourceID,
              let snapshot = state.value.snapshots.first(where: { $0.id == activityID }),
              snapshot.availableActions.contains(action) else {
            return
        }

        switch action {
        case .play, .pause:
            controller.togglePlayPause()
        case .next:
            controller.next()
        case .previous:
            controller.previous()
        default:
            return
        }
    }

    private func publish(
        _ payload: MediaActivityPayload?,
        health: ActivitySourceHealth
    ) {
        currentHealth = health
        guard let payload else {
            resetPauseGrace()
            publishState(for: nil, health: health)
            return
        }

        if payload.isPlaying {
            resetPauseGrace()
            publishState(for: payload, health: health)
            return
        }

        receivePaused(payload, health: health)
    }

    private func receivePaused(
        _ payload: MediaActivityPayload,
        health: ActivitySourceHealth
    ) {
        switch pauseGraceState {
        case let .expired(trackKey) where trackKey == payload.trackKey:
            publishState(for: nil, health: health)
            return
        case let .visible(trackKey, pauseStartedAt) where trackKey == payload.trackKey:
            if clock.now >= pauseStartedAt.addingTimeInterval(Self.pauseGracePeriod) {
                expirePauseGrace(trackKey: trackKey)
            } else {
                publishState(for: payload, health: health)
            }
            return
        case .idle, .expired, .visible:
            break
        }

        resetPauseGrace()
        pauseGeneration &+= 1
        let generation = pauseGeneration
        let pausedAt = clock.now
        let deadline = pausedAt.addingTimeInterval(Self.pauseGracePeriod)
        pauseGraceState = .visible(trackKey: payload.trackKey, pauseStartedAt: pausedAt)
        schedulePauseGrace(
            at: deadline,
            pauseStartedAt: pausedAt,
            generation: generation,
            trackKey: payload.trackKey
        )
        guard isCurrentVisiblePause(
            generation: generation,
            trackKey: payload.trackKey,
            pauseStartedAt: pausedAt
        ),
        clock.now < deadline else {
            return
        }
        publishState(for: payload, health: health)
    }

    private func schedulePauseGrace(
        at deadline: Date,
        pauseStartedAt: Date,
        generation: Int,
        trackKey: String
    ) {
        pauseWakeGeneration &+= 1
        let wakeGeneration = pauseWakeGeneration
        let cancellation = scheduler.schedule(at: deadline) { [weak self] in
            self?.completePauseGrace(
                generation: generation,
                wakeGeneration: wakeGeneration,
                trackKey: trackKey
            )
        }

        guard isCurrentVisiblePause(
            generation: generation,
            trackKey: trackKey,
            pauseStartedAt: pauseStartedAt
        ),
        pauseWakeGeneration == wakeGeneration else {
            cancellation.cancel()
            return
        }

        pauseCancellation = cancellation
        if clock.now >= deadline {
            expirePauseGrace(trackKey: trackKey)
        }
    }

    private func completePauseGrace(
        generation: Int,
        wakeGeneration: Int,
        trackKey: String
    ) {
        guard generation == pauseGeneration,
              wakeGeneration == pauseWakeGeneration,
              case let .visible(currentTrackKey, pauseStartedAt) = pauseGraceState,
              currentTrackKey == trackKey else {
            return
        }

        let deadline = pauseStartedAt.addingTimeInterval(Self.pauseGracePeriod)
        guard clock.now >= deadline else {
            let cancellation = pauseCancellation
            pauseCancellation = nil
            pauseWakeGeneration &+= 1
            cancellation?.cancel()
            schedulePauseGrace(
                at: deadline,
                pauseStartedAt: pauseStartedAt,
                generation: generation,
                trackKey: trackKey
            )
            return
        }

        pauseCancellation = nil
        expirePauseGrace(trackKey: trackKey)
    }

    private func expirePauseGrace(trackKey: String) {
        guard case let .visible(currentTrackKey, _) = pauseGraceState,
              currentTrackKey == trackKey else {
            return
        }

        pauseGraceState = .expired(trackKey: trackKey)
        let cancellation = pauseCancellation
        pauseCancellation = nil
        cancellation?.cancel()
        publishState(for: nil, health: currentHealth)
    }

    private func isCurrentVisiblePause(
        generation: Int,
        trackKey: String,
        pauseStartedAt: Date
    ) -> Bool {
        guard generation == pauseGeneration,
              case let .visible(currentTrackKey, currentPauseStartedAt) = pauseGraceState else {
            return false
        }
        return currentTrackKey == trackKey && currentPauseStartedAt == pauseStartedAt
    }

    private func resetPauseGrace() {
        pauseGeneration &+= 1
        pauseGraceState = .idle
        let cancellation = pauseCancellation
        pauseCancellation = nil
        cancellation?.cancel()
    }

    private func publishState(
        for payload: MediaActivityPayload?,
        health: ActivitySourceHealth
    ) {
        let updated = ActivitySourceState(
            snapshots: payload.map { [Self.snapshot(for: $0)] } ?? [],
            health: health
        )
        if state.value != updated {
            state.send(updated)
        }
    }

    private static let pauseGracePeriod: TimeInterval = 15

    private enum PauseGraceState {
        case idle
        case visible(trackKey: String, pauseStartedAt: Date)
        case expired(trackKey: String)
    }

    private static func health(for state: MediaController.MediaState) -> ActivitySourceHealth {
        switch state.transport {
        case .systemNowPlaying:
            return .available
        case .scriptingFallback:
            return .unavailable(
                message: "Системная музыка недоступна; доступны только Apple Music и Spotify"
            )
        }
    }

    private static func payload(_ state: MediaController.MediaState) -> MediaActivityPayload? {
        guard let track = state.track else { return nil }
        return MediaActivityPayload(
            trackKey: track.key,
            title: track.title,
            artist: track.artist,
            album: track.album,
            sourceName: state.sourceName,
            isPlaying: state.isPlaying,
            duration: state.duration,
            position: state.position,
            canSkip: state.canSkip
        )
    }

    private static func snapshot(for payload: MediaActivityPayload) -> ActivitySnapshot {
        let progress: Double?
        if payload.duration.isFinite,
           payload.duration > 0,
           payload.position.isFinite {
            progress = min(max(payload.position / payload.duration, 0), 1)
        } else {
            progress = nil
        }

        var actions: Set<ActivityAction> = [payload.isPlaying ? .pause : .play]
        if payload.canSkip {
            actions.formUnion([.previous, .next])
        }

        return ActivitySnapshot(
            id: ActivityID(source: "media", local: payload.trackKey),
            sourceID: "media",
            kind: .media,
            phase: payload.isPlaying ? .active : .paused,
            title: payload.title,
            subtitle: payload.artist,
            progress: progress,
            deadline: nil,
            occurredAt: nil,
            availableActions: actions,
            containsSensitiveText: true
        )
    }
}
