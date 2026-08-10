import Foundation

struct ActivityID: Hashable, Codable, Comparable, Sendable {
    let source: String
    let local: String

    static func < (lhs: Self, rhs: Self) -> Bool {
        (lhs.source, lhs.local) < (rhs.source, rhs.local)
    }
}

enum ActivityKind: String, Codable, CaseIterable, Sendable {
    case media, meeting, timer, download
}

enum ActivityPhase: String, Codable, Sendable {
    case ambient, active, attention, completed, failed, paused
}

enum ActivityAction: String, Codable, Hashable, CaseIterable, Sendable {
    case play, pause, previous, next, join, resume, cancel, dismiss, retry, restart, open, reveal
}

struct ActivitySnapshot: Identifiable, Equatable, Sendable {
    let id: ActivityID
    let sourceID: String
    let kind: ActivityKind
    var phase: ActivityPhase
    var title: String
    var subtitle: String
    var progress: Double?
    var deadline: Date?
    var occurredAt: Date?
    var availableActions: Set<ActivityAction>
    var containsSensitiveText: Bool
}
