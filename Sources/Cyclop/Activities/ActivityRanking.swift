import Foundation

struct ActivityIndicator: Equatable {
    let activityID: ActivityID
    let kind: ActivityKind
    let phase: ActivityPhase
}

struct ActivityIndicatorSet: Equatable {
    let items: [ActivityIndicator]
    let hiddenCount: Int
}

enum ActivityRanking {
    static func rank(_ snapshot: ActivitySnapshot) -> Int {
        switch (snapshot.kind, snapshot.phase) {
        case (.timer, .completed): return 700
        case (.meeting, _): return 600
        case (.download, .failed): return 500
        case (.timer, .active): return 400
        case (.download, .active): return 300
        case (.media, _): return 200
        case (.download, .completed): return 100
        default: return 0
        }
    }

    static func sorted(_ snapshots: [ActivitySnapshot]) -> [ActivitySnapshot] {
        snapshots
            .filter { ($0.phase != .paused || $0.kind == .media) && rank($0) > 0 }
            .sorted(by: isHigherPriority)
    }

    /// Центр активностей показывает и неактивные карточки, поэтому использует тот же
    /// детерминированный порядок без compact-фильтрации.
    static func allSorted(_ snapshots: [ActivitySnapshot]) -> [ActivitySnapshot] {
        snapshots.sorted(by: isHigherPriority)
    }

    static func indicators(afterPrimary snapshots: [ActivitySnapshot]) -> ActivityIndicatorSet {
        let visibleSnapshots = snapshots.count >= 4 ? Array(snapshots.prefix(2)) : snapshots
        let items = visibleSnapshots.map {
            ActivityIndicator(activityID: $0.id, kind: $0.kind, phase: $0.phase)
        }

        return ActivityIndicatorSet(
            items: items,
            hiddenCount: snapshots.count >= 4 ? snapshots.count - 2 : 0
        )
    }

    private static func isHigherPriority(_ lhs: ActivitySnapshot, _ rhs: ActivitySnapshot) -> Bool {
        let lhsRank = rank(lhs)
        let rhsRank = rank(rhs)
        if lhsRank != rhsRank {
            return lhsRank > rhsRank
        }

        if lhs.deadline != rhs.deadline {
            switch (lhs.deadline, rhs.deadline) {
            case let (.some(lhsDeadline), .some(rhsDeadline)):
                return lhsDeadline < rhsDeadline
            case (.some, .none):
                return true
            case (.none, .some):
                return false
            case (.none, .none):
                break
            }
        }

        if lhs.occurredAt != rhs.occurredAt {
            switch (lhs.occurredAt, rhs.occurredAt) {
            case let (.some(lhsOccurredAt), .some(rhsOccurredAt)):
                return lhsOccurredAt > rhsOccurredAt
            case (.some, .none):
                return true
            case (.none, .some):
                return false
            case (.none, .none):
                break
            }
        }

        return lhs.id < rhs.id
    }
}
