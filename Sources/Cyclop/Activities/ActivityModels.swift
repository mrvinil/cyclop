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

enum ActivitySnapshotPresentationDetails: Equatable, Sendable {
    case media(sourceName: String?)
    case download(bytesReceived: Int64, totalBytes: Int64?)
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
    var presentationDetails: ActivitySnapshotPresentationDetails?

    init(
        id: ActivityID,
        sourceID: String,
        kind: ActivityKind,
        phase: ActivityPhase,
        title: String,
        subtitle: String,
        progress: Double?,
        deadline: Date?,
        occurredAt: Date?,
        availableActions: Set<ActivityAction>,
        containsSensitiveText: Bool,
        presentationDetails: ActivitySnapshotPresentationDetails? = nil
    ) {
        self.id = id
        self.sourceID = sourceID
        self.kind = kind
        self.phase = phase
        self.title = title
        self.subtitle = subtitle
        self.progress = progress
        self.deadline = deadline
        self.occurredAt = occurredAt
        self.availableActions = availableActions
        self.containsSensitiveText = containsSensitiveText
        self.presentationDetails = presentationDetails
    }
}
