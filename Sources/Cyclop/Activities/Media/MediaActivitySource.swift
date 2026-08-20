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
    private var pauseStartedAt: Date?
    private var pausedTrackKey: String?
    private var pauseCancellation: ActivityCancellation?

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
            .map(Self.payload)
            .sink { [weak self] payload in
                self?.publish(payload)
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
                self?.publish(payload)
            }
            .store(in: &cancellables)
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

    private func publish(_ payload: MediaActivityPayload?) {
        guard let payload else {
            resetPauseGrace()
            publishState(for: nil)
            return
        }

        if payload.isPlaying {
            resetPauseGrace()
            publishState(for: payload)
            return
        }

        receivePaused(payload)
    }

    private func receivePaused(_ payload: MediaActivityPayload) {
        if pausedTrackKey == payload.trackKey,
           let pauseStartedAt {
            if clock.now >= pauseStartedAt.addingTimeInterval(Self.pauseGracePeriod) {
                pauseCancellation?.cancel()
                pauseCancellation = nil
                publishState(for: nil)
            } else {
                publishState(for: payload)
            }
            return
        }

        resetPauseGrace()
        pauseGeneration += 1
        let generation = pauseGeneration
        let pausedAt = clock.now
        let deadline = pausedAt.addingTimeInterval(Self.pauseGracePeriod)
        pauseStartedAt = pausedAt
        pausedTrackKey = payload.trackKey
        schedulePauseGrace(
            at: deadline,
            generation: generation,
            trackKey: payload.trackKey
        )
        publishState(for: payload)
    }

    private func schedulePauseGrace(
        at deadline: Date,
        generation: Int,
        trackKey: String
    ) {
        pauseCancellation = scheduler.schedule(at: deadline) { [weak self] in
            self?.completePauseGrace(generation: generation, trackKey: trackKey)
        }
    }

    private func completePauseGrace(generation: Int, trackKey: String) {
        guard generation == pauseGeneration,
              pausedTrackKey == trackKey,
              let pauseStartedAt else {
            return
        }

        let deadline = pauseStartedAt.addingTimeInterval(Self.pauseGracePeriod)
        guard clock.now >= deadline else {
            schedulePauseGrace(at: deadline, generation: generation, trackKey: trackKey)
            return
        }

        pauseCancellation = nil
        publishState(for: nil)
    }

    private func resetPauseGrace() {
        pauseGeneration += 1
        pauseCancellation?.cancel()
        pauseCancellation = nil
        pauseStartedAt = nil
        pausedTrackKey = nil
    }

    private func publishState(for payload: MediaActivityPayload?) {
        let updated = ActivitySourceState(
            snapshots: payload.map { [Self.snapshot(for: $0)] } ?? [],
            health: .available
        )
        if state.value != updated {
            state.send(updated)
        }
    }

    private static let pauseGracePeriod: TimeInterval = 15

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
