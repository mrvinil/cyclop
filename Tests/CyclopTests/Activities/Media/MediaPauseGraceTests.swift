import Combine
import Foundation
import XCTest
@testable import Cyclop

@MainActor
final class MediaPauseGraceTests: XCTestCase {
    func testPausedTrackRemainsForFifteenSecondsThenHides() {
        let harness = MediaPauseGraceHarness(now: Date(timeIntervalSince1970: 1_000))

        harness.send(playingTrack())
        harness.send(pausedTrack())

        XCTAssertEqual(harness.latest.snapshots.first?.phase, .paused)
        XCTAssertEqual(harness.scheduler.nextDate, Date(timeIntervalSince1970: 1_015))

        harness.fireNext()

        XCTAssertTrue(harness.latest.snapshots.isEmpty)
    }

    func testInitialPausedTrackStartsItsOwnGracePeriod() {
        let harness = MediaPauseGraceHarness(now: Date(timeIntervalSince1970: 1_000))

        harness.send(pausedTrack())

        XCTAssertEqual(harness.latest.snapshots.first?.phase, .paused)
        XCTAssertEqual(harness.scheduler.nextDate, Date(timeIntervalSince1970: 1_015))
    }

    func testResumeBeforeDeadlineKeepsTrackVisibleWhenCancelledCallbackFires() {
        let harness = MediaPauseGraceHarness(now: Date(timeIntervalSince1970: 1_000))

        harness.send(pausedTrack())
        let pausedWake = harness.scheduler.lastIndex
        harness.send(playingTrack())
        harness.scheduler.fire(index: pausedWake)

        XCTAssertEqual(harness.latest.snapshots.first?.phase, .active)
    }

    func testNewTrackSurvivesCancelledCallbackForPreviousPausedTrack() {
        let harness = MediaPauseGraceHarness(now: Date(timeIntervalSince1970: 1_000))

        harness.send(pausedTrack(trackKey: "track-1"))
        let firstWake = harness.scheduler.lastIndex
        harness.send(pausedTrack(trackKey: "track-2"))
        harness.scheduler.fire(index: firstWake)

        XCTAssertEqual(harness.latest.snapshots.first?.id, .init(source: "media", local: "track-2"))
        XCTAssertEqual(harness.latest.snapshots.first?.phase, .paused)
    }

    func testNilPayloadHidesImmediatelyAndStartsNewGraceCycleForNextPausedPayload() {
        let harness = MediaPauseGraceHarness(now: Date(timeIntervalSince1970: 1_000))

        harness.send(pausedTrack())
        let firstWake = harness.scheduler.lastIndex
        harness.send(nil)
        XCTAssertTrue(harness.latest.snapshots.isEmpty)

        harness.clock.advance(by: 2)
        harness.send(pausedTrack())
        harness.scheduler.fire(index: firstWake)

        XCTAssertEqual(harness.latest.snapshots.first?.phase, .paused)
        XCTAssertEqual(harness.scheduler.nextDate, Date(timeIntervalSince1970: 1_017))
    }

    func testRepeatedPausedPayloadKeepsOriginalAbsoluteDeadline() {
        let harness = MediaPauseGraceHarness(now: Date(timeIntervalSince1970: 1_000))

        harness.send(pausedTrack())
        harness.clock.advance(by: 10)
        harness.send(pausedTrack(title: "Обновлённые метаданные"))

        XCTAssertEqual(harness.latest.snapshots.first?.title, "Обновлённые метаданные")
        XCTAssertEqual(harness.scheduler.nextDate, Date(timeIntervalSince1970: 1_015))
    }

    func testPausedTrackAtDeadlineStaysHiddenUntilResumeOrNewTrack() {
        let harness = MediaPauseGraceHarness(now: Date(timeIntervalSince1970: 1_000))

        harness.send(pausedTrack())
        harness.fireNext()
        harness.send(pausedTrack(title: "Повторное состояние"))

        XCTAssertTrue(harness.latest.snapshots.isEmpty)

        harness.send(playingTrack())
        XCTAssertEqual(harness.latest.snapshots.first?.phase, .active)

        harness.send(pausedTrack())
        XCTAssertEqual(harness.latest.snapshots.first?.phase, .paused)
        XCTAssertEqual(harness.scheduler.nextDate, Date(timeIntervalSince1970: 1_030))
    }

    func testPausedPayloadReconcilesPastDeadlineAfterClockJumpsForward() {
        let harness = MediaPauseGraceHarness(now: Date(timeIntervalSince1970: 1_000))

        harness.send(pausedTrack())
        harness.clock.advance(by: 16)
        harness.send(pausedTrack(title: "Запоздалое обновление"))

        XCTAssertTrue(harness.latest.snapshots.isEmpty)
    }

    func testClockRollbackRearmsOriginalDeadlineWithoutExtendingGrace() {
        let harness = MediaPauseGraceHarness(now: Date(timeIntervalSince1970: 1_000))

        harness.send(pausedTrack())
        harness.clock.now = Date(timeIntervalSince1970: 900)
        harness.scheduler.fireNext()

        XCTAssertEqual(harness.scheduler.nextDate, Date(timeIntervalSince1970: 1_015))

        harness.clock.now = Date(timeIntervalSince1970: 1_015)
        harness.scheduler.fireNext()

        XCTAssertTrue(harness.latest.snapshots.isEmpty)
    }

    private func playingTrack(trackKey: String = "track-1") -> MediaActivityPayload {
        payload(trackKey: trackKey, isPlaying: true)
    }

    private func pausedTrack(
        trackKey: String = "track-1",
        title: String = "Песня"
    ) -> MediaActivityPayload {
        payload(trackKey: trackKey, title: title, isPlaying: false)
    }

    private func payload(
        trackKey: String,
        title: String = "Песня",
        isPlaying: Bool
    ) -> MediaActivityPayload {
        .init(
            trackKey: trackKey,
            title: title,
            artist: "Исполнитель",
            album: "Альбом",
            sourceName: "Яндекс Музыка",
            isPlaying: isPlaying,
            duration: 240,
            position: 60,
            canSkip: true
        )
    }
}

@MainActor
private final class MediaPauseGraceHarness {
    private let payloads = CurrentValueSubject<MediaActivityPayload?, Never>(nil)
    let clock: MutableActivityClock
    let scheduler = MediaPauseGraceScheduler()
    private let source: MediaActivitySource
    private let controller = MediaPauseGraceController()
    private var observation: AnyCancellable?
    private(set) var latest = ActivitySourceState(snapshots: [], health: .available)

    init(now: Date) {
        clock = MutableActivityClock(now: now)
        source = MediaActivitySource(
            payloadPublisher: payloads.eraseToAnyPublisher(),
            controller: controller,
            clock: clock,
            scheduler: scheduler
        )
        observation = source.statePublisher.sink { [weak self] state in
            self?.latest = state
        }
    }

    func send(_ payload: MediaActivityPayload?) {
        payloads.send(payload)
    }

    func fireNext() {
        guard let nextDate = scheduler.nextDate else {
            XCTFail("Ожидалось запланированное скрытие paused-трека")
            return
        }
        clock.now = nextDate
        scheduler.fireNext()
    }
}

@MainActor
private final class MediaPauseGraceScheduler: ActivityScheduling {
    struct Entry {
        let date: Date
        let action: @MainActor () -> Void
        let cancellation: MediaPauseGraceCancellation
    }

    private(set) var entries: [Entry] = []

    var nextDate: Date? {
        entries
            .filter { !$0.cancellation.isFinished }
            .map(\.date)
            .min()
    }

    var lastIndex: Int {
        entries.indices.last!
    }

    @discardableResult
    func schedule(
        at date: Date,
        _ action: @escaping @MainActor () -> Void
    ) -> ActivityCancellation {
        let cancellation = MediaPauseGraceCancellation()
        entries.append(.init(date: date, action: action, cancellation: cancellation))
        return cancellation
    }

    func fireNext() {
        guard let index = entries.indices
            .filter({ !entries[$0].cancellation.isFinished })
            .min(by: { entries[$0].date < entries[$1].date }) else {
            XCTFail("Нет запланированного действия для запуска")
            return
        }
        fire(index: index)
    }

    func fire(index: Int) {
        entries[index].cancellation.finish()
        entries[index].action()
    }
}

@MainActor
private final class MediaPauseGraceCancellation: ActivityCancellation {
    private(set) var isFinished = false

    func cancel() {
        isFinished = true
    }

    func finish() {
        isFinished = true
    }
}

@MainActor
private final class MediaPauseGraceController: MediaActivityControlling {
    func togglePlayPause() {}
    func next() {}
    func previous() {}
}
