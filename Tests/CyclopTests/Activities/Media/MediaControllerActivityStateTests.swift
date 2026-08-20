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
}

@MainActor
private final class MediaControllerHarness {
    let feed: NowPlayingFeed
    let fallback: ManualFallbackStateFetcher
    let clock: MutableMediaClock
    let controller: MediaController

    init(now: Date = Date(timeIntervalSince1970: 1_000)) {
        let feed = NowPlayingFeed()
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
    }

    func send(_ snapshot: NowPlayingFeed.Snapshot) {
        feed.onUpdate?(snapshot)
    }
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
    private var completion: ((PlayerState?) -> Void)?

    func fetch(_ completion: @escaping (PlayerState?) -> Void) {
        self.completion = completion
    }

    func resolve(_ state: PlayerState?) {
        completion?(state)
        completion = nil
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
