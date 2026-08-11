import Combine
import Foundation

enum TimerStoreError: LocalizedError, Equatable {
    case invalidDuration
    case timerNotFound
    case invalidTransition
    case persistenceFailed
}

@MainActor
final class TimerStore: ObservableObject {
    @Published private(set) var timers: [CyclopTimer] = []
    @Published private(set) var health: ActivitySourceHealth = .available
    @Published private(set) var countdownRevision = 0

    private let clock: ActivityClock
    private let scheduler: ActivityScheduling
    private let persistence: TimerPersisting
    private let soundPlayer: TimerSoundPlaying?

    private var isStarted = false
    private var writesAllowed = false
    private var isCountdownVisible = false
    private var scheduledWake: ActivityCancellation?
    private var wakeGeneration: UInt = 0

    init(
        clock: ActivityClock,
        scheduler: ActivityScheduling,
        persistence: TimerPersisting,
        soundPlayer: TimerSoundPlaying? = nil
    ) {
        self.clock = clock
        self.scheduler = scheduler
        self.persistence = persistence
        self.soundPlayer = soundPlayer
    }

    func start() throws {
        let loaded: [CyclopTimer]
        do {
            loaded = try persistence.load()
        } catch {
            writesAllowed = false
            health = .unavailable(message: "Не удалось загрузить таймеры")
            throw TimerStoreError.persistenceFailed
        }

        cancelScheduledWake()
        writesAllowed = true
        isStarted = true
        timers = loaded
        health = .available
        if try reconcileTimers(claimPendingSounds: true) == false {
            scheduleNextWake()
        }
    }

    func stop() {
        isStarted = false
        cancelScheduledWake()
    }

    func setCountdownVisible(_ isVisible: Bool) {
        guard isCountdownVisible != isVisible else { return }

        isCountdownVisible = isVisible
        scheduleNextWake()
    }

    @discardableResult
    func create(name: String, duration: TimeInterval) throws -> UUID {
        guard duration.isFinite, (1 ... 359_999).contains(duration) else {
            throw TimerStoreError.invalidDuration
        }

        let id = UUID()
        let normalizedName = name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "Таймер"
            : name
        let record = CyclopTimer(
            id: id,
            name: normalizedName,
            originalDuration: duration,
            phase: .running,
            endsAt: clock.now.addingTimeInterval(duration),
            pausedRemaining: nil,
            completedAt: nil,
            completionSoundPlayed: false
        )
        try persistAndPublish(timers + [record])
        return id
    }

    func pause(_ id: UUID) throws {
        let index = try timerIndex(id)
        guard timers[index].phase == .running else {
            throw TimerStoreError.invalidTransition
        }

        var updated = timers
        updated[index].phase = .paused
        updated[index].endsAt = nil
        updated[index].pausedRemaining = timers[index].remaining(at: clock.now)
        updated[index].completedAt = nil
        try persistAndPublish(updated)
    }

    func resume(_ id: UUID) throws {
        let index = try timerIndex(id)
        guard timers[index].phase == .paused else {
            throw TimerStoreError.invalidTransition
        }

        var updated = timers
        let remaining = timers[index].remaining(at: clock.now)
        updated[index].phase = .running
        updated[index].endsAt = clock.now.addingTimeInterval(remaining)
        updated[index].pausedRemaining = nil
        updated[index].completedAt = nil
        try persistAndPublish(updated)
    }

    func cancel(_ id: UUID) throws {
        let index = try timerIndex(id)
        guard timers[index].phase == .running || timers[index].phase == .paused else {
            throw TimerStoreError.invalidTransition
        }

        var updated = timers
        updated[index].phase = .cancelled
        updated[index].endsAt = nil
        updated[index].pausedRemaining = 0
        updated[index].completedAt = nil
        try persistAndPublish(updated)
    }

    func dismiss(_ id: UUID) throws {
        let index = try timerIndex(id)
        guard timers[index].phase == .completed || timers[index].phase == .cancelled else {
            throw TimerStoreError.invalidTransition
        }

        var updated = timers
        updated.remove(at: index)
        try persistAndPublish(updated)
    }

    func restart(_ id: UUID) throws {
        let index = try timerIndex(id)
        guard timers[index].phase == .completed || timers[index].phase == .cancelled else {
            throw TimerStoreError.invalidTransition
        }

        var updated = timers
        updated[index].phase = .running
        updated[index].endsAt = clock.now.addingTimeInterval(updated[index].originalDuration)
        updated[index].pausedRemaining = nil
        updated[index].completedAt = nil
        updated[index].completionSoundPlayed = false
        try persistAndPublish(updated)
    }

    func timer(_ id: UUID) -> CyclopTimer? {
        timers.first { $0.id == id }
    }

    func remaining(for id: UUID) -> TimeInterval? {
        timer(id)?.remaining(at: clock.now)
    }

    private func timerIndex(_ id: UUID) throws -> Int {
        guard let index = timers.firstIndex(where: { $0.id == id }) else {
            throw TimerStoreError.timerNotFound
        }
        return index
    }

    private func persistAndPublish(_ updated: [CyclopTimer]) throws {
        guard writesAllowed else {
            throw TimerStoreError.persistenceFailed
        }

        do {
            try persistence.save(updated)
        } catch {
            health = .unavailable(message: "Не удалось сохранить таймеры")
            throw TimerStoreError.persistenceFailed
        }

        timers = updated
        health = .available
        scheduleNextWake()
    }

    private func scheduleNextWake() {
        cancelScheduledWake()
        guard isStarted,
              let deadline = timers.compactMap({ timer in
                  timer.phase == .running ? timer.endsAt : nil
              }).min() else {
            return
        }

        let nextWholeSecond = nextWholeSecond(after: clock.now)
        let isCountdownPulse = isCountdownVisible && nextWholeSecond <= deadline
        let nextWake = isCountdownPulse ? nextWholeSecond : deadline
        let generation = wakeGeneration
        scheduledWake = scheduler.schedule(at: nextWake) { [weak self] in
            self?.handleScheduledWake(
                generation: generation,
                isCountdownPulse: isCountdownPulse
            )
        }
    }

    private func nextWholeSecond(after date: Date) -> Date {
        Date(timeIntervalSinceReferenceDate: date.timeIntervalSinceReferenceDate.rounded(.down) + 1)
    }

    private func cancelScheduledWake() {
        wakeGeneration &+= 1
        scheduledWake?.cancel()
        scheduledWake = nil
    }

    private func handleScheduledWake(generation: UInt, isCountdownPulse: Bool) {
        guard isStarted, generation == wakeGeneration else { return }

        cancelScheduledWake()
        if isCountdownPulse {
            countdownRevision &+= 1
        }
        do {
            if try reconcileTimers(claimPendingSounds: false) == false {
                scheduleNextWake()
            }
        } catch {
            // persistAndPublish уже перевёл health в недоступное состояние.
            // После неуспешного deadline-write новый wake намеренно не создаётся.
        }
    }

    private func reconcileTimers(claimPendingSounds: Bool) throws -> Bool {
        let now = clock.now
        var updated = timers
        var didChange = false
        var soundCount = 0

        for index in updated.indices {
            var completedNow = false
            if updated[index].phase == .running,
               let deadline = updated[index].endsAt,
               deadline <= now {
                updated[index].phase = .completed
                updated[index].endsAt = nil
                updated[index].pausedRemaining = 0
                updated[index].completedAt = deadline
                completedNow = true
                didChange = true
            }

            if soundPlayer != nil,
               updated[index].phase == .completed,
               updated[index].completionSoundPlayed == false,
               claimPendingSounds || completedNow {
                updated[index].completionSoundPlayed = true
                soundCount += 1
                didChange = true
            }
        }

        if didChange {
            try persistAndPublish(updated)
            for _ in 0 ..< soundCount {
                soundPlayer?.playCompletion()
            }
        }
        return didChange
    }
}
