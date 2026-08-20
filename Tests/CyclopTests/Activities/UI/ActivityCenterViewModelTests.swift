import Combine
import XCTest
@testable import Cyclop

@MainActor
final class ActivityCenterViewModelTests: XCTestCase {
    func testBuildsOrderedCardsAndMasksSensitiveText() async {
        let coordinator = ActivityCenterCoordinatorFake()
        let timers = ActivityCenterTimerFake()
        let downloads = ActivityCenterDownloadFake()
        let privacy = PrivacyMode()
        let model = ActivityCenterViewModel(
            coordinator: coordinator,
            timers: timers,
            downloads: downloads,
            privacy: privacy
        )
        let timerID = ActivityID(source: "timers", local: "00000000-0000-0000-0000-000000000001")
        timers.remainingTimes[timerID.local] = 125

        coordinator.send(ActivityDisplayState(
            allActivities: [
                snapshot(id: .init(source: "media", local: "song"), kind: .media, phase: .active, title: "Песня"),
                snapshot(id: timerID, kind: .timer, phase: .active, title: "Фокус"),
                snapshot(id: .init(source: "downloads.own", local: "archive"), kind: .download, phase: .completed, title: "Личный архив")
            ],
            primary: nil,
            indicators: [],
            hiddenIndicatorCount: 0,
            attention: nil,
            diagnostics: [:]
        ))
        privacy.setCovering(.activities, true)
        await Task.yield()

        XCTAssertEqual(model.cards.map(\.kind), [.timer, .media, .download])
        XCTAssertEqual(model.cards[1].title, localized("Hidden Activity"))
        XCTAssertEqual(model.cards[1].subtitle, localized("Hidden Activity"))
        XCTAssertEqual(model.cards[1].isMasked, true)
        XCTAssertEqual(model.cards[0].countdown, 125)
        XCTAssertEqual(model.cards[2].actions, [.dismiss, .open, .reveal])
    }

    func testVisiblePaneMarksCurrentAndNewTerminalDownloadsWithoutMarkingTimers() {
        let coordinator = ActivityCenterCoordinatorFake()
        let model = makeModel(
            coordinator: coordinator,
            timers: ActivityCenterTimerFake(),
            downloads: ActivityCenterDownloadFake(),
            privacy: PrivacyMode()
        )
        let completedDownload = snapshot(
            id: .init(source: "downloads.own", local: "first"),
            kind: .download,
            phase: .completed,
            title: "Первый файл"
        )
        let completedTimer = snapshot(
            id: .init(source: "timers", local: "00000000-0000-0000-0000-000000000002"),
            kind: .timer,
            phase: .completed,
            title: "Таймер"
        )
        coordinator.send(displayState([completedDownload, completedTimer]))

        model.setVisible(true)

        XCTAssertEqual(Set(coordinator.viewed), [completedDownload.id])

        let failedDownload = snapshot(
            id: .init(source: "downloads.own", local: "second"),
            kind: .download,
            phase: .failed,
            title: "Второй файл"
        )
        coordinator.send(displayState([completedDownload, completedTimer, failedDownload]))

        XCTAssertEqual(Set(coordinator.viewed), [completedDownload.id, failedDownload.id])
        XCTAssertEqual(model.cards.map(\.id), [completedTimer.id, failedDownload.id, completedDownload.id])
    }

    func testCountdownRefreshesOnlyFromTimerRevisionAndVisibilityIncludesCompactPresentation() {
        let coordinator = ActivityCenterCoordinatorFake()
        let timers = ActivityCenterTimerFake()
        let timerID = ActivityID(source: "timers", local: "00000000-0000-0000-0000-000000000003")
        timers.remainingTimes[timerID.local] = 90
        let model = makeModel(
            coordinator: coordinator,
            timers: timers,
            downloads: ActivityCenterDownloadFake(),
            privacy: PrivacyMode()
        )
        coordinator.send(displayState([snapshot(id: timerID, kind: .timer, phase: .active, title: "Фокус")]))

        XCTAssertEqual(model.cards.first?.countdown, 90)
        XCTAssertEqual(timers.visibility, [])

        model.setCompactTimerVisible(true)
        model.setVisible(true)
        model.setCompactTimerVisible(false)
        model.setVisible(false)

        XCTAssertEqual(timers.visibility, [true, false])
        timers.remainingTimes[timerID.local] = 89
        timers.advanceRevision()
        XCTAssertEqual(model.cards.first?.countdown, 89)
    }

    func testRevealSetsOnlyScrollTargetAndFileRevealRoutesThroughAction() {
        let coordinator = ActivityCenterCoordinatorFake()
        let model = makeModel(
            coordinator: coordinator,
            timers: ActivityCenterTimerFake(),
            downloads: ActivityCenterDownloadFake(),
            privacy: PrivacyMode()
        )
        let id = ActivityID(source: "downloads.own", local: "file")

        model.reveal(id)

        XCTAssertEqual(model.scrollTarget, id)
        XCTAssertTrue(coordinator.performed.isEmpty)
        model.perform(.reveal, on: id)
        XCTAssertEqual(coordinator.performed, [.init(action: .reveal, id: id)])
        model.clearScrollTarget()
        XCTAssertNil(model.scrollTarget)
    }

    func testComposerPublishesRussianValidationAndStartErrors() {
        let downloads = ActivityCenterDownloadFake()
        let model = makeModel(
            coordinator: ActivityCenterCoordinatorFake(),
            timers: ActivityCenterTimerFake(),
            downloads: downloads,
            privacy: PrivacyMode()
        )

        XCTAssertThrowsError(try model.createTimer(name: "", duration: 0)) {
            XCTAssertEqual($0 as? ActivityCenterViewModelError, .invalidTimerDuration)
        }
        XCTAssertEqual(model.transientError, "Укажите длительность таймера")

        model.downloadURL = "ftp://example.com/file.zip"
        XCTAssertThrowsError(try model.enqueueDownload()) {
            XCTAssertEqual($0 as? ActivityCenterViewModelError, .invalidDownloadURL)
        }
        XCTAssertEqual(model.transientError, "Вставьте ссылку HTTP или HTTPS")

        downloads.error = DownloadFakeError.failed
        XCTAssertThrowsError(try model.enqueueDownload(url: URL(string: "https://example.com/file.zip")!)) {
            XCTAssertEqual($0 as? ActivityCenterViewModelError, .downloadStartFailed)
        }
        XCTAssertEqual(model.transientError, "Не удалось начать загрузку")
    }

    func testPrivacyKeyKeepsActivitiesWithAmbiguousConcatenationSeparate() async {
        let coordinator = ActivityCenterCoordinatorFake()
        let privacy = PrivacyMode()
        let model = makeModel(
            coordinator: coordinator,
            timers: ActivityCenterTimerFake(),
            downloads: ActivityCenterDownloadFake(),
            privacy: privacy
        )
        let firstID = ActivityID(source: "a", local: "bc")
        let secondID = ActivityID(source: "ab", local: "c")
        coordinator.send(displayState([
            snapshot(id: firstID, kind: .media, phase: .active, title: "Первый"),
            snapshot(id: secondID, kind: .media, phase: .active, title: "Второй")
        ]))
        privacy.setCovering(.activities, true)
        model.toggleMasking(for: firstID)
        await Task.yield()

        XCTAssertNotEqual(
            ActivityCenterPresentationMapper.privacyKey(for: firstID),
            ActivityCenterPresentationMapper.privacyKey(for: secondID)
        )
        XCTAssertFalse(model.cards.first(where: { $0.id == firstID })?.isMasked ?? true)
        XCTAssertTrue(model.cards.first(where: { $0.id == secondID })?.isMasked ?? false)
    }

    func testUnavailableSourceProducesDiagnosticWithoutRemovingActivityCard() {
        let coordinator = ActivityCenterCoordinatorFake()
        let model = makeModel(
            coordinator: coordinator,
            timers: ActivityCenterTimerFake(),
            downloads: ActivityCenterDownloadFake(),
            privacy: PrivacyMode()
        )
        let media = snapshot(
            id: .init(source: "media", local: "track"),
            kind: .media,
            phase: .active,
            title: "Песня"
        )
        coordinator.send(ActivityDisplayState(
            allActivities: [media],
            primary: media,
            indicators: [],
            hiddenIndicatorCount: 0,
            attention: nil,
            diagnostics: ["media": .unavailable(message: "Источник музыки недоступен")]
        ))

        XCTAssertEqual(model.cards.map(\.id), [media.id])
        XCTAssertEqual(model.diagnostics, [
            .init(id: "media", message: "Источник музыки недоступен"),
        ])
    }

    private func makeModel(
        coordinator: ActivityCenterCoordinatorFake,
        timers: ActivityCenterTimerFake,
        downloads: ActivityCenterDownloadFake,
        privacy: PrivacyMode
    ) -> ActivityCenterViewModel {
        ActivityCenterViewModel(
            coordinator: coordinator,
            timers: timers,
            downloads: downloads,
            privacy: privacy
        )
    }

    private func displayState(_ snapshots: [ActivitySnapshot]) -> ActivityDisplayState {
        ActivityDisplayState(
            allActivities: snapshots,
            primary: nil,
            indicators: [],
            hiddenIndicatorCount: 0,
            attention: nil,
            diagnostics: [:]
        )
    }

    private func snapshot(
        id: ActivityID,
        kind: ActivityKind,
        phase: ActivityPhase,
        title: String
    ) -> ActivitySnapshot {
        ActivitySnapshot(
            id: id,
            sourceID: id.source,
            kind: kind,
            phase: phase,
            title: title,
            subtitle: "Секретные детали",
            progress: 0.25,
            deadline: nil,
            occurredAt: nil,
            availableActions: [.reveal, .dismiss, .open],
            containsSensitiveText: true
        )
    }
}

@MainActor
private final class ActivityCenterCoordinatorFake: ActivityCenterCoordinating {
    struct PerformedAction: Equatable {
        let action: ActivityAction
        let id: ActivityID
    }

    private let state = CurrentValueSubject<ActivityDisplayState, Never>(.init(
        allActivities: [], primary: nil, indicators: [], hiddenIndicatorCount: 0, attention: nil, diagnostics: [:]
    ))

    var displayState: ActivityDisplayState { state.value }
    var displayStatePublisher: AnyPublisher<ActivityDisplayState, Never> { state.eraseToAnyPublisher() }
    private(set) var performed: [PerformedAction] = []
    private(set) var viewed: [ActivityID] = []

    func send(_ displayState: ActivityDisplayState) { state.send(displayState) }
    func perform(_ action: ActivityAction, activityID: ActivityID) {
        performed.append(.init(action: action, id: activityID))
    }
    func markViewed(_ activityID: ActivityID) { viewed.append(activityID) }
}

@MainActor
private final class ActivityCenterTimerFake: ActivityCenterTiming {
    private let revision = CurrentValueSubject<Int, Never>(0)
    var remainingTimes: [String: TimeInterval] = [:]
    private(set) var visibility: [Bool] = []

    var countdownRevisionPublisher: AnyPublisher<Int, Never> { revision.eraseToAnyPublisher() }
    func remaining(for id: UUID) -> TimeInterval? { remainingTimes[id.uuidString] }
    func setCountdownVisible(_ isVisible: Bool) { visibility.append(isVisible) }
    func create(name: String, duration: TimeInterval) throws -> UUID { UUID() }
    func advanceRevision() { revision.send(revision.value + 1) }
}

@MainActor
private final class ActivityCenterDownloadFake: ActivityCenterDownloadEnqueuing {
    var error: Error?

    func enqueue(_ rawURL: String) throws -> UUID {
        if let error { throw error }
        return UUID()
    }
}

private enum DownloadFakeError: Error {
    case failed
}
