import Combine

enum ActivitySourceHealth: Equatable {
    case available
    case unavailable(message: String)
}

struct ActivitySourceState: Equatable {
    var snapshots: [ActivitySnapshot]
    var health: ActivitySourceHealth
}

@MainActor
protocol ActivitySource: AnyObject {
    var sourceID: String { get }
    var statePublisher: AnyPublisher<ActivitySourceState, Never> { get }
    func perform(_ action: ActivityAction, activityID: ActivityID)
}
