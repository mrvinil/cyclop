import XCTest
@testable import Cyclop

final class ActivityModelsTests: XCTestCase {
    func testSnapshotIdentityDoesNotDependOnDisplayText() {
        let id = ActivityID(source: "timer", local: "abc")
        let first = ActivitySnapshot(
            id: id,
            sourceID: "timers",
            kind: .timer,
            phase: .active,
            title: "Помодоро",
            subtitle: "",
            progress: nil,
            deadline: Date(timeIntervalSince1970: 100),
            occurredAt: nil,
            availableActions: [.pause, .cancel],
            containsSensitiveText: true
        )
        var second = first
        second.title = "Таймер"
        XCTAssertEqual(first.id, second.id)
        XCTAssertEqual(first.availableActions, [.pause, .cancel])
    }
}
