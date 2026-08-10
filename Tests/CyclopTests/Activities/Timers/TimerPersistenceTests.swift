import Foundation
import XCTest
@testable import Cyclop

final class TimerPersistenceTests: XCTestCase {
    private var temporaryDirectory: URL!

    override func setUpWithError() throws {
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "CyclopTimerPersistenceTests-\(UUID().uuidString)",
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

    func testRoundTripPreservesExactRunningPausedAndCompletedFieldsWithMillisecondDates() throws {
        let file = temporaryDirectory.appendingPathComponent("timers.json")
        let persistence = JSONTimerPersistence(fileURL: file)
        let timers = [
            CyclopTimer(
                id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
                name: "Фокус",
                originalDuration: 1_500,
                phase: .running,
                endsAt: Date(timeIntervalSince1970: 1_700_000_000.125),
                pausedRemaining: nil,
                completedAt: nil,
                completionSoundPlayed: false
            ),
            CyclopTimer(
                id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
                name: "Перерыв",
                originalDuration: 600,
                phase: .paused,
                endsAt: nil,
                pausedRemaining: 420.25,
                completedAt: nil,
                completionSoundPlayed: false
            ),
            CyclopTimer(
                id: UUID(uuidString: "00000000-0000-0000-0000-000000000003")!,
                name: "Чай",
                originalDuration: 300,
                phase: .completed,
                endsAt: nil,
                pausedRemaining: 0,
                completedAt: Date(timeIntervalSince1970: 200.875),
                completionSoundPlayed: true
            ),
        ]

        try persistence.save(timers)

        XCTAssertEqual(try persistence.load(), timers)

        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [[String: Any]]
        )
        XCTAssertEqual((object[0]["endsAt"] as? NSNumber)?.int64Value, 1_700_000_000_125)
        XCTAssertEqual((object[2]["completedAt"] as? NSNumber)?.int64Value, 200_875)
    }

    func testRemainingUsesPhaseStateAndClampsNegativeValuesToZero() {
        let now = Date(timeIntervalSince1970: 1_000)

        XCTAssertEqual(timer(phase: .running, endsAt: now.addingTimeInterval(25)).remaining(at: now), 25)
        XCTAssertEqual(timer(phase: .running, endsAt: now.addingTimeInterval(-1)).remaining(at: now), 0)
        XCTAssertEqual(timer(phase: .running).remaining(at: now), 0)
        XCTAssertEqual(timer(phase: .paused, pausedRemaining: 40).remaining(at: now), 40)
        XCTAssertEqual(timer(phase: .paused, pausedRemaining: -1).remaining(at: now), 0)
        XCTAssertEqual(timer(phase: .paused).remaining(at: now), 0)
        XCTAssertEqual(
            timer(
                phase: .completed,
                endsAt: now.addingTimeInterval(25),
                pausedRemaining: 40
            ).remaining(at: now),
            0
        )
        XCTAssertEqual(
            timer(
                phase: .cancelled,
                endsAt: now.addingTimeInterval(25),
                pausedRemaining: 40
            ).remaining(at: now),
            0
        )
    }

    func testLoadReturnsEmptyArrayWhenFileDoesNotExist() throws {
        let missing = temporaryDirectory.appendingPathComponent("missing/timers.json")

        XCTAssertEqual(try JSONTimerPersistence(fileURL: missing).load(), [])
    }

    func testLoadThrowsForCorruptJSON() throws {
        let broken = temporaryDirectory.appendingPathComponent("timers.json")
        try Data("not-json".utf8).write(to: broken)

        XCTAssertThrowsError(try JSONTimerPersistence(fileURL: broken).load())
    }

    func testLoadDoesNotTreatOtherFileSystemErrorsAsMissingFile() throws {
        let directoryAtFileURL = temporaryDirectory.appendingPathComponent(
            "timers.json",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: directoryAtFileURL,
            withIntermediateDirectories: false
        )

        XCTAssertThrowsError(try JSONTimerPersistence(fileURL: directoryAtFileURL).load())
    }

    func testAtomicSaveCreatesNestedParentDirectories() throws {
        let file = temporaryDirectory
            .appendingPathComponent("nested", isDirectory: true)
            .appendingPathComponent("state", isDirectory: true)
            .appendingPathComponent("timers.json")
        let persistence = JSONTimerPersistence(fileURL: file)
        let timers = [timer(phase: .paused, pausedRemaining: 12)]

        try persistence.save(timers)

        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        XCTAssertEqual(try persistence.load(), timers)
    }

    func testLiveUsesInjectedFileManagerApplicationSupportLookup() {
        let applicationSupport = temporaryDirectory.appendingPathComponent("Application Support")
        let fileManager = ApplicationSupportFileManager(applicationSupportURL: applicationSupport)

        let persistence = JSONTimerPersistence.live(fileManager: fileManager)

        XCTAssertEqual(
            persistence.fileURL,
            applicationSupport.appendingPathComponent("Cyclop/timers.json")
        )
        XCTAssertEqual(fileManager.lookups.count, 1)
        XCTAssertEqual(fileManager.lookups.first?.directory, .applicationSupportDirectory)
        XCTAssertEqual(fileManager.lookups.first?.domainMask, .userDomainMask)
    }

    private func timer(
        phase: TimerPhase,
        endsAt: Date? = nil,
        pausedRemaining: TimeInterval? = nil
    ) -> CyclopTimer {
        CyclopTimer(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000010")!,
            name: "Тест",
            originalDuration: 60,
            phase: phase,
            endsAt: endsAt,
            pausedRemaining: pausedRemaining,
            completedAt: nil,
            completionSoundPlayed: false
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
