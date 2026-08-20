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
    private let state: NonReentrantCurrentValueSubject<ActivitySourceState>
    private var cancellables = Set<AnyCancellable>()

    init(controller: MediaController) {
        self.controller = controller
        state = NonReentrantCurrentValueSubject(.init(snapshots: [], health: .available))

        controller.mediaStatePublisher
            .map(Self.payload)
            .sink { [weak self] payload in
                self?.publish(payload)
            }
            .store(in: &cancellables)
    }

    init(
        payloadPublisher: AnyPublisher<MediaActivityPayload?, Never>,
        controller: any MediaActivityControlling
    ) {
        self.controller = controller
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
        let updated = ActivitySourceState(
            snapshots: payload.map { [Self.snapshot(for: $0)] } ?? [],
            health: .available
        )
        if state.value != updated {
            state.send(updated)
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
