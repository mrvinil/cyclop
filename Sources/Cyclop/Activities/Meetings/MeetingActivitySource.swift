import AppKit
import Combine
import Foundation

struct MeetingSourceInput: Equatable {
    enum Access: Equatable {
        case notRequested
        case granted
        case denied
    }

    let access: Access
    let meetings: [MeetingActivityInput]
}

@MainActor
protocol CalendarActivityStateProviding {
    var activityStatePublisher: AnyPublisher<CalendarStore.ActivityState, Never> { get }
}

extension CalendarStore: CalendarActivityStateProviding {}

@MainActor
final class MeetingActivitySource: ActivitySource {
    let sourceID = "meetings"

    var statePublisher: AnyPublisher<ActivitySourceState, Never> {
        state.publisher
    }

    private let opener: (URL) -> Void
    private let isJoinable: (URL) -> Bool
    private let clock: ActivityClock
    private let scheduler: ActivityScheduling
    private let state = NonReentrantCurrentValueSubject<ActivitySourceState>(
        .init(snapshots: [], health: .available)
    )
    private var cancellables = Set<AnyCancellable>()
    private var currentInput: MeetingSourceInput?
    private var currentLeadMinutes: Int?
    private var evaluationCursor: Date?
    private var wakeGeneration: UInt64 = 0
    private var wakeCancellation: ActivityCancellation?

    convenience init(
        calendar: any CalendarActivityStateProviding,
        settings: ActivitySettings,
        clock: ActivityClock,
        scheduler: ActivityScheduling
    ) {
        self.init(
            states: calendar.activityStatePublisher
                .map(Self.sourceInput)
                .eraseToAnyPublisher(),
            leadMinutes: settings.$meetingLeadMinutes.eraseToAnyPublisher(),
            opener: { NSWorkspace.shared.open($0) },
            isJoinable: MeetingLink.isJoinable,
            clock: clock,
            scheduler: scheduler
        )
    }

    init(
        states: AnyPublisher<MeetingSourceInput, Never>,
        leadMinutes: AnyPublisher<Int, Never>,
        opener: @escaping (URL) -> Void,
        isJoinable: @escaping (URL) -> Bool = MeetingLink.isJoinable,
        clock: ActivityClock,
        scheduler: ActivityScheduling
    ) {
        self.opener = opener
        self.isJoinable = isJoinable
        self.clock = clock
        self.scheduler = scheduler

        states
            .sink { [weak self] input in
                self?.receive(input: input)
            }
            .store(in: &cancellables)
        leadMinutes
            .sink { [weak self] minutes in
                self?.receive(leadMinutes: minutes)
            }
            .store(in: &cancellables)
    }

    deinit {
        let cancellation = wakeCancellation
        Task { @MainActor in
            cancellation?.cancel()
        }
    }

    func perform(_ action: ActivityAction, activityID: ActivityID) {
        guard action == .join,
              activityID.source == sourceID,
              let snapshot = state.value.snapshots.first(where: { $0.id == activityID }),
              snapshot.availableActions.contains(.join),
              let meeting = currentInput?.meetings.first(where: { $0.id == activityID.local }),
              let link = meeting.link,
              isJoinable(link) else {
            return
        }
        opener(link)
    }

    private func receive(input: MeetingSourceInput) {
        if currentInput?.access != .granted, input.access == .granted {
            evaluationCursor = nil
        } else if input.access != .granted {
            evaluationCursor = nil
        }
        currentInput = input
        evaluate()
    }

    private func receive(leadMinutes: Int) {
        let normalized = Self.normalizedLeadMinutes(leadMinutes)
        let didChange = currentLeadMinutes.map { $0 != normalized } ?? false
        currentLeadMinutes = normalized
        evaluate(suppressMilestones: didChange)
    }

    private func evaluate(suppressMilestones: Bool = false) {
        wakeGeneration &+= 1
        let evaluationGeneration = wakeGeneration
        let ownedCancellation = wakeCancellation
        wakeCancellation = nil
        ownedCancellation?.cancel()

        guard let input = currentInput, let leadMinutes = currentLeadMinutes else { return }
        guard input.access == .granted else {
            publish(.init(
                snapshots: [],
                health: input.access == .denied
                    ? .unavailable(message: "Нет доступа к календарю")
                    : .available
            ))
            return
        }

        let now = clock.now
        let previousEvaluation = suppressMilestones ? nil : evaluationCursor
        let policy = MeetingActivityPolicy(leadMinutes: leadMinutes)
        let evaluated = input.meetings.map { meeting in
            (meeting, policy.presentation(
                for: meeting,
                now: now,
                previousEvaluation: previousEvaluation
            ))
        }
        let snapshots = evaluated.compactMap { entry -> ActivitySnapshot? in
            let (meeting, presentation) = entry
            guard presentation.isVisible else { return nil }
            return Self.snapshot(
                meeting: meeting,
                presentation: presentation,
                isJoinable: isJoinable
            )
        }.sorted {
            if $0.deadline != $1.deadline {
                return ($0.deadline ?? .distantFuture) < ($1.deadline ?? .distantFuture)
            }
            return $0.id.local < $1.id.local
        }
        evaluationCursor = max(evaluationCursor ?? now, now)
        publish(.init(snapshots: snapshots, health: .available))
        guard evaluationGeneration == wakeGeneration else { return }

        let schedulingNow = evaluationCursor ?? now
        if let nextBoundary = input.meetings.compactMap({ meeting in
            policy.presentation(for: meeting, now: schedulingNow).nextBoundary
        }).min() {
            scheduleBoundary(at: nextBoundary)
        }
    }

    private func scheduleBoundary(at date: Date) {
        let generation = wakeGeneration
        let cancellation = scheduler.schedule(at: date) { [weak self] in
            self?.receiveBoundaryWake(generation: generation)
        }

        guard generation == wakeGeneration, wakeCancellation == nil else {
            cancellation.cancel()
            return
        }
        guard clock.now < date else {
            wakeGeneration &+= 1
            cancellation.cancel()
            evaluate()
            return
        }
        wakeCancellation = cancellation
    }

    private func receiveBoundaryWake(generation: UInt64) {
        guard generation == wakeGeneration else { return }
        evaluate()
    }

    private func publish(_ updated: ActivitySourceState) {
        if state.value != updated {
            state.send(updated)
        }
    }

    private static func normalizedLeadMinutes(_ value: Int) -> Int {
        [5, 10, 15, 30].contains(value) ? value : 15
    }

    private static func sourceInput(_ state: CalendarStore.ActivityState) -> MeetingSourceInput {
        let access: MeetingSourceInput.Access
        switch state.access {
        case .notRequested: access = .notRequested
        case .granted: access = .granted
        case .denied: access = .denied
        }
        return MeetingSourceInput(
            access: access,
            meetings: state.meetings.map {
                MeetingActivityInput(
                    id: $0.id,
                    title: $0.title,
                    start: $0.start,
                    end: $0.end,
                    link: $0.link,
                    provider: $0.provider
                )
            }
        )
    }

    private static func snapshot(
        meeting: MeetingActivityInput,
        presentation: MeetingPresentation,
        isJoinable: (URL) -> Bool
    ) -> ActivitySnapshot {
        let actions: Set<ActivityAction>
        if let link = meeting.link, isJoinable(link) {
            actions = [.join]
        } else {
            actions = []
        }
        return ActivitySnapshot(
            id: .init(source: "meetings", local: meeting.id),
            sourceID: "meetings",
            kind: .meeting,
            phase: presentation.phase,
            title: meeting.title,
            subtitle: meeting.provider ?? "",
            progress: nil,
            deadline: meeting.start,
            occurredAt: presentation.milestoneDate,
            availableActions: actions,
            containsSensitiveText: true
        )
    }
}
