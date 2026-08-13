import Foundation
import XCTest
@testable import Cyclop

final class DownloadFinalizationStoreTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CyclopFinalizationStoreTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let root {
            try? FileManager.default.removeItem(at: root)
        }
        root = nil
    }

    func testStagesSystemTemporaryFileAtDeterministicAppOwnedURL() throws {
        let store = DownloadFinalizationStore(rootDirectory: root)
        let id = UUID(uuidString: "10000000-0000-0000-0000-000000000001")!
        let temporary = root.appendingPathComponent("system-temporary")
        try Data([1, 2, 3]).write(to: temporary)

        let staged = try store.stage(downloadID: id, temporaryURL: temporary)

        XCTAssertEqual(staged, root.appendingPathComponent("\(id.uuidString).stage"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: temporary.path))
        XCTAssertEqual(try Data(contentsOf: staged), Data([1, 2, 3]))
        XCTAssertThrowsError(try store.stage(downloadID: id, temporaryURL: staged))
    }

    func testAtomicJournalRoundTripClassifiesJournalAndStageOnlyCrashPoints() throws {
        let store = DownloadFinalizationStore(rootDirectory: root)
        let journalID = UUID(uuidString: "10000000-0000-0000-0000-000000000002")!
        let orphanID = UUID(uuidString: "10000000-0000-0000-0000-000000000003")!
        let journalStage = try stage(Data([4]), id: journalID, store: store)
        let orphanStage = try stage(Data([5]), id: orphanID, store: store)
        let journal = DownloadFinalizationJournal(
            downloadID: journalID,
            destinationURL: URL(fileURLWithPath: "/Downloads/archive.zip"),
            completedAt: Date(timeIntervalSince1970: 1_000.125)
        )

        try store.save(journal)

        XCTAssertEqual(try store.recoveries(), [
            .journal(journal, stagedURL: journalStage),
            .stagedOnly(downloadID: orphanID, stagedURL: orphanStage),
        ])
        try store.removeJournal(downloadID: journalID)
        XCTAssertEqual(try store.recoveries(), [
            .stagedOnly(downloadID: journalID, stagedURL: journalStage),
            .stagedOnly(downloadID: orphanID, stagedURL: orphanStage),
        ])
    }

    func testJournalSurvivesFinalMoveWithoutStageUntilExplicitMetadataCommitCleanup() throws {
        let store = DownloadFinalizationStore(rootDirectory: root)
        let id = UUID(uuidString: "10000000-0000-0000-0000-000000000004")!
        let staged = try stage(Data([6]), id: id, store: store)
        let destination = root.appendingPathComponent("final.zip")
        let journal = DownloadFinalizationJournal(
            downloadID: id,
            destinationURL: destination,
            completedAt: Date(timeIntervalSince1970: 2_000)
        )
        try store.save(journal)
        try FileManager.default.moveItem(at: staged, to: destination)

        XCTAssertEqual(try store.recoveries(), [.journal(journal, stagedURL: nil)])
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.path))

        try store.removeJournal(downloadID: id)

        XCTAssertTrue(try store.recoveries().isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.path))
    }

    func testCorruptOrSemanticallyInvalidJournalFailsClosedWithoutDeletingFiles() throws {
        let store = DownloadFinalizationStore(rootDirectory: root)
        let id = UUID(uuidString: "10000000-0000-0000-0000-000000000005")!
        let staged = try stage(Data([7]), id: id, store: store)
        let corrupt = root.appendingPathComponent("\(id.uuidString).json")
        try Data("not-json".utf8).write(to: corrupt)

        XCTAssertThrowsError(try store.recoveries())
        XCTAssertTrue(FileManager.default.fileExists(atPath: staged.path))

        let invalid = """
        {"schemaVersion":1,"downloadID":"\(id.uuidString)","destinationURL":"https://example.com/file","completedAt":1000000}
        """
        try Data(invalid.utf8).write(to: corrupt, options: .atomic)

        XCTAssertThrowsError(try store.recoveries())
        XCTAssertTrue(FileManager.default.fileExists(atPath: staged.path))
    }

    func testAbandonmentMarkerMakesCleanupIdempotentWithoutDeletingFinalDestination() throws {
        let store = DownloadFinalizationStore(rootDirectory: root)
        let id = UUID(uuidString: "10000000-0000-0000-0000-000000000006")!
        _ = try stage(Data([8]), id: id, store: store)
        let destination = root.appendingPathComponent("пользовательский-файл.zip")
        try Data([9]).write(to: destination)
        try store.save(DownloadFinalizationJournal(
            downloadID: id,
            destinationURL: destination,
            completedAt: Date(timeIntervalSince1970: 3_000)
        ))

        try store.markAbandoned(downloadID: id)

        XCTAssertEqual(try store.abandonedDownloadIDs(), [id])
        try store.abandon(downloadID: id)
        try store.abandon(downloadID: id)

        XCTAssertTrue(try store.recoveries().isEmpty)
        XCTAssertTrue(try store.abandonedDownloadIDs().isEmpty)
        XCTAssertEqual(try Data(contentsOf: destination), Data([9]))
    }

    private func stage(
        _ data: Data,
        id: UUID,
        store: DownloadFinalizationStore
    ) throws -> URL {
        let temporary = root.appendingPathComponent("temporary-\(UUID().uuidString)")
        try data.write(to: temporary)
        return try store.stage(downloadID: id, temporaryURL: temporary)
    }
}
