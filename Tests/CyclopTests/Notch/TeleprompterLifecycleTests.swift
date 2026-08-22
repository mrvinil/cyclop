import XCTest
@testable import Cyclop

@MainActor
final class TeleprompterLifecycleTests: XCTestCase {
    func testStoppingViewModelFlushesPendingTeleprompterText() {
        var writes = 0
        let prompter = TeleprompterStore(
            fileURL: URL(fileURLWithPath: "/tmp/teleprompter-test.txt"),
            write: { _, _ in writes += 1 }
        )
        prompter.script = "Последняя строка"
        let viewModel = NotchViewModel(
            geometry: .current(),
            teleprompter: prompter
        )

        viewModel.stop()

        XCTAssertEqual(writes, 1)
    }

    func testDismissRunningTeleprompterStopsOnlyActiveTeleprompter() {
        let prompter = TeleprompterStore(
            fileURL: URL(fileURLWithPath: "/tmp/teleprompter-test.txt"),
            write: { _, _ in }
        )
        prompter.script = "Текст для чтения"
        prompter.contentHeight = 200
        prompter.viewportHeight = 100
        let viewModel = NotchViewModel(
            geometry: .current(),
            teleprompter: prompter
        )
        viewModel.tab = .teleprompter
        prompter.start()

        XCTAssertTrue(viewModel.dismissRunningTeleprompter())
        XCTAssertFalse(prompter.isRunning)
        XCTAssertFalse(viewModel.dismissRunningTeleprompter())
    }
}
