import Combine
import Foundation
import XCTest
@testable import Cyclop

@MainActor
final class MediaActivitySourceTests: XCTestCase {
    func testPlayingTrackMapsMetadataAndTransportActions() {
        let harness = MediaSourceHarness(now: Date(timeIntervalSince1970: 1_000))
        harness.send(.init(
            trackKey: "track-1",
            title: "Песня",
            artist: "Исполнитель",
            album: "Альбом",
            sourceName: "Яндекс Музыка",
            isPlaying: true,
            duration: 240,
            position: 60,
            canSkip: true
        ))

        let snapshot = harness.latest.snapshots.first

        XCTAssertEqual(snapshot?.kind, .media)
        XCTAssertEqual(snapshot?.phase, .active)
        XCTAssertEqual(snapshot?.title, "Песня")
        XCTAssertEqual(snapshot?.subtitle, "Исполнитель")
        XCTAssertEqual(snapshot?.availableActions, [.pause, .previous, .next])
    }

    func testPausedTrackMapsPlayAndHidesSkippingWhenPlayerCannotSkip() {
        let harness = MediaSourceHarness(now: Date(timeIntervalSince1970: 1_000))
        harness.send(payload(isPlaying: false, duration: 240, position: 60, canSkip: false))

        let snapshot = harness.latest.snapshots.first

        XCTAssertEqual(snapshot?.phase, .paused)
        XCTAssertEqual(snapshot?.availableActions, [.play])
        XCTAssertEqual(snapshot?.progress, 0.25)
        XCTAssertTrue(snapshot?.containsSensitiveText == true)
    }

    func testPausedTrackKeepsSkippingWhenPlayerCanSkip() {
        let harness = MediaSourceHarness(now: Date(timeIntervalSince1970: 1_000))
        harness.send(payload(isPlaying: false, canSkip: true))

        XCTAssertEqual(
            harness.latest.snapshots.first?.availableActions,
            [.play, .previous, .next]
        )
    }

    func testNilPayloadRemovesMediaActivityImmediately() {
        let harness = MediaSourceHarness(now: Date(timeIntervalSince1970: 1_000))
        harness.send(payload())
        harness.send(nil)

        XCTAssertEqual(harness.latest, .init(snapshots: [], health: .available))
    }

    func testUnknownDurationHasNoProgress() {
        let harness = MediaSourceHarness(now: Date(timeIntervalSince1970: 1_000))
        harness.send(payload(duration: 0, position: 60))

        XCTAssertNil(harness.latest.snapshots.first?.progress)
    }

    func testProgressIsClampedToTrackBounds() {
        let harness = MediaSourceHarness(now: Date(timeIntervalSince1970: 1_000))
        harness.send(payload(duration: 100, position: -10))
        XCTAssertEqual(harness.latest.snapshots.first?.progress, 0)

        harness.send(payload(duration: 100, position: 150))
        XCTAssertEqual(harness.latest.snapshots.first?.progress, 1)
    }

    func testTrackIdentityStaysStableAcrossMetadataUpdatesAndHasNoOccurrence() {
        let harness = MediaSourceHarness(now: Date(timeIntervalSince1970: 1_000))
        harness.send(payload(trackKey: "track-1", title: "Первая версия", position: 10))
        let first = harness.latest.snapshots.first

        harness.send(payload(trackKey: "track-1", title: "Новая версия", position: 20))
        let updated = harness.latest.snapshots.first

        XCTAssertEqual(first?.id, ActivityID(source: "media", local: "track-1"))
        XCTAssertEqual(updated?.id, first?.id)
        XCTAssertEqual(updated?.title, "Новая версия")
        XCTAssertNil(first?.occurredAt)
        XCTAssertNil(updated?.occurredAt)
    }

    func testSupportedActionsRouteExactlyOnceToController() {
        let harness = MediaSourceHarness(now: Date(timeIntervalSince1970: 1_000))
        harness.send(payload(isPlaying: true, canSkip: true))
        let activityID = ActivityID(source: "media", local: "track-1")

        harness.perform(.pause, activityID: activityID)
        XCTAssertEqual(harness.controller.calls, [.toggle])

        harness.controller.reset()
        harness.perform(.previous, activityID: activityID)
        XCTAssertEqual(harness.controller.calls, [.previous])

        harness.controller.reset()
        harness.perform(.next, activityID: activityID)
        XCTAssertEqual(harness.controller.calls, [.next])

        harness.controller.reset()
        harness.send(payload(isPlaying: false, canSkip: false))
        harness.perform(.play, activityID: activityID)
        XCTAssertEqual(harness.controller.calls, [.toggle])
    }

    func testForeignUnknownAndUnavailableActionsHaveNoSideEffects() {
        let harness = MediaSourceHarness(now: Date(timeIntervalSince1970: 1_000))
        harness.send(payload(isPlaying: true, canSkip: false))

        harness.perform(.pause, activityID: .init(source: "timers", local: "track-1"))
        harness.perform(.pause, activityID: .init(source: "media", local: "unknown"))
        harness.perform(.next, activityID: .init(source: "media", local: "track-1"))
        harness.perform(.dismiss, activityID: .init(source: "media", local: "track-1"))

        XCTAssertTrue(harness.controller.calls.isEmpty)
    }

    func testProductionSourceReceivesOnlyCommittedMediaControllerState() {
        let feed = NowPlayingFeed()
        let controller = MediaController(feed: feed)
        let source = MediaActivitySource(controller: controller)
        var states: [ActivitySourceState] = []
        let observation = source.statePublisher.sink { states.append($0) }
        var nowPlaying = NowPlayingFeed.Snapshot()
        nowPlaying.isPlaying = true
        nowPlaying.title = "Цельное состояние"
        nowPlaying.artist = "Исполнитель"
        nowPlaying.album = "Альбом"
        nowPlaying.duration = 200
        nowPlaying.elapsed = 50
        nowPlaying.source = "Яндекс Музыка"
        nowPlaying.commands = [
            NowPlayingFeed.Command.next.rawValue,
            NowPlayingFeed.Command.previous.rawValue,
        ]

        feed.onUpdate?(nowPlaying)

        XCTAssertEqual(states.count, 2)
        XCTAssertEqual(states.last?.snapshots, [ActivitySnapshot(
            id: .init(source: "media", local: "Цельное состояние|Исполнитель|Альбом"),
            sourceID: "media",
            kind: .media,
            phase: .active,
            title: "Цельное состояние",
            subtitle: "Исполнитель",
            progress: 0.25,
            deadline: nil,
            occurredAt: nil,
            availableActions: [.pause, .previous, .next],
            containsSensitiveText: true
        )])
        withExtendedLifetime(observation) {}
    }

    private func payload(
        trackKey: String = "track-1",
        title: String = "Песня",
        isPlaying: Bool = true,
        duration: TimeInterval = 240,
        position: TimeInterval = 60,
        canSkip: Bool = true
    ) -> MediaActivityPayload {
        .init(
            trackKey: trackKey,
            title: title,
            artist: "Исполнитель",
            album: "Альбом",
            sourceName: "Яндекс Музыка",
            isPlaying: isPlaying,
            duration: duration,
            position: position,
            canSkip: canSkip
        )
    }
}

@MainActor
private final class MediaSourceHarness {
    private let payloads = CurrentValueSubject<MediaActivityPayload?, Never>(nil)
    private let source: MediaActivitySource
    let controller = FakeMediaActivityController()
    private var observation: AnyCancellable?
    private(set) var latest = ActivitySourceState(snapshots: [], health: .available)

    init(now: Date) {
        source = MediaActivitySource(
            payloadPublisher: payloads.eraseToAnyPublisher(),
            controller: controller
        )
        observation = source.statePublisher.sink { [weak self] state in
            self?.latest = state
        }
    }

    func send(_ payload: MediaActivityPayload?) {
        payloads.send(payload)
    }

    func perform(_ action: ActivityAction, activityID: ActivityID) {
        source.perform(action, activityID: activityID)
    }
}

@MainActor
private final class FakeMediaActivityController: MediaActivityControlling {
    enum Call: Equatable {
        case toggle, next, previous
    }

    private(set) var calls: [Call] = []

    func togglePlayPause() { calls.append(.toggle) }
    func next() { calls.append(.next) }
    func previous() { calls.append(.previous) }

    func reset() { calls.removeAll() }
}
