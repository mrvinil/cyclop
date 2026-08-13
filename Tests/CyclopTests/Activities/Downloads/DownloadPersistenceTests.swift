import Foundation
import XCTest
@testable import Cyclop

final class DownloadPersistenceTests: XCTestCase {
    private var temporaryDirectory: URL!

    override func setUpWithError() throws {
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "CyclopDownloadPersistenceTests-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: true
        )
    }

    override func tearDownWithError() throws {
        if let temporaryDirectory {
            try FileManager.default.removeItem(at: temporaryDirectory)
        }
        temporaryDirectory = nil
    }

    func testRoundTripPreservesEveryPhaseAndModelFieldWithMillisecondDates() throws {
        let file = temporaryDirectory.appendingPathComponent("downloads.json")
        let persistence = JSONDownloadPersistence(fileURL: file)
        let downloads = [
            download(
                id: "00000000-0000-0000-0000-000000000001",
                phase: .queued,
                displayName: "В очереди",
                destinationURL: nil,
                taskIdentifier: nil,
                resumeData: nil,
                bytesReceived: 0,
                totalBytes: nil,
                createdAt: 100.125,
                completedAt: nil,
                failure: nil
            ),
            download(
                id: "00000000-0000-0000-0000-000000000002",
                phase: .downloading,
                displayName: "Загрузка",
                destinationURL: URL(fileURLWithPath: "/tmp/download.zip"),
                taskIdentifier: 42,
                resumeData: Data([1, 2, 3]),
                bytesReceived: 512,
                totalBytes: 1_024,
                createdAt: 200.875,
                completedAt: nil,
                failure: nil
            ),
            download(
                id: "00000000-0000-0000-0000-000000000003",
                phase: .paused,
                displayName: "Пауза",
                destinationURL: nil,
                taskIdentifier: 43,
                resumeData: Data([4, 5, 6]),
                bytesReceived: 256,
                totalBytes: 2_048,
                createdAt: 300.625,
                completedAt: nil,
                failure: nil
            ),
            download(
                id: "00000000-0000-0000-0000-000000000004",
                phase: .completed,
                displayName: "Готово",
                destinationURL: URL(fileURLWithPath: "/tmp/complete.zip"),
                taskIdentifier: nil,
                resumeData: nil,
                bytesReceived: 4_096,
                totalBytes: 4_096,
                createdAt: 400.5,
                completedAt: 500.375,
                failure: nil
            ),
            download(
                id: "00000000-0000-0000-0000-000000000005",
                phase: .failed,
                displayName: "Ошибка",
                destinationURL: nil,
                taskIdentifier: 44,
                resumeData: nil,
                bytesReceived: 1_024,
                totalBytes: 8_192,
                createdAt: 600.25,
                completedAt: 700.125,
                failedAt: 710.875,
                failure: DownloadFailure(code: "network_lost", message: "Сеть недоступна")
            ),
            download(
                id: "00000000-0000-0000-0000-000000000006",
                phase: .cancelled,
                displayName: "Отменено",
                destinationURL: nil,
                taskIdentifier: nil,
                resumeData: Data(),
                bytesReceived: -1,
                totalBytes: 10,
                createdAt: 800.75,
                completedAt: 900.625,
                failure: nil
            ),
        ]

        try persistence.save(downloads)

        XCTAssertEqual(try persistence.load(), downloads)

        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [[String: Any]]
        )
        XCTAssertEqual((object[0]["createdAt"] as? NSNumber)?.int64Value, 100_125)
        XCTAssertEqual((object[3]["completedAt"] as? NSNumber)?.int64Value, 500_375)
        XCTAssertEqual((object[4]["failedAt"] as? NSNumber)?.int64Value, 710_875)
    }

    func testProgressIsNilWithoutPositiveTotalBytes() {
        XCTAssertNil(download(totalBytes: nil).progress)
        XCTAssertNil(download(totalBytes: 0).progress)
        XCTAssertNil(download(totalBytes: -1).progress)
    }

    func testProgressClampsReceivedBytesToZeroThroughOne() {
        XCTAssertEqual(download(bytesReceived: -1, totalBytes: 10).progress, 0)
        XCTAssertEqual(download(bytesReceived: 0, totalBytes: 10).progress, 0)
        XCTAssertEqual(download(bytesReceived: 5, totalBytes: 10).progress, 0.5)
        XCTAssertEqual(download(bytesReceived: 10, totalBytes: 10).progress, 1)
        XCTAssertEqual(download(bytesReceived: 11, totalBytes: 10).progress, 1)
    }

    func testCompletedDownloadReportsFullProgressWhenLengthWasUnknown() {
        XCTAssertEqual(download(phase: .completed, totalBytes: nil).progress, 1)
    }

    func testLoadReturnsEmptyArrayOnlyWhenFileDoesNotExist() throws {
        let missing = temporaryDirectory.appendingPathComponent("missing/downloads.json")

        XCTAssertEqual(try JSONDownloadPersistence(fileURL: missing).load(), [])
    }

    func testLoadThrowsForCorruptJSON() throws {
        let broken = temporaryDirectory.appendingPathComponent("downloads.json")
        try Data("not-json".utf8).write(to: broken)

        XCTAssertThrowsError(try JSONDownloadPersistence(fileURL: broken).load())
    }

    func testLegacyJSONWithoutFailedAtDecodesWithNilMigrationValue() throws {
        let file = temporaryDirectory.appendingPathComponent("downloads.json")
        let legacyJSON = """
        [{
          "id":"00000000-0000-0000-0000-000000000001",
          "remoteURL":"https://example.com/archive.zip",
          "phase":"failed",
          "displayName":"archive.zip",
          "bytesReceived":25,
          "totalBytes":100,
          "createdAt":100000,
          "failure":{"code":"network","message":"Ошибка сети"}
        }]
        """
        try Data(legacyJSON.utf8).write(to: file)

        let loaded = try XCTUnwrap(JSONDownloadPersistence(fileURL: file).load().first)

        XCTAssertEqual(loaded.phase, .failed)
        XCTAssertNil(loaded.failedAt)
        XCTAssertEqual(loaded.createdAt, Date(timeIntervalSince1970: 100))
    }

    func testLoadDoesNotTreatOtherFileSystemErrorsAsMissingFile() throws {
        let directoryAtFileURL = temporaryDirectory.appendingPathComponent(
            "downloads.json",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: directoryAtFileURL,
            withIntermediateDirectories: false
        )

        XCTAssertThrowsError(try JSONDownloadPersistence(fileURL: directoryAtFileURL).load())
    }

    func testAtomicSaveCreatesNestedParentDirectoriesAndReplacesExistingData() throws {
        let file = temporaryDirectory
            .appendingPathComponent("nested", isDirectory: true)
            .appendingPathComponent("state", isDirectory: true)
            .appendingPathComponent("downloads.json")
        let persistence = JSONDownloadPersistence(fileURL: file)
        let first = [download(phase: .paused, displayName: "Первая")]
        let replacement = [download(phase: .completed, displayName: "Вторая")]

        try persistence.save(first)
        try persistence.save(replacement)

        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        XCTAssertEqual(try persistence.load(), replacement)
    }

    func testLiveUsesInjectedFileManagerApplicationSupportLookup() {
        let applicationSupport = temporaryDirectory.appendingPathComponent("Application Support")
        let fileManager = ApplicationSupportFileManager(applicationSupportURL: applicationSupport)

        let persistence = JSONDownloadPersistence.live(fileManager: fileManager)

        XCTAssertEqual(
            persistence.fileURL,
            applicationSupport.appendingPathComponent("Cyclop/downloads.json")
        )
        XCTAssertEqual(fileManager.lookups.count, 1)
        XCTAssertEqual(fileManager.lookups.first?.directory, .applicationSupportDirectory)
        XCTAssertEqual(fileManager.lookups.first?.domainMask, .userDomainMask)
    }

    private func download(
        id: String = "00000000-0000-0000-0000-000000000010",
        phase: DownloadPhase = .queued,
        displayName: String = "Тест",
        destinationURL: URL? = nil,
        taskIdentifier: Int? = nil,
        resumeData: Data? = nil,
        bytesReceived: Int64 = 0,
        totalBytes: Int64? = nil,
        createdAt: TimeInterval = 1_000,
        completedAt: TimeInterval? = nil,
        failedAt: TimeInterval? = nil,
        failure: DownloadFailure? = nil
    ) -> CyclopDownload {
        CyclopDownload(
            id: UUID(uuidString: id)!,
            remoteURL: URL(string: "https://example.com/archive.zip")!,
            phase: phase,
            displayName: displayName,
            destinationURL: destinationURL,
            taskIdentifier: taskIdentifier,
            resumeData: resumeData,
            bytesReceived: bytesReceived,
            totalBytes: totalBytes,
            createdAt: Date(timeIntervalSince1970: createdAt),
            completedAt: completedAt.map { Date(timeIntervalSince1970: $0) },
            failedAt: failedAt.map { Date(timeIntervalSince1970: $0) },
            failure: failure
        )
    }
}

private final class ApplicationSupportFileManager: FileManager, @unchecked Sendable {
    struct Lookup {
        let directory: SearchPathDirectory
        let domainMask: SearchPathDomainMask
    }

    let applicationSupportURL: URL
    private(set) var lookups: [Lookup] = []

    init(applicationSupportURL: URL) {
        self.applicationSupportURL = applicationSupportURL
        super.init()
    }

    override func urls(
        for directory: SearchPathDirectory,
        in domainMask: SearchPathDomainMask
    ) -> [URL] {
        lookups.append(Lookup(directory: directory, domainMask: domainMask))
        return [applicationSupportURL]
    }
}
