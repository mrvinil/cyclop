import Foundation

struct MeetingActivityInput: Equatable {
    let id: String
    let title: String
    let start: Date
    let end: Date
    let link: URL?
    let provider: String?
}

enum MeetingMilestone: String, Equatable {
    case threshold
    case oneMinute
    case started
}

struct MeetingPresentation: Equatable {
    let isVisible: Bool
    let phase: ActivityPhase
    let milestone: MeetingMilestone?
    let milestoneDate: Date?
    let nextBoundary: Date?
}

struct MeetingActivityPolicy {
    private let leadMinutes: Int

    init(leadMinutes: Int) {
        self.leadMinutes = leadMinutes
    }

    func presentation(
        for meeting: MeetingActivityInput,
        now: Date,
        previousEvaluation: Date? = nil
    ) -> MeetingPresentation {
        guard meeting.end > meeting.start else {
            return MeetingPresentation(
                isVisible: false,
                phase: .ambient,
                milestone: nil,
                milestoneDate: nil,
                nextBoundary: nil
            )
        }

        let threshold = meeting.start.addingTimeInterval(TimeInterval(-leadMinutes * 60))
        let boundaries = [threshold, meeting.start.addingTimeInterval(-60), meeting.start, meeting.end]
        let isVisible = now >= threshold && now < meeting.end
        let milestone = latestMilestone(
            threshold: threshold,
            oneMinute: meeting.start.addingTimeInterval(-60),
            start: meeting.start,
            now: now,
            previousEvaluation: previousEvaluation
        )

        return MeetingPresentation(
            isVisible: isVisible,
            phase: isVisible ? .active : .ambient,
            milestone: milestone?.kind,
            milestoneDate: milestone?.date,
            nextBoundary: boundaries.filter { $0 > now }.min()
        )
    }

    private func latestMilestone(
        threshold: Date,
        oneMinute: Date,
        start: Date,
        now: Date,
        previousEvaluation: Date?
    ) -> (kind: MeetingMilestone, date: Date)? {
        guard let previousEvaluation, previousEvaluation < now else {
            return nil
        }

        var milestones: [(kind: MeetingMilestone, date: Date)] = [
            (.oneMinute, oneMinute),
            (.started, start)
        ]
        if threshold != oneMinute {
            milestones.append((.threshold, threshold))
        }

        return milestones
            .filter { $0.date > previousEvaluation && $0.date <= now }
            .max { lhs, rhs in
                if lhs.date != rhs.date {
                    return lhs.date < rhs.date
                }
                return milestonePriority(lhs.kind) < milestonePriority(rhs.kind)
            }
    }

    private func milestonePriority(_ milestone: MeetingMilestone) -> Int {
        switch milestone {
        case .threshold:
            0
        case .oneMinute:
            1
        case .started:
            2
        }
    }
}
