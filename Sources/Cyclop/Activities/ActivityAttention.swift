import Foundation

struct AttentionEvent: Equatable, Identifiable, Sendable {
    enum Kind: Equatable, Sendable {
        case meetingThreshold
        case meetingOneMinute
        case meetingStarted
        case timerCompleted
        case downloadFailed
        case downloadCompleted

        var duration: TimeInterval {
            switch self {
            case .meetingThreshold, .meetingOneMinute, .meetingStarted, .downloadCompleted:
                return 5
            case .timerCompleted:
                return 10
            case .downloadFailed:
                return 8
            }
        }
    }

    let id: String
    let activityID: ActivityID
    let kind: Kind
    let occurredAt: Date

    var duration: TimeInterval { kind.duration }
}

enum ActivityAttentionPolicy {
    static func events(
        previous: [ActivitySnapshot],
        current: [ActivitySnapshot],
        now _: Date
    ) -> [AttentionEvent] {
        let previousByID = previous.reduce(into: [ActivityID: ActivitySnapshot]()) {
            $0[$1.id] = $1
        }

        return current.compactMap { snapshot in
            event(previous: previousByID[snapshot.id], current: snapshot)
        }
    }

    private static func event(
        previous: ActivitySnapshot?,
        current: ActivitySnapshot
    ) -> AttentionEvent? {
        guard let occurredAt = current.occurredAt else { return nil }

        if current.kind == .meeting {
            guard previous?.occurredAt != occurredAt else { return nil }
            return meetingEvent(for: current, occurredAt: occurredAt)
        }

        guard previous?.phase != current.phase else { return nil }

        let kind: AttentionEvent.Kind
        switch (current.kind, current.phase) {
        case (.timer, .completed):
            kind = .timerCompleted
        case (.download, .failed):
            kind = .downloadFailed
        case (.download, .completed):
            kind = .downloadCompleted
        default:
            return nil
        }

        return AttentionEvent(
            id: terminalEventID(for: current, occurredAt: occurredAt),
            activityID: current.id,
            kind: kind,
            occurredAt: occurredAt
        )
    }

    private static func meetingEvent(
        for snapshot: ActivitySnapshot,
        occurredAt: Date
    ) -> AttentionEvent {
        let kind: AttentionEvent.Kind
        let milestone: String

        if snapshot.deadline == occurredAt {
            kind = .meetingStarted
            milestone = "started"
        } else if snapshot.deadline?.timeIntervalSince(occurredAt) == 60 {
            kind = .meetingOneMinute
            milestone = "oneMinute"
        } else {
            kind = .meetingThreshold
            milestone = "threshold"
        }

        return AttentionEvent(
            id: "meeting:\(snapshot.id.local):\(milestone):\(epochComponent(occurredAt))",
            activityID: snapshot.id,
            kind: kind,
            occurredAt: occurredAt
        )
    }

    private static func terminalEventID(
        for snapshot: ActivitySnapshot,
        occurredAt: Date
    ) -> String {
        "\(snapshot.kind.rawValue):\(snapshot.id.source):\(snapshot.id.local):\(snapshot.phase.rawValue):\(epochComponent(occurredAt))"
    }

    private static func epochComponent(_ date: Date) -> String {
        let timestamp = date.timeIntervalSince1970
        let wholeSeconds = timestamp.rounded(.towardZero)
        if timestamp == wholeSeconds {
            return String(Int64(wholeSeconds))
        }
        return String(timestamp)
    }
}

final class ActivityAttentionLedger {
    private static let storageKey = "activities.attentionLedger"
    private static let retentionInterval: TimeInterval = 86_400

    private let defaults: UserDefaults
    private let clock: ActivityClock

    init(defaults: UserDefaults, clock: ActivityClock) {
        self.defaults = defaults
        self.clock = clock
    }

    func claim(_ event: AttentionEvent) -> Bool {
        let claimedAt = clock.now.timeIntervalSince1970
        let cutoff = claimedAt - Self.retentionInterval
        var claims = storedClaims().filter { $0.value >= cutoff }

        guard claims[event.id] == nil else {
            defaults.set(claims, forKey: Self.storageKey)
            return false
        }

        claims[event.id] = claimedAt
        defaults.set(claims, forKey: Self.storageKey)
        return true
    }

    private func storedClaims() -> [String: TimeInterval] {
        guard let stored = defaults.dictionary(forKey: Self.storageKey) else { return [:] }

        return stored.reduce(into: [String: TimeInterval]()) { claims, entry in
            if let timestamp = entry.value as? NSNumber {
                claims[entry.key] = timestamp.doubleValue
            }
        }
    }
}
