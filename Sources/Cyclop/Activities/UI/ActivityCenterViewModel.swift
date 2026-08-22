import Combine
import Foundation

@MainActor
protocol ActivityCenterCoordinating: AnyObject {
    var displayState: ActivityDisplayState { get }
    var displayStatePublisher: AnyPublisher<ActivityDisplayState, Never> { get }

    func perform(_ action: ActivityAction, activityID: ActivityID)
    func markViewed(_ activityID: ActivityID)
}

extension ActivityCoordinator: ActivityCenterCoordinating {
    var displayStatePublisher: AnyPublisher<ActivityDisplayState, Never> {
        $displayState.eraseToAnyPublisher()
    }
}

@MainActor
protocol ActivityCenterTiming: AnyObject {
    var countdownRevisionPublisher: AnyPublisher<Int, Never> { get }

    func create(name: String, duration: TimeInterval) throws -> UUID
    func remaining(for id: UUID) -> TimeInterval?
    func setCountdownVisible(_ isVisible: Bool)
}

extension TimerStore: ActivityCenterTiming {
    var countdownRevisionPublisher: AnyPublisher<Int, Never> {
        $countdownRevision.eraseToAnyPublisher()
    }
}

@MainActor
protocol ActivityCenterDownloadEnqueuing: AnyObject {
    func enqueue(_ rawURL: String) throws -> UUID
}

extension DownloadManager: ActivityCenterDownloadEnqueuing {}

struct ActivityCardModel: Identifiable, Equatable {
    let id: ActivityID
    let kind: ActivityKind
    let phase: ActivityPhase
    let title: String
    let subtitle: String
    let progress: Double?
    let countdown: TimeInterval?
    let sourceName: String?
    let start: Date?
    let bytesReceived: Int64?
    let totalBytes: Int64?
    let actions: [ActivityAction]
    let isMasked: Bool
}

struct ActivityDiagnosticModel: Identifiable, Equatable {
    let id: String
    let message: String
}

enum ActivityCenterViewModelError: LocalizedError, Equatable {
    case invalidTimerDuration
    case invalidDownloadURL
    case downloadStartFailed
    case timerStartFailed

    var errorDescription: String? {
        switch self {
        case .invalidTimerDuration:
            return "Укажите длительность таймера"
        case .invalidDownloadURL:
            return "Вставьте ссылку HTTP или HTTPS"
        case .downloadStartFailed:
            return "Не удалось начать загрузку"
        case .timerStartFailed:
            return "Не удалось создать таймер"
        }
    }
}

@MainActor
enum ActivityCenterPresentationMapper {
    static func cards(
        from snapshots: [ActivitySnapshot],
        timers: ActivityCenterTiming,
        privacy: PrivacyMode
    ) -> [ActivityCardModel] {
        ActivityRanking.allSorted(snapshots).map { card(from: $0, timers: timers, privacy: privacy) }
    }

    static func card(
        from snapshot: ActivitySnapshot,
        timers: ActivityCenterTiming,
        privacy: PrivacyMode
    ) -> ActivityCardModel {
        let isMasked = snapshot.containsSensitiveText
            && privacy.hides(.activities, privacyKey(for: snapshot.id))
        let countdown = timerRemaining(for: snapshot, timers: timers)
        let details = cardDetails(from: snapshot, isMasked: isMasked)

        return ActivityCardModel(
            id: snapshot.id,
            kind: snapshot.kind,
            phase: snapshot.phase,
            title: isMasked ? localized("Hidden Activity") : snapshot.title,
            subtitle: isMasked ? localized("Hidden Activity") : snapshot.subtitle,
            progress: snapshot.progress,
            countdown: countdown,
            sourceName: details.sourceName,
            start: snapshot.kind == .meeting ? snapshot.deadline : nil,
            bytesReceived: details.bytesReceived,
            totalBytes: details.totalBytes,
            actions: snapshot.availableActions.sorted { $0.rawValue < $1.rawValue },
            isMasked: isMasked
        )
    }

    static func privacyKey(for id: ActivityID) -> String {
        let sourceLength = id.source.lengthOfBytes(using: .utf8)
        return "activity:\(sourceLength):\(id.source)\(id.local)"
    }

    private static func timerRemaining(
        for snapshot: ActivitySnapshot,
        timers: ActivityCenterTiming
    ) -> TimeInterval? {
        guard snapshot.kind == .timer,
              let id = UUID(uuidString: snapshot.id.local) else {
            return nil
        }
        return timers.remaining(for: id)
    }

    private static func cardDetails(
        from snapshot: ActivitySnapshot,
        isMasked: Bool
    ) -> (sourceName: String?, bytesReceived: Int64?, totalBytes: Int64?) {
        switch (snapshot.kind, snapshot.presentationDetails) {
        case let (.media, .media(sourceName)):
            return (isMasked ? nil : sourceName, nil, nil)
        case let (.download, .download(bytesReceived, totalBytes)):
            return (nil, bytesReceived, totalBytes)
        default:
            return (nil, nil, nil)
        }
    }
}

@MainActor
final class ActivityCenterViewModel: ObservableObject {
    @Published private(set) var cards: [ActivityCardModel] = []
    @Published private(set) var diagnostics: [ActivityDiagnosticModel] = []
    @Published var timerComposerPresented = false
    @Published var downloadComposerPresented = false
    @Published var downloadURL = ""
    @Published private(set) var scrollTarget: ActivityID?
    @Published private(set) var transientError: String?

    private let coordinator: ActivityCenterCoordinating
    private let timers: ActivityCenterTiming
    private let downloads: ActivityCenterDownloadEnqueuing
    private let privacy: PrivacyMode
    private var isPaneVisible = false
    private var isCompactTimerVisible = false
    private var isCountdownVisible = false
    private var viewedTerminalDownloadIDs = Set<ActivityID>()
    private var cancellables = Set<AnyCancellable>()

    init(
        coordinator: ActivityCenterCoordinating,
        timers: ActivityCenterTiming,
        downloads: ActivityCenterDownloadEnqueuing,
        privacy: PrivacyMode
    ) {
        self.coordinator = coordinator
        self.timers = timers
        self.downloads = downloads
        self.privacy = privacy

        coordinator.displayStatePublisher
            .sink { [weak self] state in self?.receiveDisplayState(state) }
            .store(in: &cancellables)
        timers.countdownRevisionPublisher
            .sink { [weak self] _ in self?.rebuildPresentation() }
            .store(in: &cancellables)
        privacy.$sections
            .sink { [weak self] _ in self?.schedulePresentationRebuild() }
            .store(in: &cancellables)
        privacy.$revealed
            .sink { [weak self] _ in self?.schedulePresentationRebuild() }
            .store(in: &cancellables)

        receiveDisplayState(coordinator.displayState)
    }

    func perform(_ action: ActivityAction, on id: ActivityID) {
        coordinator.perform(action, activityID: id)
    }

    /// Терминальные загрузки остаются карточками до явного решения человека.
    /// Групповая очистка использует те же действия источников, что и кнопки на
    /// карточках: завершённые записи удаляются, а ошибки переводятся в
    /// отменённое состояние с их обычной надёжной очисткой.
    var canClearDownloadHistory: Bool {
        cards.contains { card in
            card.kind == .download && (card.phase == .completed || card.phase == .failed)
        }
    }

    func clearDownloadHistory() {
        let terminalActions = cards.compactMap { card -> (ActivityAction, ActivityID)? in
            guard card.kind == .download else { return nil }
            switch card.phase {
            case .completed:
                return card.actions.contains(.dismiss) ? (.dismiss, card.id) : nil
            case .failed:
                return card.actions.contains(.cancel) ? (.cancel, card.id) : nil
            default:
                return nil
            }
        }
        for (action, id) in terminalActions {
            coordinator.perform(action, activityID: id)
        }
    }

    func createTimer(name: String, duration: TimeInterval) throws {
        guard duration.isFinite, (1 ... 359_999).contains(duration) else {
            throw publish(.invalidTimerDuration)
        }

        do {
            _ = try timers.create(name: name, duration: duration)
            transientError = nil
        } catch {
            throw publish(.timerStartFailed)
        }
    }

    func enqueueDownload() throws {
        try enqueueDownload(rawURL: downloadURL)
    }

    func enqueueDownload(url: URL) throws {
        try enqueueDownload(rawURL: url.absoluteString)
    }

    /// Opens the URL composer without requesting focus by itself. The panel
    /// owns keyboard policy; this keeps a pointer hover from stealing it.
    func presentDownloadComposer(prefilling url: URL? = nil) {
        if let url {
            downloadURL = url.absoluteString
        }
        downloadComposerPresented = true
    }

    /// Задаёт только точную цель прокрутки/фокуса; файловые действия идут через `perform`.
    func reveal(_ id: ActivityID) {
        scrollTarget = id
    }

    func clearScrollTarget() {
        scrollTarget = nil
    }

    func toggleMasking(for id: ActivityID) {
        privacy.toggle(ActivityCenterPresentationMapper.privacyKey(for: id))
        rebuildPresentation()
    }

    func setVisible(_ isVisible: Bool) {
        guard isPaneVisible != isVisible else { return }
        isPaneVisible = isVisible
        updateCountdownVisibility()
        if isVisible {
            markVisibleTerminalDownloads(in: coordinator.displayState)
        }
    }

    func setCompactTimerVisible(_ isVisible: Bool) {
        guard isCompactTimerVisible != isVisible else { return }
        isCompactTimerVisible = isVisible
        updateCountdownVisibility()
    }

    private func enqueueDownload(rawURL: String) throws {
        do {
            _ = try DownloadRequestParser.parse(rawURL)
        } catch {
            throw publish(.invalidDownloadURL)
        }

        do {
            _ = try downloads.enqueue(rawURL)
            downloadURL = ""
            transientError = nil
        } catch {
            throw publish(.downloadStartFailed)
        }
    }

    private func publish(_ error: ActivityCenterViewModelError) -> ActivityCenterViewModelError {
        transientError = error.localizedDescription
        return error
    }

    private func receiveDisplayState(_ state: ActivityDisplayState) {
        rebuildPresentation(using: state)
        if isPaneVisible {
            markVisibleTerminalDownloads(in: state)
        }
    }

    private func rebuildPresentation(using state: ActivityDisplayState? = nil) {
        let state = state ?? coordinator.displayState
        cards = ActivityCenterPresentationMapper.cards(
            from: state.allActivities,
            timers: timers,
            privacy: privacy
        )
        diagnostics = state.diagnostics
            .compactMap { sourceID, health -> ActivityDiagnosticModel? in
                guard case let .unavailable(message) = health else { return nil }
                return ActivityDiagnosticModel(id: sourceID, message: message)
            }
            .sorted { $0.id < $1.id }
    }

    private func schedulePresentationRebuild() {
        DispatchQueue.main.async { [weak self] in
            self?.rebuildPresentation()
        }
    }

    private func updateCountdownVisibility() {
        let visible = isPaneVisible || isCompactTimerVisible
        guard visible != isCountdownVisible else { return }
        isCountdownVisible = visible
        timers.setCountdownVisible(visible)
    }

    private func markVisibleTerminalDownloads(in state: ActivityDisplayState) {
        let terminalDownloads = Set(state.allActivities.lazy.filter {
            $0.kind == .download && ($0.phase == .completed || $0.phase == .failed)
        }.map(\.id))
        viewedTerminalDownloadIDs.formIntersection(terminalDownloads)
        let unseenIDs = terminalDownloads.subtracting(viewedTerminalDownloadIDs).sorted()
        viewedTerminalDownloadIDs.formUnion(unseenIDs)

        for id in unseenIDs {
            coordinator.markViewed(id)
        }
    }
}
