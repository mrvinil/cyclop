import Foundation
import XCTest
@testable import Cyclop

@MainActor
final class RetiredOwnDownloadCleanupTests: XCTestCase {
    private var root: URL!
    private var defaults: UserDefaults!
    private var defaultsSuiteName = ""

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CyclopRetiredDownloadCleanup-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defaultsSuiteName = "CyclopRetiredDownloadCleanup-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: defaultsSuiteName)!
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
        defaults.removePersistentDomain(forName: defaultsSuiteName)
    }

    func testRunIfNeededCancelsOldTasksAndRemovesOnlyOwnTechnicalDataOnce() throws {
        let cyclop = root.appendingPathComponent("Cyclop", isDirectory: true)
        let persistence = cyclop.appendingPathComponent("downloads.json")
        let finalizations = cyclop.appendingPathComponent("DownloadFinalizations", isDirectory: true)
        let savedFile = root.appendingPathComponent("Downloads/important.zip")
        let unrelatedData = cyclop.appendingPathComponent("notes.json")
        try FileManager.default.createDirectory(at: finalizations, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: savedFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("old queue".utf8).write(to: persistence)
        try Data("journal".utf8).write(to: finalizations.appendingPathComponent("old.json"))
        try Data("download".utf8).write(to: savedFile)
        try Data("note".utf8).write(to: unrelatedData)

        var cancelledTaskSessions = 0
        let cleanup = RetiredOwnDownloadCleanup(
            applicationSupportDirectory: root,
            defaults: defaults,
            cancelRetiredTasks: { completion in
                cancelledTaskSessions += 1
                completion()
            }
        )

        cleanup.runIfNeeded()

        XCTAssertEqual(cancelledTaskSessions, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: persistence.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: finalizations.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: savedFile.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: unrelatedData.path))

        cleanup.runIfNeeded()

        XCTAssertEqual(cancelledTaskSessions, 1)
    }
}
