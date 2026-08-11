import Combine
import Foundation
import OSLog

@MainActor
final class TimerActivitySource: ActivitySource {
    let sourceID = "timers"

    var statePublisher: AnyPublisher<ActivitySourceState, Never> {
        state.eraseToAnyPublisher()
    }

    private let store: TimerStore
    private let state: CurrentValueSubject<ActivitySourceState, Never>
    private let logger = Logger(subsystem: "Cyclop", category: "Таймеры")
    private var cancellables = Set<AnyCancellable>()

    init(store: TimerStore) {
        self.store = store
        state = CurrentValueSubject(Self.makeState(timers: store.timers, health: store.health))

        store.$timers
            .sink { [weak self] timers in
                MainActor.assumeIsolated {
                    self?.receive(timers: timers)
                }
            }
            .store(in: &cancellables)

        store.$health
            .sink { [weak self] health in
                MainActor.assumeIsolated {
                    self?.receive(health: health)
                }
            }
            .store(in: &cancellables)
    }

    func perform(_ action: ActivityAction, activityID: ActivityID) {
        guard activityID.source == sourceID else {
            logger.notice("Источник таймеров проигнорировал действие для чужой активности")
            return
        }
        guard let timerID = UUID(uuidString: activityID.local) else {
            logger.notice("Источник таймеров проигнорировал действие с некорректным идентификатором")
            return
        }

        do {
            switch action {
            case .pause:
                try store.pause(timerID)
            case .resume:
                try store.resume(timerID)
            case .cancel:
                try store.cancel(timerID)
            case .dismiss:
                try store.dismiss(timerID)
            case .restart:
                try store.restart(timerID)
            default:
                logger.notice("Источник таймеров проигнорировал неподдерживаемое действие")
                return
            }
        } catch {
            logger.error("Не удалось выполнить действие с таймером")
            publishActionFailure()
        }
    }

    private func publish(timers: [CyclopTimer], health: ActivitySourceHealth) {
        let updated = Self.makeState(timers: timers, health: health)
        if state.value != updated {
            state.send(updated)
        }
    }

    private func receive(timers: [CyclopTimer]) {
        guard store.health == .available else { return }
        publish(timers: timers, health: .available)
    }

    private func receive(health: ActivitySourceHealth) {
        publish(timers: store.timers, health: health)
    }

    private func publishActionFailure() {
        if store.health == .available {
            publish(
                timers: store.timers,
                health: .unavailable(message: "Не удалось выполнить действие с таймером")
            )
        } else {
            publish(timers: store.timers, health: store.health)
        }
    }

    private static func makeState(
        timers: [CyclopTimer],
        health: ActivitySourceHealth
    ) -> ActivitySourceState {
        ActivitySourceState(
            snapshots: timers.compactMap(snapshot),
            health: health
        )
    }

    private static func snapshot(for timer: CyclopTimer) -> ActivitySnapshot? {
        let phase: ActivityPhase
        let deadline: Date?
        let occurredAt: Date?
        let actions: Set<ActivityAction>

        switch timer.phase {
        case .running:
            phase = .active
            deadline = timer.endsAt
            occurredAt = nil
            actions = [.pause, .cancel]
        case .paused:
            phase = .paused
            deadline = nil
            occurredAt = nil
            actions = [.resume, .cancel]
        case .completed:
            phase = .completed
            deadline = nil
            occurredAt = timer.completedAt
            actions = [.dismiss, .restart]
        case .cancelled:
            return nil
        }

        return ActivitySnapshot(
            id: ActivityID(source: "timers", local: timer.id.uuidString),
            sourceID: "timers",
            kind: .timer,
            phase: phase,
            title: timer.name,
            subtitle: "",
            progress: nil,
            deadline: deadline,
            occurredAt: occurredAt,
            availableActions: actions,
            containsSensitiveText: true
        )
    }
}
