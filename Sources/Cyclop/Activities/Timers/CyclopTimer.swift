import Foundation

enum TimerPhase: String, Codable, Equatable {
    case running, paused, completed, cancelled
}

struct CyclopTimer: Identifiable, Codable, Equatable {
    let id: UUID
    var name: String
    let originalDuration: TimeInterval
    var phase: TimerPhase
    var endsAt: Date?
    var pausedRemaining: TimeInterval?
    var completedAt: Date?
    var completionSoundPlayed: Bool

    func remaining(at now: Date) -> TimeInterval {
        switch phase {
        case .running:
            return max(0, endsAt?.timeIntervalSince(now) ?? 0)
        case .paused:
            return max(0, pausedRemaining ?? 0)
        case .completed, .cancelled:
            return 0
        }
    }
}
