import Combine
import Foundation

enum NotchPresentationMode: Equatable {
    case idle
    case compact
    case attention
    case expanded
}

struct NotchPresentationState: Equatable {
    var mode: NotchPresentationMode
    var display: ActivityDisplayState
}

@MainActor
final class NotchPresentationModel: ObservableObject {
    @Published private(set) var state: NotchPresentationState
    private(set) var requestedTab: String?

    private let clock: ActivityClock
    private let scheduler: ActivityScheduling
    private let onActivityOpen: (ActivityID) -> Void
    private let onAttentionExpired: (AttentionEvent) -> Void

    private var lastUserTab: String
    private var scheduledAttention: AttentionEvent?
    private var suppressedAttention: AttentionEvent?
    private var attentionCancellation: ActivityCancellation?
    private var generation = 0

    init(
        clock: ActivityClock,
        scheduler: ActivityScheduling,
        initialUserTab: String = "media",
        onActivityOpen: @escaping (ActivityID) -> Void = { _ in },
        onAttentionExpired: @escaping (AttentionEvent) -> Void
    ) {
        self.clock = clock
        self.scheduler = scheduler
        self.lastUserTab = initialUserTab
        self.onActivityOpen = onActivityOpen
        self.onAttentionExpired = onAttentionExpired
        state = NotchPresentationState(mode: .idle, display: Self.emptyDisplay)
    }

    func receive(display: ActivityDisplayState) {
        let isExpanded = state.mode == .expanded
        state.display = display

        if let attention = display.attention {
            if scheduledAttention != attention {
                schedule(attention)
            }
            if !isExpanded {
                state.mode = suppressedAttention == attention
                    ? collapsedMode(for: display)
                    : .attention
            }
        } else {
            suppressedAttention = nil
            cancelAttentionSchedule()
            if !isExpanded {
                state.mode = collapsedMode(for: display)
            }
        }
    }

    func recordUserTab(_ tab: String) {
        lastUserTab = tab
        requestedTab = nil
    }

    func openFromPointer(overActiveIsland: Bool) {
        guard state.mode != .expanded else { return }

        requestedTab = overActiveIsland ? "activities" : lastUserTab
        state.mode = .expanded
    }

    func open(activityID: ActivityID) {
        requestedTab = "activities"
        state.mode = .expanded
        onActivityOpen(activityID)
    }

    func closeFromPointer() {
        guard state.mode == .expanded else { return }

        requestedTab = nil
        suppressedAttention = state.display.attention
        state.mode = collapsedMode(for: state.display)
    }

    private func schedule(_ event: AttentionEvent) {
        attentionCancellation?.cancel()
        suppressedAttention = nil
        generation &+= 1
        let scheduledGeneration = generation
        scheduledAttention = event
        attentionCancellation = scheduler.schedule(
            at: clock.now.addingTimeInterval(event.duration)
        ) { [weak self] in
            self?.expire(event, generation: scheduledGeneration)
        }
    }

    private func cancelAttentionSchedule() {
        guard scheduledAttention != nil || attentionCancellation != nil else { return }

        attentionCancellation?.cancel()
        attentionCancellation = nil
        scheduledAttention = nil
        generation &+= 1
    }

    private func expire(_ event: AttentionEvent, generation scheduledGeneration: Int) {
        guard generation == scheduledGeneration, scheduledAttention == event else { return }

        attentionCancellation = nil
        scheduledAttention = nil
        generation &+= 1
        let expirationGeneration = generation

        onAttentionExpired(event)

        guard generation == expirationGeneration, state.mode != .expanded else { return }
        state.mode = collapsedMode(for: state.display)
    }

    private func collapsedMode(for display: ActivityDisplayState) -> NotchPresentationMode {
        let hasCompactContent = display.primary != nil
            || !display.indicators.isEmpty
            || display.hiddenIndicatorCount > 0
        return hasCompactContent ? .compact : .idle
    }

    private static var emptyDisplay: ActivityDisplayState {
        ActivityDisplayState(
            allActivities: [],
            primary: nil,
            indicators: [],
            hiddenIndicatorCount: 0,
            attention: nil,
            diagnostics: [:]
        )
    }
}
