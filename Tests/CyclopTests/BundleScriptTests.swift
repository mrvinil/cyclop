import Foundation
import XCTest

final class BundleScriptTests: XCTestCase {
    func testBundleEnablesSystemFileQuarantineForFilesCreatedByCyclop() throws {
        let script = try String(
            contentsOf: repositoryRoot.appendingPathComponent("Scripts/bundle.sh"),
            encoding: .utf8
        )

        XCTAssertTrue(script.contains("<key>LSFileQuarantineEnabled</key><true/>"))
    }

    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
