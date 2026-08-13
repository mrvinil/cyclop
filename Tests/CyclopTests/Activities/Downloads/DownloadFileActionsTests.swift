import Darwin
import Foundation
import XCTest
@testable import Cyclop

final class DownloadFileActionsTests: XCTestCase {
    func testLiveActionsRejectFIFOAsMissingRatherThanTreatingItAsAFile() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CyclopFileActionsTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let fifo = root.appendingPathComponent("pipe")
        XCTAssertEqual(mkfifo(fifo.path, S_IRUSR | S_IWUSR), 0)

        let result = DownloadFileActions.live().open(fifo)

        guard case .failure(.missingFile) = result else {
            return XCTFail("FIFO не должен считаться обычным файлом")
        }
    }
}
