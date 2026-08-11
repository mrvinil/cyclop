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
        let now = clock.now
        if try reconcileTimers(now: now, claimPendingSounds: true) == false {
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

        let now = clock.now
        let id = UUID()
        let normalizedName = name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "Таймер"
            : name
        let record = CyclopTimer(
            id: id,
            name: normalizedName,
            originalDuration: duration,
            phase: .running,
            endsAt: now.addingTimeInterval(duration),
            pausedRemaining: nil,
            completedAt: nil,
            completionSoundPlayed: false
        )
        _ = try reconcileTimers(now: now, claimPendingSounds: false) { updated in
            updated.append(record)
        }
        return id
    }

    func pause(_ id: UUID) throws {
        let index = try timerIndex(id)
        guard timers[index].phase == .running else {
            throw TimerStoreError.invalidTransition
        }

        let now = clock.now
        _ = try reconcileTimers(now: now, claimPendingSounds: false) { updated in
            let updatedIndex = try Self.timerIndex(id, in: updated)
            guard updated[updatedIndex].phase == .running else {
                return
            }

            let remaining = updated[updatedIndex].remaining(at: now)
            updated[updatedIndex].phase = .paused
            updated[updatedIndex].endsAt = nil
            updated[updatedIndex].pausedRemaining = remaining
            updated[updatedIndex].completedAt = nil
        }
    }

    func resume(_ id: UUID) throws {
        let index = try timerIndex(id)
        guard timers[index].phase == .paused else {
            throw TimerStoreError.invalidTransition
        }

        let now = clock.now
        _ = try reconcileTimers(now: now, claimPendingSounds: false) { updated in
            let updatedIndex = try Self.timerIndex(id, in: updated)
            let remaining = updated[updatedIndex].remaining(at: now)
            if remaining <= 0 {
                updated[updatedIndex].phase = .completed
                updated[updatedIndex].endsAt = nil
                updated[updatedIndex].pausedRemaining = 0
                updated[updatedIndex].completedAt = now
            } else {
                updated[updatedIndex].phase = .running
                updated[updatedIndex].endsAt = now.addingTimeInterval(remaining)
                updated[updatedIndex].pausedRemaining = nil
                updated[updatedIndex].completedAt = nil
            }
        }
    }

    func cancel(_ id: UUID) throws {
        let index = try timerIndex(id)
        guard timers[index].phase == .running || timers[index].phase == .paused else {
            throw TimerStoreError.invalidTransition
        }

        let now = clock.now
        _ = try reconcileTimers(now: now, claimPendingSounds: false) { updated in
            let updatedIndex = try Self.timerIndex(id, in: updated)
            guard updated[updatedIndex].phase != .completed else {
                return
            }
            updated.remove(at: updatedIndex)
        }
    }

    func dismiss(_ id: UUID) throws {
        let index = try timerIndex(id)
        guard timers[index].phase == .completed else {
            throw TimerStoreError.invalidTransition
        }

        let now = clock.now
        _ = try reconcileTimers(now: now, claimPendingSounds: false) { updated in
            let updatedIndex = try Self.timerIndex(id, in: updated)
            updated.remove(at: updatedIndex)
        }
    }

    func restart(_ id: UUID) throws {
        let index = try timerIndex(id)
        guard timers[index].phase == .completed else {
            throw TimerStoreError.invalidTransition
        }

        let now = clock.now
        _ = try reconcileTimers(now: now, claimPendingSounds: false) { updated in
            let updatedIndex = try Self.timerIndex(id, in: updated)
            updated[updatedIndex].phase = .running
            updated[updatedIndex].endsAt = now.addingTimeInterval(
                updated[updatedIndex].originalDuration
            )
            updated[updatedIndex].pausedRemaining = nil
            updated[updatedIndex].completedAt = nil
            updated[updatedIndex].completionSoundPlayed = false
        }
    }

    func timer(_ id: UUID) -> CyclopTimer? {
        timers.first { $0.id == id }
    }

    func remaining(for id: UUID) -> TimeInterval? {
        timer(id)?.remaining(at: clock.now)
    }

    private func timerIndex(_ id: UUID) throws -> Int {
        try Self.timerIndex(id, in: timers)
    }

    private static func timerIndex(_ id: UUID, in timers: [CyclopTimer]) throws -> Int {
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
            let now = clock.now
            if try reconcileTimers(now: now, claimPendingSounds: false) == false {
                scheduleNextWake()
            }
        } catch {
            // persistAndPublish уже перевёл health в недоступное состояние.
            // После неуспешного deadline-write новый wake намеренно не создаётся.
        }
    }

    private func reconcileTimers(
        now: Date,
        claimPendingSounds: Bool,
        transition: (inout [CyclopTimer]) throws -> Void = { _ in }
    ) throws -> Bool {
        let previouslyCompletedIDs = Set(
            timers.lazy.filter { $0.phase == .completed }.map(\.id)
        )
        var updated = timers.filter { $0.phase != .cancelled }

        for index in updated.indices {
            if updated[index].phase == .running,
               let deadline = updated[index].endsAt,
               deadline <= now {
                updated[index].phase = .completed
                updated[index].endsAt = nil
                updated[index].pausedRemaining = 0
                updated[index].completedAt = deadline
            }
        }

        try transition(&updated)

        var soundCount = 0
        for index in updated.indices {
            let completedNow = updated[index].phase == .completed
                && !previouslyCompletedIDs.contains(updated[index].id)

            if soundPlayer != nil,
               updated[index].phase == .completed,
               updated[index].completionSoundPlayed == false,
               claimPendingSounds || completedNow {
                updated[index].completionSoundPlayed = true
                soundCount += 1
            }
        }

        if updated != timers {
            try persistAndPublish(updated)
            for _ in 0 ..< soundCount {
                soundPlayer?.playCompletion()
            }
            return true
        }
        return false
    }
}
