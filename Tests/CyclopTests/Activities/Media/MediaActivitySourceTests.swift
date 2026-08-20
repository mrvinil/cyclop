import Combine
import Foundation
import XCTest
@testable import Cyclop

@MainActor
final class MediaActivitySourceTests: XCTestCase {
    func testPlayingTrackMapsMetadataAndTransportActions() {
        let harness = MediaSourceHarness()
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

    func testProviderNamesDoNotChangeActivityContract() {
        let expected = ActivitySourceState(
            snapshots: [ActivitySnapshot(
                id: .init(source: "media", local: "track-1"),
                sourceID: "media",
                kind: .media,
                phase: .active,
                title: "Песня",
                subtitle: "Исполнитель",
                progress: 0.25,
                deadline: nil,
                occurredAt: nil,
                availableActions: [.pause, .previous, .next],
                containsSensitiveText: true
            )],
            health: .available
        )

        for sourceName in ["Music", "Spotify", "Safari", "Google Chrome", "Яндекс Музыка"] {
            let harness = MediaSourceHarness()
            harness.send(.init(
                trackKey: "track-1",
                title: "Песня",
                artist: "Исполнитель",
                album: "Альбом",
                sourceName: sourceName,
                isPlaying: true,
                duration: 240,
                position: 60,
                canSkip: true
            ))

            XCTAssertEqual(harness.latest, expected, "Источник: \(sourceName)")
        }
    }

    func testPausedTrackMapsPlayAndHidesSkippingWhenPlayerCannotSkip() {
        let harness = MediaSourceHarness()
        harness.send(payload(isPlaying: false, duration: 240, position: 60, canSkip: false))

        let snapshot = harness.latest.snapshots.first

        XCTAssertEqual(snapshot?.phase, .paused)
        XCTAssertEqual(snapshot?.availableActions, [.play])
        XCTAssertEqual(snapshot?.progress, 0.25)
        XCTAssertTrue(snapshot?.containsSensitiveText == true)
    }

    func testPausedTrackKeepsSkippingWhenPlayerCanSkip() {
        let harness = MediaSourceHarness()
        harness.send(payload(isPlaying: false, canSkip: true))

        XCTAssertEqual(
            harness.latest.snapshots.first?.availableActions,
            [.play, .previous, .next]
        )
    }

    func testNilPayloadRemovesMediaActivityImmediately() {
        let harness = MediaSourceHarness()
        harness.send(payload())
        harness.send(nil)

        XCTAssertEqual(harness.latest, .init(snapshots: [], health: .available))
    }

    func testUnknownDurationHasNoProgress() {
        let harness = MediaSourceHarness()
        harness.send(payload(duration: 0, position: 60))

        XCTAssertNil(harness.latest.snapshots.first?.progress)
    }

    func testProgressIsClampedToTrackBounds() {
        let harness = MediaSourceHarness()
        harness.send(payload(duration: 100, position: -10))
        XCTAssertEqual(harness.latest.snapshots.first?.progress, 0)

        harness.send(payload(duration: 100, position: 150))
        XCTAssertEqual(harness.latest.snapshots.first?.progress, 1)
    }

    func testTrackIdentityStaysStableAcrossMetadataUpdatesAndHasNoOccurrence() {
        let harness = MediaSourceHarness()
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
        let harness = MediaSourceHarness()
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
        let harness = MediaSourceHarness()
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

    func testHelperFailureClearsSystemTrackBeforeFallbackResolution() {
        let feed = NowPlayingFeed()
        let fallback = ManualFallbackStateFetcher()
        let controller = MediaController(
            feed: feed,
            fallbackState: fallback.fetch,
            now: { Date() }
        )
        var states: [MediaController.MediaState] = []
        let observation = controller.mediaStatePublisher.sink { states.append($0) }
        var browser = NowPlayingFeed.Snapshot()
        browser.isPlaying = true
        browser.title = "Браузер"
        browser.artist = "Исполнитель"
        browser.album = "Альбом"
        browser.duration = 300
        browser.elapsed = 120
        browser.source = "Яндекс Музыка"
        browser.commands = []

        feed.onUpdate?(browser)
        feed.onUnavailable?()

        XCTAssertEqual(states.map { $0.track?.title }, [nil, "Браузер", nil])
        XCTAssertEqual(states.last?.canSkip, true)
        XCTAssertEqual(fallback.requestCount, 1)
        withExtendedLifetime(observation) {}
    }

    func testHelperFailureAtomicallyClearsSystemActivityWithDegradedDiagnostic() {
        let feed = NowPlayingFeed()
        let fallback = ManualFallbackStateFetcher()
        let controller = MediaController(
            feed: feed,
            fallbackState: fallback.fetch,
            now: { Date() }
        )
        let source = MediaActivitySource(controller: controller)
        var states: [ActivitySourceState] = []
        let observation = source.statePublisher.sink { states.append($0) }

        var browser = NowPlayingFeed.Snapshot()
        browser.isPlaying = true
        browser.title = "Браузер"
        browser.artist = "Исполнитель"
        browser.album = "Альбом"
        browser.source = "Safari"
        feed.onUpdate?(browser)
        feed.onUnavailable?()

        XCTAssertEqual(states.count, 3)
        XCTAssertEqual(states[1].health, .available)
        XCTAssertEqual(states[1].snapshots.first?.title, "Браузер")
        XCTAssertEqual(
            states[2],
            .init(
                snapshots: [],
                health: .unavailable(
                    message: "Системная музыка недоступна; доступны только Apple Music и Spotify"
                )
            )
        )
        withExtendedLifetime(observation) {}
    }

    func testFallbackSnapshotKeepsDegradedDiagnostic() {
        let feed = NowPlayingFeed()
        let fallback = ManualFallbackStateFetcher()
        let controller = MediaController(
            feed: feed,
            fallbackState: fallback.fetch,
            now: { Date() }
        )
        let source = MediaActivitySource(controller: controller)
        var latest = ActivitySourceState(snapshots: [], health: .available)
        let observation = source.statePublisher.sink { latest = $0 }

        feed.onUnavailable?()
        fallback.resolve(.init(
            app: .music,
            isPlaying: true,
            title: "Apple Music",
            artist: "Исполнитель",
            album: "Альбом",
            duration: 180,
            position: 45,
            artworkURL: nil
        ))

        XCTAssertEqual(latest.snapshots.first?.title, "Apple Music")
        XCTAssertEqual(
            latest.health,
            .unavailable(
                message: "Системная музыка недоступна; доступны только Apple Music и Spotify"
            )
        )
        withExtendedLifetime(observation) {}
    }

    func testStaleFallbackResultDoesNotReplaceDegradedSnapshotOrDiagnostic() {
        let feed = NowPlayingFeed()
        let fallback = ManualFallbackStateFetcher()
        let controller = MediaController(
            feed: feed,
            fallbackState: fallback.fetch,
            now: { Date() }
        )
        let source = MediaActivitySource(controller: controller)
        var latest = ActivitySourceState(snapshots: [], health: .available)
        let observation = source.statePublisher.sink { latest = $0 }

        feed.onUnavailable?()
        controller.setActive(true)
        fallback.resolve(request: 1, state: .init(
            app: .music,
            isPlaying: true,
            title: "Новый результат",
            artist: "Исполнитель",
            album: "Альбом",
            duration: 180,
            position: 45,
            artworkURL: nil
        ))
        fallback.resolve(request: 0, state: .init(
            app: .spotify,
            isPlaying: true,
            title: "Устаревший результат",
            artist: "Исполнитель",
            album: "Альбом",
            duration: 180,
            position: 45,
            artworkURL: nil
        ))

        XCTAssertEqual(latest.snapshots.first?.title, "Новый результат")
        XCTAssertEqual(
            latest.health,
            .unavailable(
                message: "Системная музыка недоступна; доступны только Apple Music и Spotify"
            )
        )
        controller.stop()
        withExtendedLifetime(observation) {}
    }

    func testMediaControllerSuppressesEqualStateEmission() {
        let feed = NowPlayingFeed()
        let controller = MediaController(feed: feed)
        var states: [MediaController.MediaState] = []
        let observation = controller.mediaStatePublisher.sink { states.append($0) }
        var nowPlaying = NowPlayingFeed.Snapshot()
        nowPlaying.title = "Одинаковый track"
        nowPlaying.artist = "Исполнитель"
        nowPlaying.album = "Альбом"
        nowPlaying.duration = 100
        nowPlaying.elapsed = 25

        feed.onUpdate?(nowPlaying)
        feed.onUpdate?(nowPlaying)

        XCTAssertEqual(states.count, 2)
        withExtendedLifetime(observation) {}
    }

    func testProductionSourceKeepsTrackAvailableWithoutSourceName() {
        let feed = NowPlayingFeed()
        let controller = MediaController(feed: feed)
        let source = MediaActivitySource(controller: controller)
        var states: [ActivitySourceState] = []
        let observation = source.statePublisher.sink { states.append($0) }
        var nowPlaying = NowPlayingFeed.Snapshot()
        nowPlaying.title = "Без провайдера"
        nowPlaying.artist = "Исполнитель"
        nowPlaying.album = "Альбом"

        feed.onUpdate?(nowPlaying)

        XCTAssertEqual(states.count, 2)
        XCTAssertEqual(states.last?.snapshots.first?.title, "Без провайдера")
        XCTAssertEqual(states.last?.health, .available)
        withExtendedLifetime(observation) {}
    }

    func testReentrantActionKeepsFIFOPublishOrderForActionAndPassiveSubscribers() {
        let payloads = CurrentValueSubject<MediaActivityPayload?, Never>(nil)
        let controller = FakeMediaActivityController()
        let source = MediaActivitySource(
            payloadPublisher: payloads.eraseToAnyPublisher(),
            controller: controller
        )
        controller.onToggle = {
            payloads.send(self.payload(isPlaying: false))
        }
        var actionPhases: [ActivityPhase?] = []
        let actionObservation = source.statePublisher.sink { state in
            actionPhases.append(state.snapshots.first?.phase)
            guard let active = state.snapshots.first(where: { $0.phase == .active }) else {
                return
            }
            source.perform(.pause, activityID: active.id)
        }
        var passivePhases: [ActivityPhase?] = []
        let passiveObservation = source.statePublisher.sink {
            passivePhases.append($0.snapshots.first?.phase)
        }

        payloads.send(payload())

        XCTAssertEqual(actionPhases, [nil, .active, .paused])
        XCTAssertEqual(passivePhases, [nil, .active, .paused])
        XCTAssertEqual(controller.calls, [.toggle])
        withExtendedLifetime((actionObservation, passiveObservation)) {}
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

    init() {
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
    var onToggle: (() -> Void)?

    func togglePlayPause() {
        calls.append(.toggle)
        onToggle?()
    }
    func next() { calls.append(.next) }
    func previous() { calls.append(.previous) }

    func reset() { calls.removeAll() }
}

@MainActor
private final class ManualFallbackStateFetcher {
    private var completions: [(PlayerState?) -> Void] = []
    private(set) var requestCount = 0

    func fetch(_ completion: @escaping (PlayerState?) -> Void) {
        requestCount += 1
        completions.append(completion)
    }

    func resolve(_ state: PlayerState?) {
        resolve(request: 0, state: state)
    }

    func resolve(request: Int, state: PlayerState?) {
        completions[request](state)
    }
}
