import Combine
import Foundation

struct ActivityDisplayState: Equatable {
    var allActivities: [ActivitySnapshot]
    var primary: ActivitySnapshot?
    var indicators: [ActivityIndicator]
    var hiddenIndicatorCount: Int
    var attention: AttentionEvent?
    var diagnostics: [String: ActivitySourceHealth]
}

@MainActor
final class ActivityCoordinator: ObservableObject {
    @Published private(set) var displayState: ActivityDisplayState

    private let sourceOrder: [String]
    private let sourcesByID: [String: ActivitySource]
    private let attentionLedger: ActivityAttentionLedger
    private let clock: ActivityClock

    private var sourceStates: [String: ActivitySourceState]
    private var visibility: Visibility
    private var settledAttentionIDs = Set<ActivityID>()
    private var viewedDownloadIDs = Set<ActivityID>()
    private var activeAttention: AttentionEvent?
    private var pendingAttention: [AttentionEvent] = []
    private var cancellables = Set<AnyCancellable>()

    init(
        sources: [ActivitySource],
        settings: ActivitySettings,
        attentionLedger: ActivityAttentionLedger,
        clock: ActivityClock
    ) {
        var orderedSourceIDs: [String] = []
        var indexedSources: [String: ActivitySource] = [:]
        var initialStates: [String: ActivitySourceState] = [:]

        for source in sources {
            precondition(indexedSources[source.sourceID] == nil, "Activity source IDs must be unique")
            orderedSourceIDs.append(source.sourceID)
            indexedSources[source.sourceID] = source
            initialStates[source.sourceID] = .init(snapshots: [], health: .available)
        }

        sourceOrder = orderedSourceIDs
        sourcesByID = indexedSources
        sourceStates = initialStates
        visibility = Visibility(settings: settings)
        self.attentionLedger = attentionLedger
        self.clock = clock
        displayState = ActivityDisplayState(
            allActivities: [],
            primary: nil,
            indicators: [],
            hiddenIndicatorCount: 0,
            attention: nil,
            diagnostics: Self.diagnostics(sourceOrder: orderedSourceIDs, states: initialStates)
        )

        observe(settings)
        observe(sources)
    }

    func perform(_ action: ActivityAction, activityID: ActivityID) {
        guard let snapshot = allActivities.first(where: { $0.id == activityID }),
              let source = sourcesByID[snapshot.sourceID] else {
            return
        }

        source.perform(action, activityID: activityID)
    }

    func settleAttention(_ event: AttentionEvent) {
        settleTerminalActivity(for: event)

        if activeAttention?.id == event.id {
            activeAttention = nil
        }
        pendingAttention.removeAll { $0.id == event.id }
        promotePendingAttention()
        rebuildDisplayState()
    }

    func markViewed(_ activityID: ActivityID) {
        guard let snapshot = allActivities.first(where: { $0.id == activityID }),
              snapshot.kind == .download,
              snapshot.phase == .failed || snapshot.phase == .completed else {
            return
        }

        viewedDownloadIDs.insert(activityID)
        removeAttention(for: activityID)
        promotePendingAttention()
        rebuildDisplayState()
    }

    private var allActivities: [ActivitySnapshot] {
        sourceOrder.flatMap { sourceStates[$0]?.snapshots ?? [] }
    }

    private func observe(_ sources: [ActivitySource]) {
        for source in sources {
            let sourceID = source.sourceID
            source.statePublisher
                .sink { [weak self] state in
                    MainActor.assumeIsolated {
                        self?.receive(state, from: sourceID)
                    }
                }
                .store(in: &cancellables)
        }
    }

    private func observe(_ settings: ActivitySettings) {
        settings.$isEnabled
            .dropFirst()
            .sink { [weak self] isEnabled in
                MainActor.assumeIsolated {
                    self?.visibility.isEnabled = isEnabled
                    self?.visibilityDidChange()
                }
            }
            .store(in: &cancellables)

        settings.$mediaEnabled
            .dropFirst()
            .sink { [weak self] isEnabled in
                MainActor.assumeIsolated {
                    self?.visibility.mediaEnabled = isEnabled
                    self?.visibilityDidChange()
                }
            }
            .store(in: &cancellables)

        settings.$meetingsEnabled
            .dropFirst()
            .sink { [weak self] isEnabled in
                MainActor.assumeIsolated {
                    self?.visibility.meetingsEnabled = isEnabled
                    self?.visibilityDidChange()
                }
            }
            .store(in: &cancellables)

        settings.$timersEnabled
            .dropFirst()
            .sink { [weak self] isEnabled in
                MainActor.assumeIsolated {
                    self?.visibility.timersEnabled = isEnabled
                    self?.visibilityDidChange()
                }
            }
            .store(in: &cancellables)

        settings.$downloadsEnabled
            .dropFirst()
            .sink { [weak self] isEnabled in
                MainActor.assumeIsolated {
                    self?.visibility.downloadsEnabled = isEnabled
                    self?.visibilityDidChange()
                }
            }
            .store(in: &cancellables)
    }

    private func receive(_ state: ActivitySourceState, from sourceID: String) {
        let previousActivities = allActivities
        sourceStates[sourceID] = state
        let currentActivities = allActivities

        pruneTerminalMarks(using: currentActivities)
        reconcileAttention(using: currentActivities)
        enqueueNewAttention(previous: previousActivities, current: currentActivities)
        promotePendingAttention()
        rebuildDisplayState(using: currentActivities)
    }

    private func visibilityDidChange() {
        settleAttentionHiddenByVisibility()
        reconcileAttention(using: allActivities)
        promotePendingAttention()
        rebuildDisplayState()
    }

    private func settleAttentionHiddenByVisibility() {
        var events = pendingAttention
        if let activeAttention {
            events.insert(activeAttention, at: 0)
        }

        for event in events {
            guard let snapshot = allActivities.first(where: { $0.id == event.activityID }),
                  !visibility.isEnabled || !visibility.allows(snapshot.kind) else {
                continue
            }
            settleTerminalActivity(for: event)
        }
    }

    private func enqueueNewAttention(
        previous: [ActivitySnapshot],
        current: [ActivitySnapshot]
    ) {
        guard visibility.isEnabled else { return }

        let rankedCurrent = ActivityRanking.sorted(current.filter {
            visibility.allows($0.kind) && !isViewedDownload($0)
        })
        let events = ActivityAttentionPolicy.events(
            previous: previous,
            current: rankedCurrent,
            now: clock.now
        )

        for event in events {
            guard activeAttention?.id != event.id,
                  !pendingAttention.contains(where: { $0.id == event.id }) else {
                continue
            }
            pendingAttention.append(event)
        }
    }

    private func pruneTerminalMarks(using activities: [ActivitySnapshot]) {
        let terminalIDs = Set(activities.lazy.filter {
            $0.phase == .completed || $0.phase == .failed
        }.map(\.id))
        settledAttentionIDs.formIntersection(terminalIDs)
        viewedDownloadIDs.formIntersection(terminalIDs)
    }

    private func reconcileAttention(using activities: [ActivitySnapshot]) {
        let snapshotsByID = Dictionary(activities.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        if let activeAttention,
           !isAttentionRelevant(activeAttention, snapshotsByID: snapshotsByID) {
            self.activeAttention = nil
        }
        pendingAttention.removeAll {
            !isAttentionRelevant($0, snapshotsByID: snapshotsByID)
        }
    }

    private func isAttentionRelevant(
        _ event: AttentionEvent,
        snapshotsByID: [ActivityID: ActivitySnapshot]
    ) -> Bool {
        guard visibility.isEnabled,
              let snapshot = snapshotsByID[event.activityID],
              visibility.allows(snapshot.kind),
              !isViewedDownload(snapshot) else {
            return false
        }

        switch event.kind {
        case .timerCompleted:
            return snapshot.kind == .timer && snapshot.phase == .completed
        case .downloadFailed:
            return snapshot.kind == .download && snapshot.phase == .failed
        case .downloadCompleted:
            return snapshot.kind == .download && snapshot.phase == .completed
        case .meetingThreshold, .meetingOneMinute, .meetingStarted:
            return snapshot.kind == .meeting
        }
    }

    private func settleTerminalActivity(for event: AttentionEvent) {
        switch event.kind {
        case .timerCompleted, .downloadFailed:
            guard let snapshot = allActivities.first(where: { $0.id == event.activityID }),
                  ActivityAttentionPolicy.events(
                    previous: [],
                    current: [snapshot],
                    now: clock.now
                  ).first == event else {
                return
            }
            settledAttentionIDs.insert(event.activityID)
        case .meetingThreshold, .meetingOneMinute, .meetingStarted, .downloadCompleted:
            break
        }
    }

    private func removeAttention(for activityID: ActivityID) {
        if activeAttention?.activityID == activityID {
            activeAttention = nil
        }
        pendingAttention.removeAll { $0.activityID == activityID }
    }

    private func promotePendingAttention() {
        guard activeAttention == nil else { return }

        while !pendingAttention.isEmpty {
            let event = pendingAttention.removeFirst()
            if attentionLedger.claim(event) {
                activeAttention = event
                return
            }
            settleTerminalActivity(for: event)
        }
    }

    private func rebuildDisplayState(using activities: [ActivitySnapshot]? = nil) {
        let mergedActivities = activities ?? allActivities
        let diagnostics = Self.diagnostics(sourceOrder: sourceOrder, states: sourceStates)

        guard visibility.isEnabled else {
            displayState = ActivityDisplayState(
                allActivities: mergedActivities,
                primary: nil,
                indicators: [],
                hiddenIndicatorCount: 0,
                attention: nil,
                diagnostics: diagnostics
            )
            return
        }

        let rankedActivities = ActivityRanking.sorted(mergedActivities.filter {
            visibility.allows($0.kind) && !isViewedDownload($0)
        })
        let primary = rankedActivities.first(where: { !isSettledTerminal($0) })
        let secondary = rankedActivities.filter { $0.id != primary?.id }
        let indicatorSet = ActivityRanking.indicators(afterPrimary: secondary)

        displayState = ActivityDisplayState(
            allActivities: mergedActivities,
            primary: primary,
            indicators: indicatorSet.items,
            hiddenIndicatorCount: indicatorSet.hiddenCount,
            attention: activeAttention,
            diagnostics: diagnostics
        )
    }

    private func isSettledTerminal(_ snapshot: ActivitySnapshot) -> Bool {
        guard settledAttentionIDs.contains(snapshot.id) else { return false }
        return (snapshot.kind == .timer && snapshot.phase == .completed)
            || (snapshot.kind == .download && snapshot.phase == .failed)
    }

    private func isViewedDownload(_ snapshot: ActivitySnapshot) -> Bool {
        guard viewedDownloadIDs.contains(snapshot.id), snapshot.kind == .download else {
            return false
        }
        return snapshot.phase == .failed || snapshot.phase == .completed
    }

    private static func diagnostics(
        sourceOrder: [String],
        states: [String: ActivitySourceState]
    ) -> [String: ActivitySourceHealth] {
        sourceOrder.reduce(into: [:]) { result, sourceID in
            if let health = states[sourceID]?.health {
                result[sourceID] = health
            }
        }
    }
}

private struct Visibility {
    var isEnabled: Bool
    var mediaEnabled: Bool
    var meetingsEnabled: Bool
    var timersEnabled: Bool
    var downloadsEnabled: Bool

    @MainActor
    init(settings: ActivitySettings) {
        isEnabled = settings.isEnabled
        mediaEnabled = settings.mediaEnabled
        meetingsEnabled = settings.meetingsEnabled
        timersEnabled = settings.timersEnabled
        downloadsEnabled = settings.downloadsEnabled
    }

    func allows(_ kind: ActivityKind) -> Bool {
        switch kind {
        case .media: return mediaEnabled
        case .meeting: return meetingsEnabled
        case .timer: return timersEnabled
        case .download: return downloadsEnabled
        }
    }
}
