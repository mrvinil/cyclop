import Combine
import Foundation
import XCTest
@testable import Cyclop

@MainActor
final class MediaControllerActivityStateTests: XCTestCase {
    func testTogglePublishesOneCommittedPausedState() {
        let harness = MediaControllerHarness()
        let recorder = MediaStateRecorder(harness.controller)
        harness.send(track(isPlaying: true, position: 20))

        harness.controller.togglePlayPause()

        XCTAssertEqual(recorder.states.count, 3)
        XCTAssertEqual(recorder.states.last?.track?.title, "Песня")
        XCTAssertEqual(recorder.states.last?.isPlaying, false)
        XCTAssertEqual(recorder.states.last?.position, 20)
    }

    func testReentrantRoundTripDeliversFIFOAndKeepsPublisherAlignedWithFields() {
        let harness = MediaControllerHarness()
        var actionStates: [MediaController.MediaState] = []
        var didRoundTrip = false
        let actionObservation = harness.controller.mediaStatePublisher.sink { state in
            actionStates.append(state)
            guard state.isPlaying, state.track != nil, !didRoundTrip else { return }
            didRoundTrip = true
            harness.controller.togglePlayPause()
            harness.controller.togglePlayPause()
        }
        var passiveStates: [MediaController.MediaState] = []
        let passiveObservation = harness.controller.mediaStatePublisher.sink {
            passiveStates.append($0)
        }

        harness.send(track(isPlaying: true, position: 20))

        XCTAssertEqual(actionStates.map(\.isPlaying), [false, true, false, true])
        XCTAssertEqual(passiveStates.map(\.isPlaying), [false, true, false, true])

        var publisherState: MediaController.MediaState?
        let finalObservation = harness.controller.mediaStatePublisher.sink { publisherState = $0 }
        XCTAssertEqual(publisherState, .init(
            track: harness.controller.track,
            isPlaying: harness.controller.isPlaying,
            duration: harness.controller.duration,
            position: harness.controller.position,
            sourceName: harness.controller.sourceName,
            canSkip: harness.controller.canSkip
        ))
        withExtendedLifetime((actionObservation, passiveObservation, finalObservation)) {}
    }

    func testSeekPublishesOneCommittedClampedPosition() {
        let harness = MediaControllerHarness()
        let recorder = MediaStateRecorder(harness.controller)
        harness.send(track(duration: 100, position: 20))

        harness.controller.seek(to: 140)

        XCTAssertEqual(recorder.states.count, 3)
        XCTAssertEqual(recorder.states.last?.position, 100)
        XCTAssertEqual(recorder.states.last?.duration, 100)
    }

    func testEmptyFeedClearsMediaState() {
        let harness = MediaControllerHarness()
        let recorder = MediaStateRecorder(harness.controller)
        harness.send(track())
        harness.send(.init())

        XCTAssertEqual(recorder.states.count, 3)
        XCTAssertNil(recorder.states.last?.track)
        XCTAssertEqual(recorder.states.last?.sourceName, nil)
    }

    func testFallbackResultPublishesOnlyCollectedDirectPlayerState() {
        let harness = MediaControllerHarness()
        let recorder = MediaStateRecorder(harness.controller)
        harness.send(track(title: "Браузер", source: "Яндекс Музыка", commands: []))

        harness.feed.onUnavailable?()
        harness.fallback.resolve(.init(
            app: .music,
            isPlaying: true,
            title: "Apple Music",
            artist: "Исполнитель Music",
            album: "Альбом Music",
            duration: 180,
            position: 45,
            artworkURL: nil
        ))

        XCTAssertEqual(recorder.states.map { $0.track?.title }, [nil, "Браузер", nil, "Apple Music"])
        XCTAssertEqual(recorder.states.last?.sourceName, "Apple Music")
        XCTAssertEqual(recorder.states.last?.canSkip, true)
        XCTAssertEqual(recorder.states.last?.position, 45)
    }

    func testFallbackAbsenceLeavesActivityClearedWithoutDuplicateEmission() {
        let harness = MediaControllerHarness()
        let recorder = MediaStateRecorder(harness.controller)
        harness.send(track(title: "Браузер", source: "Яндекс Музыка", commands: []))

        harness.feed.onUnavailable?()
        harness.fallback.resolve(nil)

        XCTAssertEqual(recorder.states.map { $0.track?.title }, [nil, "Браузер", nil])
    }

    func testLatestFallbackResultWinsWhenRequestsResolveOutOfOrder() {
        let harness = MediaControllerHarness()
        let recorder = MediaStateRecorder(harness.controller)

        harness.feed.onUnavailable?()
        harness.controller.setActive(true)
        XCTAssertEqual(harness.fallback.requestCount, 2)

        harness.fallback.resolve(request: 1, state: fallbackState(title: "Новый результат"))
        harness.fallback.resolve(request: 0, state: fallbackState(title: "Устаревший результат"))

        XCTAssertEqual(recorder.states.map { $0.track?.title }, [nil, nil, "Новый результат"])
        XCTAssertEqual(
            recorder.states.map(\.transport),
            [.systemNowPlaying, .scriptingFallback, .scriptingFallback]
        )
        XCTAssertEqual(harness.controller.track?.title, "Новый результат")
        harness.controller.stop()
    }

    func testLatestFallbackAbsenceWinsWhenOlderResultResolvesAfterward() {
        let harness = MediaControllerHarness()
        let recorder = MediaStateRecorder(harness.controller)

        harness.feed.onUnavailable?()
        harness.controller.setActive(true)
        XCTAssertEqual(harness.fallback.requestCount, 2)

        harness.fallback.resolve(request: 1, state: nil)
        harness.fallback.resolve(request: 0, state: fallbackState(title: "Устаревший результат"))

        XCTAssertEqual(recorder.states.map { $0.track?.title }, [nil, nil])
        XCTAssertEqual(
            recorder.states.map(\.transport),
            [.systemNowPlaying, .scriptingFallback]
        )
        XCTAssertNil(harness.controller.track)
        harness.controller.stop()
    }

    func testFallbackCompletionAfterStopDoesNotPublishOrRestartState() {
        let harness = MediaControllerHarness()
        let recorder = MediaStateRecorder(harness.controller)

        harness.feed.onUnavailable?()
        harness.controller.setActive(true)
        harness.controller.stop()
        harness.fallback.resolve(request: 1, state: fallbackState(title: "Поздний результат", isPlaying: true))

        XCTAssertEqual(recorder.states.map { $0.track?.title }, [nil, nil])
        XCTAssertEqual(
            recorder.states.map(\.transport),
            [.systemNowPlaying, .scriptingFallback]
        )
        XCTAssertNil(harness.controller.track)
    }

    func testRestartAfterFallbackAcceptsSystemSnapshotAndRoutesActionsThroughFeed() {
        let harness = MediaControllerHarness()
        let source = MediaActivitySource(controller: harness.controller)
        var latest = ActivitySourceState(snapshots: [], health: .available)
        let observation = source.statePublisher.sink { latest = $0 }

        harness.feed.onUnavailable?()
        harness.fallback.resolve(fallbackState(title: "Apple Music"))
        harness.controller.stop()
        harness.controller.start()
        harness.send(track(title: "Системный возврат", source: "Safari"))

        XCTAssertEqual(harness.controller.track?.title, "Системный возврат")
        XCTAssertEqual(harness.mediaStatePublisherValue?.transport, .systemNowPlaying)
        XCTAssertEqual(latest.snapshots.first?.title, "Системный возврат")
        XCTAssertEqual(latest.health, .available)

        source.perform(.next, activityID: .init(
            source: "media",
            local: "Системный возврат|Исполнитель|Альбом"
        ))
        XCTAssertEqual(harness.feedProbe.writes, ["cmd 4"])
        XCTAssertEqual(harness.feedProbe.starts, 2)
        withExtendedLifetime(observation) {}
    }

    func testRestartAfterFallbackReinstallsFallbackRequestAndAtomicDiagnostic() {
        let harness = MediaControllerHarness()
        let source = MediaActivitySource(controller: harness.controller)
        var latest = ActivitySourceState(snapshots: [], health: .available)
        let observation = source.statePublisher.sink { latest = $0 }

        harness.feed.onUnavailable?()
        XCTAssertEqual(harness.fallback.requestCount, 1)
        harness.controller.stop()
        harness.controller.start()
        harness.feed.onUnavailable?()

        XCTAssertEqual(harness.fallback.requestCount, 2)
        XCTAssertEqual(harness.mediaStatePublisherValue?.transport, .scriptingFallback)
        XCTAssertEqual(
            latest,
            .init(
                snapshots: [],
                health: .unavailable(
                    message: "Системная музыка недоступна; доступны только Apple Music и Spotify"
                )
            )
        )
        XCTAssertEqual(harness.feedProbe.starts, 2)
        withExtendedLifetime(observation) {}
    }

    func testLateSystemSnapshotAfterFallbackDoesNotReplaceDegradedStateOrRouteBrowserActions() {
        let harness = MediaControllerHarness()
        let source = MediaActivitySource(controller: harness.controller)
        var latest = ActivitySourceState(snapshots: [], health: .available)
        let observation = source.statePublisher.sink { latest = $0 }
        let lateSystemUpdate = harness.feed.onUpdate!

        harness.feed.onUnavailable?()
        harness.fallback.resolve(fallbackState(title: "Apple Music"))
        let stateBeforeLateUpdate = latest
        lateSystemUpdate(track(title: "Браузер", source: "Safari"))

        XCTAssertEqual(latest, stateBeforeLateUpdate)
        XCTAssertEqual(harness.controller.track?.title, "Apple Music")
        XCTAssertEqual(latest.health, .unavailable(
            message: "Системная музыка недоступна; доступны только Apple Music и Spotify"
        ))

        source.perform(.next, activityID: .init(
            source: "media",
            local: "Apple Music|Исполнитель|Альбом"
        ))
        XCTAssertTrue(harness.feedProbe.writes.isEmpty)
        withExtendedLifetime(observation) {}
    }

    func testLateSystemSnapshotAfterStopDoesNotChangeStateOrEmit() {
        let harness = MediaControllerHarness()
        let recorder = MediaStateRecorder(harness.controller)
        let lateSystemUpdate = harness.feed.onUpdate!
        harness.send(track(title: "До остановки"))
        harness.controller.stop()
        let statesBeforeLateUpdate = recorder.states

        lateSystemUpdate(track(title: "После остановки", source: "Google Chrome"))

        XCTAssertEqual(recorder.states, statesBeforeLateUpdate)
        XCTAssertEqual(harness.controller.track?.title, "До остановки")
    }

    func testSystemCallbacksBeforeStartAreInert() {
        let harness = MediaControllerHarness(started: false)
        let recorder = MediaStateRecorder(harness.controller)

        harness.send(track(title: "До запуска"))
        harness.feed.onUnavailable?()

        XCTAssertEqual(recorder.states.count, 1)
        XCTAssertNil(harness.controller.track)
        XCTAssertEqual(harness.fallback.requestCount, 0)
        XCTAssertEqual(harness.feedProbe.starts, 0)
    }

    func testStartAndStopAreIdempotentAcrossTransportCycles() {
        let harness = MediaControllerHarness()

        harness.controller.start()
        harness.controller.stop()
        harness.controller.stop()
        harness.controller.start()
        harness.controller.start()

        XCTAssertEqual(harness.feedProbe.starts, 2)
    }

    func testReentrantStopDuringSystemResetDoesNotStartStoppedFeed() {
        let harness = MediaControllerHarness()
        harness.feed.onUnavailable?()
        harness.fallback.resolve(fallbackState(title: "Apple Music"))
        var stopOnReset = false
        let observation = harness.controller.mediaStatePublisher.sink { state in
            guard stopOnReset, state.transport == .systemNowPlaying, state.track == nil else { return }
            harness.controller.stop()
        }

        harness.controller.stop()
        stopOnReset = true
        harness.controller.start()

        XCTAssertEqual(harness.feedProbe.starts, 1)
        withExtendedLifetime(observation) {}
    }

    func testReentrantStopDuringFallbackResetDoesNotInstallRefreshRequest() {
        let harness = MediaControllerHarness()
        var stopOnFallbackReset = true
        let observation = harness.controller.mediaStatePublisher.sink { state in
            guard stopOnFallbackReset, state.transport == .scriptingFallback, state.track == nil else { return }
            stopOnFallbackReset = false
            harness.controller.stop()
        }

        harness.feed.onUnavailable?()

        XCTAssertEqual(harness.fallback.requestCount, 0)
        withExtendedLifetime(observation) {}
    }

    func testRestartClearsPendingSeekBeforeFirstNewSystemSnapshot() {
        let harness = MediaControllerHarness()
        let source = MediaActivitySource(controller: harness.controller)
        var latest = ActivitySourceState(snapshots: [], health: .available)
        let observation = source.statePublisher.sink { latest = $0 }
        harness.send(track(title: "Первый", duration: 300, position: 100))
        harness.controller.seek(to: 200)

        harness.controller.stop()
        harness.controller.start()
        harness.send(track(title: "Новый", duration: 400, position: 30))

        XCTAssertEqual(harness.controller.position, 30)
        XCTAssertEqual(latest.snapshots.first?.progress, 0.075)
        withExtendedLifetime(observation) {}
    }

    func testTickPublishesEndClampOnceAndSuppressesRepeatedEndState() {
        let harness = MediaControllerHarness(now: Date(timeIntervalSince1970: 1_000))
        let recorder = MediaStateRecorder(harness.controller)
        harness.send(track(isPlaying: true, duration: 100, position: 99))
        harness.clock.advance(by: 2)

        harness.controller.setActive(true)
        harness.controller.setActive(false)
        harness.controller.setActive(true)
        harness.controller.stop()

        XCTAssertEqual(recorder.states.count, 3)
        XCTAssertEqual(recorder.states.last?.position, 100)
    }

    func testNilSourceNameStillPublishesTrackState() {
        let harness = MediaControllerHarness()
        let recorder = MediaStateRecorder(harness.controller)
        harness.send(track(source: nil))

        XCTAssertEqual(recorder.states.count, 2)
        XCTAssertEqual(recorder.states.last?.track?.title, "Песня")
        XCTAssertNil(recorder.states.last?.sourceName)
    }

    private func track(
        title: String = "Песня",
        isPlaying: Bool = false,
        duration: TimeInterval = 120,
        position: TimeInterval = 30,
        source: String? = "Яндекс Музыка",
        commands: Set<Int>? = nil
    ) -> NowPlayingFeed.Snapshot {
        var snapshot = NowPlayingFeed.Snapshot()
        snapshot.isPlaying = isPlaying
        snapshot.title = title
        snapshot.artist = "Исполнитель"
        snapshot.album = "Альбом"
        snapshot.duration = duration
        snapshot.elapsed = position
        snapshot.source = source
        snapshot.commands = commands
        return snapshot
    }

    private func fallbackState(title: String, isPlaying: Bool = false) -> PlayerState {
        .init(
            app: .music,
            isPlaying: isPlaying,
            title: title,
            artist: "Исполнитель",
            album: "Альбом",
            duration: 180,
            position: 45,
            artworkURL: nil
        )
    }
}

@MainActor
private final class MediaControllerHarness {
    let feed: NowPlayingFeed
    let fallback: ManualFallbackStateFetcher
    let clock: MutableMediaClock
    let controller: MediaController
    let feedProbe = MediaFeedProbe()

    init(now: Date = Date(timeIntervalSince1970: 1_000), started: Bool = true) {
        let feed = NowPlayingFeed(
            onStart: { [feedProbe] in feedProbe.starts += 1 },
            onWrite: { [feedProbe] line in feedProbe.writes.append(line) }
        )
        let fallback = ManualFallbackStateFetcher()
        let clock = MutableMediaClock(now: now)
        self.feed = feed
        self.fallback = fallback
        self.clock = clock
        controller = MediaController(
            feed: feed,
            fallbackState: fallback.fetch,
            now: { clock.now }
        )
        if started {
            controller.start()
        }
    }

    func send(_ snapshot: NowPlayingFeed.Snapshot) {
        feed.onUpdate?(snapshot)
    }

    var mediaStatePublisherValue: MediaController.MediaState? {
        var value: MediaController.MediaState?
        let observation = controller.mediaStatePublisher.sink { value = $0 }
        withExtendedLifetime(observation) {}
        return value
    }
}

@MainActor
private final class MediaFeedProbe {
    var starts = 0
    var writes: [String] = []
}

@MainActor
private final class MediaStateRecorder {
    private var observation: AnyCancellable?
    private(set) var states: [MediaController.MediaState] = []

    init(_ controller: MediaController) {
        observation = controller.mediaStatePublisher.sink { [weak self] state in
            self?.states.append(state)
        }
    }
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

@MainActor
private final class MutableMediaClock {
    var now: Date

    init(now: Date) {
        self.now = now
    }

    func advance(by interval: TimeInterval) {
        now.addTimeInterval(interval)
    }
}
