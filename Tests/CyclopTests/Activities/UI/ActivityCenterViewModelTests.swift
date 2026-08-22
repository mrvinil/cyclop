import Combine
import XCTest
@testable import Cyclop

@MainActor
final class ActivityCenterViewModelTests: XCTestCase {
    func testBuildsOrderedCardsAndMasksSensitiveText() async {
        let coordinator = ActivityCenterCoordinatorFake()
        let timers = ActivityCenterTimerFake()
        let privacy = PrivacyMode()
        let model = ActivityCenterViewModel(
            coordinator: coordinator,
            timers: timers,
            privacy: privacy
        )
        let timerID = ActivityID(source: "timers", local: "00000000-0000-0000-0000-000000000001")
        timers.remainingTimes[timerID.local] = 125

        coordinator.send(ActivityDisplayState(
            allActivities: [
                snapshot(id: .init(source: "media", local: "song"), kind: .media, phase: .active, title: "Песня"),
                snapshot(id: timerID, kind: .timer, phase: .active, title: "Фокус"),
                snapshot(id: .init(source: "downloads.external", local: "archive"), kind: .download, phase: .completed, title: "Личный архив")
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

    func testMapsKindSpecificProducerDetailsAndMeetingStartToCards() {
        let meetingStart = Date(timeIntervalSince1970: 2_000)
        let media = snapshot(
            id: .init(source: "media", local: "song-details"),
            kind: .media,
            phase: .active,
            title: "Песня",
            containsSensitiveText: false,
            presentationDetails: .media(sourceName: "Spotify")
        )
        let meeting = snapshot(
            id: .init(source: "meetings", local: "meeting-details"),
            kind: .meeting,
            phase: .ambient,
            title: "Синк",
            deadline: meetingStart
        )
        let download = snapshot(
            id: .init(source: "downloads.external", local: "download-details"),
            kind: .download,
            phase: .active,
            title: "Архив",
            presentationDetails: .download(bytesReceived: 512, totalBytes: 1_024)
        )

        let cards = ActivityCenterPresentationMapper.cards(
            from: [media, meeting, download],
            timers: ActivityCenterTimerFake(),
            privacy: PrivacyMode()
        )

        XCTAssertEqual(cards.first(where: { $0.id == media.id })?.sourceName, "Spotify")
        XCTAssertEqual(cards.first(where: { $0.id == meeting.id })?.start, meetingStart)
        XCTAssertEqual(cards.first(where: { $0.id == download.id })?.bytesReceived, 512)
        XCTAssertEqual(cards.first(where: { $0.id == download.id })?.totalBytes, 1_024)
    }

    func testMaskingRemovesMediaSourceBeforePublishingCardModel() async {
        let coordinator = ActivityCenterCoordinatorFake()
        let privacy = PrivacyMode()
        let media = snapshot(
            id: .init(source: "media", local: "private-source"),
            kind: .media,
            phase: .active,
            title: "Песня",
            presentationDetails: .media(sourceName: "Секретный источник")
        )
        let model = makeModel(
            coordinator: coordinator,
            timers: ActivityCenterTimerFake(),
            privacy: privacy
        )
        coordinator.send(displayState([media]))
        privacy.setCovering(.activities, true)
        await Task.yield()

        XCTAssertTrue(model.cards[0].isMasked)
        XCTAssertNil(model.cards[0].sourceName)
    }

    func testVisiblePaneMarksCurrentAndNewTerminalDownloadsWithoutMarkingTimers() {
        let coordinator = ActivityCenterCoordinatorFake()
        let model = makeModel(
            coordinator: coordinator,
            timers: ActivityCenterTimerFake(),
            privacy: PrivacyMode()
        )
        let completedDownload = snapshot(
            id: .init(source: "downloads.external", local: "first"),
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
            id: .init(source: "downloads.external", local: "second"),
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
            privacy: PrivacyMode()
        )
        let id = ActivityID(source: "downloads.external", local: "file")

        model.reveal(id)

        XCTAssertEqual(model.scrollTarget, id)
        XCTAssertTrue(coordinator.performed.isEmpty)
        model.perform(.reveal, on: id)
        XCTAssertEqual(coordinator.performed, [.init(action: .reveal, id: id)])
        model.clearScrollTarget()
        XCTAssertNil(model.scrollTarget)
    }

    func testClearDownloadHistoryRoutesOnlyTerminalDownloads() {
        let coordinator = ActivityCenterCoordinatorFake()
        let model = makeModel(
            coordinator: coordinator,
            timers: ActivityCenterTimerFake(),
            privacy: PrivacyMode()
        )
        let completedExternal = snapshot(
            id: .init(source: "downloads.external", local: "external"),
            kind: .download,
            phase: .completed,
            title: "Браузер"
        )
        let active = snapshot(
            id: .init(source: "downloads.external", local: "active"),
            kind: .download,
            phase: .active,
            title: "В процессе"
        )
        coordinator.send(displayState([active, completedExternal]))

        model.clearDownloadHistory()

        XCTAssertEqual(
            coordinator.performed
                .map { "\($0.action.rawValue):\($0.id.source):\($0.id.local)" }
                .sorted(),
            ["dismiss:downloads.external:external"]
        )
        XCTAssertFalse(coordinator.performed.contains { $0.id == active.id })
    }

    func testPrivacyKeyKeepsActivitiesWithAmbiguousConcatenationSeparate() async {
        let coordinator = ActivityCenterCoordinatorFake()
        let privacy = PrivacyMode()
        let model = makeModel(
            coordinator: coordinator,
            timers: ActivityCenterTimerFake(),
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

    func testUsesPublishedDisplayStateValueWithoutWaitingForAnotherCoordinatorUpdate() {
        let coordinator = ActivityCenterCoordinatorFake()
        let model = makeModel(
            coordinator: coordinator,
            timers: ActivityCenterTimerFake(),
            privacy: PrivacyMode()
        )
        let media = snapshot(
            id: .init(source: "media", local: "single-update"),
            kind: .media,
            phase: .active,
            title: "Новая песня"
        )
        let state = ActivityDisplayState(
            allActivities: [media],
            primary: media,
            indicators: [],
            hiddenIndicatorCount: 0,
            attention: nil,
            diagnostics: ["media": .unavailable(message: "Источник музыки недоступен")]
        )

        coordinator.send(state)

        XCTAssertEqual(model.cards.map(\.id), [media.id])
        XCTAssertEqual(model.diagnostics, [
            .init(id: "media", message: "Источник музыки недоступен"),
        ])
    }

    func testReservesSortedTerminalBatchBeforeReentrantMarkViewedPublication() {
        let coordinator = ActivityCenterCoordinatorFake()
        coordinator.republishesWhenMarkedViewed = true
        let model = makeModel(
            coordinator: coordinator,
            timers: ActivityCenterTimerFake(),
            privacy: PrivacyMode()
        )
        let first = snapshot(
            id: .init(source: "downloads.external", local: "alpha"),
            kind: .download,
            phase: .completed,
            title: "Первый"
        )
        let second = snapshot(
            id: .init(source: "downloads.external", local: "beta"),
            kind: .download,
            phase: .failed,
            title: "Второй"
        )
        coordinator.send(displayState([second, first]))

        model.setVisible(true)

        XCTAssertEqual(coordinator.viewed, [first.id, second.id])
    }

    private func makeModel(
        coordinator: ActivityCenterCoordinatorFake,
        timers: ActivityCenterTimerFake,
        privacy: PrivacyMode
    ) -> ActivityCenterViewModel {
        ActivityCenterViewModel(
            coordinator: coordinator,
            timers: timers,
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
        title: String,
        deadline: Date? = nil,
        containsSensitiveText: Bool = true,
        presentationDetails: ActivitySnapshotPresentationDetails? = nil,
        availableActions: Set<ActivityAction> = [.reveal, .dismiss, .open]
    ) -> ActivitySnapshot {
        ActivitySnapshot(
            id: id,
            sourceID: id.source,
            kind: kind,
            phase: phase,
            title: title,
            subtitle: "Секретные детали",
            progress: 0.25,
            deadline: deadline,
            occurredAt: nil,
            availableActions: availableActions,
            containsSensitiveText: containsSensitiveText,
            presentationDetails: presentationDetails
        )
    }
}

@MainActor
private final class ActivityCenterCoordinatorFake: ActivityCenterCoordinating {
    struct PerformedAction: Equatable {
        let action: ActivityAction
        let id: ActivityID
    }

    @Published private(set) var displayState = ActivityDisplayState(
        allActivities: [], primary: nil, indicators: [], hiddenIndicatorCount: 0, attention: nil, diagnostics: [:]
    )

    var displayStatePublisher: AnyPublisher<ActivityDisplayState, Never> { $displayState.eraseToAnyPublisher() }
    private(set) var performed: [PerformedAction] = []
    private(set) var viewed: [ActivityID] = []
    var republishesWhenMarkedViewed = false

    func send(_ displayState: ActivityDisplayState) { self.displayState = displayState }
    func perform(_ action: ActivityAction, activityID: ActivityID) {
        performed.append(.init(action: action, id: activityID))
    }
    func markViewed(_ activityID: ActivityID) {
        viewed.append(activityID)
        if republishesWhenMarkedViewed {
            displayState = displayState
        }
    }
}

@MainActor
final class ActivityCenterTimerFake: ActivityCenterTiming {
    private let revision = CurrentValueSubject<Int, Never>(0)
    var remainingTimes: [String: TimeInterval] = [:]
    private(set) var visibility: [Bool] = []

    var countdownRevisionPublisher: AnyPublisher<Int, Never> { revision.eraseToAnyPublisher() }
    func remaining(for id: UUID) -> TimeInterval? { remainingTimes[id.uuidString] }
    func setCountdownVisible(_ isVisible: Bool) { visibility.append(isVisible) }
    func create(name: String, duration: TimeInterval) throws -> UUID { UUID() }
    func advanceRevision() { revision.send(revision.value + 1) }
}
