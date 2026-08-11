import Combine
import Foundation
import XCTest
@testable import Cyclop

@MainActor
final class DownloadManagerTests: XCTestCase {
    private var defaultsSuiteName: String!
    private var defaults: UserDefaults!
    private var settings: ActivitySettings!
    private var clock: MutableActivityClock!
    private var persistence: MemoryDownloadPersistence!
    private var transport: FakeDownloadTransport!
    private var scheduler: ManualActivityScheduler!
    private var files: DownloadFileOperationsDouble!
    private var opened: [URL] = []
    private var revealed: [URL] = []

    override func setUp() {
        super.setUp()
        defaultsSuiteName = "DownloadManagerTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: defaultsSuiteName)!
        defaults.removePersistentDomain(forName: defaultsSuiteName)
        settings = ActivitySettings(
            defaults: defaults,
            homeDirectory: URL(fileURLWithPath: "/Users/test")
        )
        clock = MutableActivityClock(now: date(1_000))
        persistence = MemoryDownloadPersistence()
        transport = FakeDownloadTransport()
        scheduler = ManualActivityScheduler()
        files = DownloadFileOperationsDouble()
        opened = []
        revealed = []
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: defaultsSuiteName)
        defaultsSuiteName = nil
        defaults = nil
        settings = nil
        clock = nil
        persistence = nil
        transport = nil
        scheduler = nil
        files = nil
        opened = []
        revealed = []
        super.tearDown()
    }

    func testStartsAtMostThreeAndDrainsNextInDeterministicQueueOrder() throws {
        let manager = makeManager(maxConcurrent: 9)
        try manager.start()
        let ids = try (0 ..< 5).map { try manager.enqueue("https://example.com/\($0).zip") }

        XCTAssertEqual(transport.startedIDs, Array(ids.prefix(3)))
        XCTAssertEqual(manager.downloads.filter { $0.phase == .downloading }.map(\.id), Array(ids.prefix(3)))
        XCTAssertEqual(manager.downloads.filter { $0.phase == .queued }.map(\.id), Array(ids.suffix(2)))

        transport.send(.failed(
            id: ids[0],
            code: "network",
            message: "Сеть недоступна",
            resumeData: nil
        ))

        XCTAssertEqual(transport.startedIDs, Array(ids.prefix(4)))
        XCTAssertEqual(manager.downloads.first { $0.id == ids[3] }?.phase, .downloading)
    }

    func testReservesWholeBatchBeforeSynchronousTransportEventsAndNeverExceedsThree() throws {
        let queued = (1 ... 5).map {
            download(id: id($0), phase: .queued, createdAt: TimeInterval($0))
        }
        persistence = MemoryDownloadPersistence(queued)
        let manager = makeManager(maxConcurrent: 3)
        var downloadingCountsAtStart: [Int] = []
        transport.onStart = { [weak manager, weak transport] id in
            downloadingCountsAtStart.append(
                manager?.downloads.filter { $0.phase == .downloading }.count ?? -1
            )
            if transport?.startedIDs.count == 1 {
                transport?.send(.failed(
                    id: id,
                    code: "sync-failure",
                    message: "Синхронная ошибка",
                    resumeData: nil
                ))
            }
        }

        try manager.start()

        XCTAssertEqual(downloadingCountsAtStart.first, 3)
        XCTAssertLessThanOrEqual(downloadingCountsAtStart.max() ?? 0, 3)
        XCTAssertEqual(transport.startedIDs, Array(queued.prefix(4).map(\.id)))
    }

    func testStartPurgesCancelledRestoresDownloadingAndQueuesByCreatedAtBeforeExternalCalls() throws {
        let cancelled = download(id: id(1), phase: .cancelled, createdAt: 100)
        let later = download(id: id(2), phase: .queued, createdAt: 300)
        let active = download(id: id(3), phase: .downloading, taskIdentifier: 42, createdAt: 200)
        let earlier = download(id: id(4), phase: .queued, createdAt: 150)
        let paused = download(id: id(5), phase: .paused, resumeData: Data([5]), createdAt: 50)
        persistence = MemoryDownloadPersistence([cancelled, later, active, earlier, paused])
        var timeline: [String] = []
        persistence.onSave = { _ in timeline.append("save") }
        transport.onRestore = { _ in timeline.append("restore") }
        transport.onStart = { id in timeline.append("start:\(id.uuidString)") }
        let manager = makeManager(maxConcurrent: 3)

        try manager.start()

        XCTAssertEqual(persistence.savedValues.first?.contains(where: { $0.id == cancelled.id }), false)
        XCTAssertEqual(manager.downloads.contains(where: { $0.id == cancelled.id }), false)
        XCTAssertEqual(transport.restoredValues, [[active]])
        XCTAssertEqual(transport.startedIDs, [earlier.id, later.id])
        XCTAssertEqual(timeline.prefix(2), ["save", "restore"])
        XCTAssertEqual(manager.downloads.first { $0.id == paused.id }?.phase, .paused)
    }

    func testLoadFailureBlocksWritesHandlerAndTransportUntilSuccessfulRestart() throws {
        persistence.loadError = TestFailure.failed
        let manager = makeManager()

        XCTAssertThrowsError(try manager.start()) { error in
            XCTAssertEqual(error as? DownloadManagerError, .persistenceFailed)
        }
        XCTAssertThrowsError(try manager.enqueue("https://example.com/new.zip")) { error in
            XCTAssertEqual(error as? DownloadManagerError, .persistenceFailed)
        }

        XCTAssertEqual(
            manager.health,
            .unavailable(message: "Не удалось загрузить список загрузок")
        )
        XCTAssertNil(transport.eventHandler)
        XCTAssertEqual(persistence.saveCount, 0)
        XCTAssertTrue(transport.startCalls.isEmpty)

        persistence.loadError = nil
        try manager.start()
        _ = try manager.enqueue("https://example.com/new.zip")
        XCTAssertEqual(manager.health, .available)
        XCTAssertEqual(transport.startCalls.count, 1)
    }

    func testCancelledCleanupSaveFailurePublishesOnlyPersistedLoadedStateAndDoesNotAttachTransport() {
        let cancelled = download(id: id(1), phase: .cancelled)
        let queued = download(id: id(2), phase: .queued)
        persistence = MemoryDownloadPersistence([cancelled, queued])
        persistence.saveError = TestFailure.failed
        let manager = makeManager()

        XCTAssertThrowsError(try manager.start()) { error in
            XCTAssertEqual(error as? DownloadManagerError, .persistenceFailed)
        }

        XCTAssertEqual(manager.downloads, [cancelled, queued])
        XCTAssertEqual(
            manager.health,
            .unavailable(message: "Не удалось сохранить список загрузок")
        )
        XCTAssertNil(transport.eventHandler)
        XCTAssertTrue(transport.startCalls.isEmpty)
    }

    func testStartIsIdempotentStopDetachesHandlerAndRestartLoadsAgain() throws {
        let manager = makeManager()
        try manager.start()
        let firstHandler = transport.eventHandler
        try manager.start()

        XCTAssertEqual(persistence.loadCount, 1)
        XCTAssertNotNil(firstHandler)
        XCTAssertNotNil(transport.eventHandler)

        manager.stop()
        XCTAssertNil(transport.eventHandler)
        transport.send(.progress(id: id(99), received: 10, expected: 20))
        try manager.start()
        XCTAssertEqual(persistence.loadCount, 2)
        XCTAssertNotNil(transport.eventHandler)
    }

    func testWaitsForAsynchronousRestoreBeforePublicActionsOrQueueDrain() throws {
        let active = download(id: id(1), phase: .downloading, taskIdentifier: 44)
        let queued = download(id: id(2), phase: .queued)
        persistence = MemoryDownloadPersistence([active, queued])
        transport.completesRestoreImmediately = false
        let manager = makeManager(maxConcurrent: 2)

        try manager.start()
        try manager.start()

        XCTAssertEqual(transport.restoredValues, [[active]])
        XCTAssertEqual(transport.pendingRestoreCompletions.count, 1)
        XCTAssertTrue(transport.startCalls.isEmpty)
        XCTAssertThrowsError(try manager.enqueue("https://example.com/waiting.zip")) { error in
            XCTAssertEqual(error as? DownloadManagerError, .persistenceFailed)
        }

        transport.completeNextRestore()

        XCTAssertEqual(transport.startedIDs, [queued.id])
        XCTAssertEqual(manager.downloads.first { $0.id == queued.id }?.phase, .downloading)
        XCTAssertNoThrow(try manager.enqueue("https://example.com/ready.zip"))
    }

    func testLateRestoreCompletionAfterStopCannotDrainOrUnlockNewLifecycle() throws {
        let firstQueued = download(id: id(1), phase: .queued)
        persistence = MemoryDownloadPersistence([firstQueued])
        transport.completesRestoreImmediately = false
        let manager = makeManager(maxConcurrent: 1)

        try manager.start()
        manager.stop()

        let secondQueued = download(id: id(2), phase: .queued)
        persistence.stored = [secondQueued]
        try manager.start()
        XCTAssertEqual(transport.pendingRestoreCompletions.count, 2)

        transport.completeNextRestore()

        XCTAssertTrue(transport.startCalls.isEmpty)
        XCTAssertThrowsError(try manager.enqueue("https://example.com/still-waiting.zip"))

        transport.completeNextRestore()

        XCTAssertEqual(transport.startedIDs, [secondQueued.id])
        XCTAssertEqual(manager.downloads.map(\.id), [secondQueued.id])
    }

    func testAsyncRestoreDrainSaveFailureSchedulesLifecycleRecoveryWithoutReloadOrSecondRestore() throws {
        let queued = download(id: id(1), phase: .queued)
        persistence = MemoryDownloadPersistence([queued])
        transport.completesRestoreImmediately = false
        let manager = makeManager(maxConcurrent: 1)

        try manager.start()
        persistence.failingSaveCalls = [1]
        transport.completeNextRestore()

        XCTAssertEqual(manager.health, .unavailable(message: "Не удалось сохранить список загрузок"))
        XCTAssertEqual(manager.downloads.first?.phase, .queued)
        XCTAssertTrue(transport.startCalls.isEmpty)
        let recovery = try XCTUnwrap(scheduler.activeEntries.first)
        XCTAssertEqual(recovery.date, date(1_002))

        clock.advance(by: 2)
        recovery.action()

        XCTAssertEqual(manager.health, .available)
        XCTAssertEqual(manager.downloads.first?.phase, .downloading)
        XCTAssertEqual(transport.startedIDs, [queued.id])
        XCTAssertEqual(persistence.loadCount, 1)
        XCTAssertEqual(transport.restoredValues, [[]])
        XCTAssertTrue(scheduler.activeEntries.isEmpty)
    }

    func testAsyncRestoreLifecycleRecoveryReschedulesUntilStoreRecovers() throws {
        let queued = download(id: id(1), phase: .queued)
        persistence = MemoryDownloadPersistence([queued])
        persistence.failingSaveCalls = [1, 2]
        transport.completesRestoreImmediately = false
        let manager = makeManager(maxConcurrent: 1)

        try manager.start()
        transport.completeNextRestore()
        let firstRecovery = try XCTUnwrap(scheduler.activeEntries.first)

        clock.advance(by: 2)
        firstRecovery.action()

        XCTAssertEqual(manager.health, .unavailable(message: "Не удалось сохранить список загрузок"))
        XCTAssertTrue(transport.startCalls.isEmpty)
        let secondRecovery = try XCTUnwrap(scheduler.activeEntries.first)
        XCTAssertEqual(secondRecovery.date, date(1_004))

        clock.advance(by: 2)
        secondRecovery.action()

        XCTAssertEqual(manager.health, .available)
        XCTAssertEqual(manager.downloads.first?.phase, .downloading)
        XCTAssertEqual(transport.startedIDs, [queued.id])
        XCTAssertEqual(persistence.loadCount, 1)
        XCTAssertEqual(transport.restoredValues, [[]])
        XCTAssertTrue(scheduler.activeEntries.isEmpty)
    }

    func testEnqueueSaveFailureDoesNotPublishRecordOrStartTransport() throws {
        let manager = makeManager()
        try manager.start()
        persistence.saveError = TestFailure.failed

        XCTAssertThrowsError(try manager.enqueue("https://example.com/archive.zip")) { error in
            XCTAssertEqual(error as? DownloadManagerError, .persistenceFailed)
        }

        XCTAssertTrue(manager.downloads.isEmpty)
        XCTAssertTrue(transport.startCalls.isEmpty)
        XCTAssertEqual(
            manager.health,
            .unavailable(message: "Не удалось сохранить список загрузок")
        )
    }

    func testStartReportsQueuedDrainSaveFailureWithoutStartingTransport() {
        let queued = download(id: id(1), phase: .queued)
        persistence = MemoryDownloadPersistence([queued])
        persistence.saveError = TestFailure.failed
        let manager = makeManager()

        XCTAssertThrowsError(try manager.start()) { error in
            XCTAssertEqual(error as? DownloadManagerError, .persistenceFailed)
        }

        XCTAssertEqual(manager.downloads, [queued])
        XCTAssertTrue(transport.startCalls.isEmpty)
        XCTAssertNotNil(transport.eventHandler)
        XCTAssertEqual(
            manager.health,
            .unavailable(message: "Не удалось сохранить список загрузок")
        )
    }

    func testRepeatedStartRetriesIncompleteDrainWithoutReloadRestoreOrDuplicateStart() throws {
        let queued = download(id: id(1), phase: .queued)
        persistence = MemoryDownloadPersistence([queued])
        persistence.saveError = TestFailure.failed
        let manager = makeManager()

        XCTAssertThrowsError(try manager.start())
        XCTAssertEqual(persistence.loadCount, 1)
        XCTAssertEqual(transport.restoredValues, [[]])
        XCTAssertTrue(transport.startCalls.isEmpty)

        persistence.saveError = nil
        try manager.start()
        try manager.start()

        XCTAssertEqual(manager.downloads.first?.phase, .downloading)
        XCTAssertEqual(persistence.loadCount, 1)
        XCTAssertEqual(transport.restoredValues, [[]])
        XCTAssertEqual(transport.startedIDs, [queued.id])
    }

    func testPauseFlushesBeforeTransportAndWaitsForConfirmationResumeData() throws {
        var timeline: [String] = []
        persistence.onSave = { _ in timeline.append("save") }
        transport.onPause = { _ in timeline.append("pause") }
        let manager = makeManager()
        try manager.start()
        let id = try manager.enqueue("https://example.com/archive.zip")
        timeline.removeAll()

        manager.pause(id)
        manager.pause(id)

        XCTAssertEqual(manager.downloads.first?.phase, .downloading)
        XCTAssertEqual(transport.pausedIDs, [id])
        XCTAssertEqual(timeline, ["save", "pause"])

        transport.send(.paused(id: id, resumeData: Data([1, 2, 3])))
        XCTAssertEqual(manager.downloads.first?.phase, .paused)
        XCTAssertEqual(manager.downloads.first?.resumeData, Data([1, 2, 3]))
        XCTAssertNil(manager.downloads.first?.taskIdentifier)
    }

    func testPausedConfirmationOneShotSaveFailureRetriesWithoutSecondPauseCall() throws {
        let active = download(id: id(1), phase: .downloading)
        let queued = download(id: id(2), phase: .queued)
        persistence = MemoryDownloadPersistence([active, queued])
        let manager = makeManager(maxConcurrent: 1)
        try manager.start()
        manager.pause(active.id)
        persistence.saveError = TestFailure.failed

        transport.send(.paused(id: active.id, resumeData: Data([1, 2, 3])))

        XCTAssertEqual(manager.downloads.first?.phase, .downloading)
        XCTAssertEqual(transport.pausedIDs, [active.id])
        let retry = try XCTUnwrap(scheduler.activeEntries.first)
        XCTAssertEqual(retry.date, date(1_002))

        persistence.saveError = nil
        clock.advance(by: 2)
        retry.action()

        XCTAssertEqual(manager.downloads.first { $0.id == active.id }?.phase, .paused)
        XCTAssertEqual(manager.downloads.first { $0.id == active.id }?.resumeData, Data([1, 2, 3]))
        XCTAssertEqual(manager.downloads.first { $0.id == queued.id }?.phase, .downloading)
        XCTAssertEqual(transport.pausedIDs, [active.id])
        XCTAssertEqual(transport.startedIDs, [queued.id])
        XCTAssertTrue(scheduler.activeEntries.isEmpty)
    }

    func testFinishBeforePauseConfirmationKeepsPendingFinalizationAndIgnoresLatePaused() throws {
        let manager = makeManager()
        try manager.start()
        let id = try manager.enqueue("https://example.com/pause-race.zip")
        manager.pause(id)
        persistence.saveError = TestFailure.failed
        let temporaryURL = URL(fileURLWithPath: "/tmp/pause-race")

        transport.send(.finished(
            id: id,
            temporaryURL: temporaryURL,
            suggestedFilename: "pause-race.zip"
        ))
        transport.send(.paused(id: id, resumeData: Data([1, 2, 3])))

        XCTAssertEqual(files.moves.count, 1)
        XCTAssertEqual(manager.downloads.first?.phase, .downloading)
        XCTAssertEqual(scheduler.activeEntries.count, 1)

        persistence.saveError = nil
        let retry = try XCTUnwrap(scheduler.activeEntries.first)
        clock.advance(by: 2)
        retry.action()

        XCTAssertEqual(manager.downloads.first?.phase, .completed)
        XCTAssertEqual(manager.downloads.first?.destinationURL?.lastPathComponent, "pause-race.zip")
        XCTAssertEqual(files.moves.count, 1)
        XCTAssertTrue(scheduler.activeEntries.isEmpty)
    }

    func testPauseConfirmationBeforeFinishKeepsPausedAndDoesNotMoveLateFile() throws {
        let manager = makeManager()
        try manager.start()
        let id = try manager.enqueue("https://example.com/pause-first.zip")
        manager.pause(id)

        transport.send(.paused(id: id, resumeData: Data([8])))
        transport.send(.finished(
            id: id,
            temporaryURL: URL(fileURLWithPath: "/tmp/pause-first"),
            suggestedFilename: "pause-first.zip"
        ))

        XCTAssertEqual(manager.downloads.first?.phase, .paused)
        XCTAssertEqual(manager.downloads.first?.resumeData, Data([8]))
        XCTAssertTrue(files.moves.isEmpty)
    }

    func testResumePersistsQueuedThenStartsWithPreservedResumeData() throws {
        let paused = download(id: id(1), phase: .paused, resumeData: Data([7, 8]))
        persistence = MemoryDownloadPersistence([paused])
        var timeline: [String] = []
        persistence.onSave = { records in
            timeline.append("save:\(records[0].phase.rawValue)")
        }
        transport.onStart = { _ in timeline.append("start") }
        let manager = makeManager()
        try manager.start()
        timeline.removeAll()

        manager.resume(paused.id)

        XCTAssertEqual(transport.startCalls.first?.resumeData, Data([7, 8]))
        XCTAssertEqual(manager.downloads.first?.phase, .downloading)
        XCTAssertEqual(timeline, ["save:queued", "save:downloading", "start"])
    }

    func testCancelPersistsCancelledBeforeTransportAndOnlyConfirmationRemovesRecord() throws {
        let paused = download(id: id(1), phase: .paused)
        let failed = download(
            id: id(2),
            phase: .failed,
            failure: .init(code: "network", message: "Ошибка")
        )
        persistence = MemoryDownloadPersistence([paused, failed])
        var timeline: [String] = []
        persistence.onSave = { records in
            let phase = records.first { $0.id == paused.id }?.phase.rawValue ?? "removed"
            timeline.append("save:\(phase)")
        }
        transport.onCancel = { _ in timeline.append("cancel") }
        let manager = makeManager()
        try manager.start()

        manager.cancel(paused.id)
        manager.cancel(paused.id)

        XCTAssertEqual(manager.downloads.first { $0.id == paused.id }?.phase, .cancelled)
        XCTAssertEqual(transport.cancelledIDs, [paused.id])
        XCTAssertEqual(timeline, ["save:cancelled", "cancel"])

        transport.send(.cancelled(id: paused.id))
        XCTAssertNil(manager.downloads.first { $0.id == paused.id })
        XCTAssertEqual(timeline.last, "save:removed")
    }

    func testCancelIgnoresEarlyFinishAndRetriesCancelledConfirmationWithoutMovingFile() throws {
        let active = download(id: id(1), phase: .downloading)
        let queued = download(id: id(2), phase: .queued)
        persistence = MemoryDownloadPersistence([active, queued])
        let manager = makeManager(maxConcurrent: 1)
        try manager.start()
        manager.cancel(active.id)
        persistence.saveError = TestFailure.failed

        transport.send(.finished(
            id: active.id,
            temporaryURL: URL(fileURLWithPath: "/tmp/cancel-race"),
            suggestedFilename: "cancel-race.zip"
        ))
        transport.send(.cancelled(id: active.id))

        XCTAssertTrue(files.moves.isEmpty)
        XCTAssertEqual(manager.downloads.first { $0.id == active.id }?.phase, .cancelled)
        XCTAssertTrue(transport.startCalls.isEmpty)
        let retry = try XCTUnwrap(scheduler.activeEntries.first)

        persistence.saveError = nil
        clock.advance(by: 2)
        retry.action()

        XCTAssertNil(manager.downloads.first { $0.id == active.id })
        XCTAssertEqual(manager.downloads.first { $0.id == queued.id }?.phase, .downloading)
        XCTAssertEqual(transport.startedIDs, [queued.id])
        XCTAssertTrue(files.moves.isEmpty)
    }

    func testEveryCancellablePhaseUsesExplicitConfirmationAndQueuedSlotDrainsAfterRemoval() throws {
        let downloading = download(id: id(1), phase: .downloading)
        let queued = download(id: id(2), phase: .queued)
        let paused = download(id: id(3), phase: .paused)
        let failed = download(id: id(4), phase: .failed, failure: .init(code: "x", message: "Ошибка"))
        persistence = MemoryDownloadPersistence([downloading, queued, paused, failed])
        let manager = makeManager(maxConcurrent: 1)
        try manager.start()

        for id in [downloading.id, queued.id, paused.id, failed.id] {
            manager.cancel(id)
            XCTAssertEqual(manager.downloads.first { $0.id == id }?.phase, .cancelled)
            transport.send(.cancelled(id: id))
            XCTAssertNil(manager.downloads.first { $0.id == id })
        }
        XCTAssertEqual(transport.cancelledIDs, [downloading.id, queued.id, paused.id, failed.id])
    }

    func testQueuedCancellationStillWaitsForTransportConfirmation() throws {
        let active = (1 ... 3).map { download(id: id($0), phase: .downloading) }
        let queued = download(id: id(4), phase: .queued)
        persistence = MemoryDownloadPersistence(active + [queued])
        let manager = makeManager()
        try manager.start()

        manager.cancel(queued.id)

        XCTAssertEqual(manager.downloads.last?.phase, .cancelled)
        XCTAssertEqual(transport.cancelledIDs, [queued.id])
        transport.send(.cancelled(id: queued.id))
        XCTAssertNil(manager.downloads.first { $0.id == queued.id })
    }

    func testRetryClearsFailureProgressTaskAndCompletionButPreservesOnlyUsableResumeData() throws {
        let failed = download(
            id: id(1),
            phase: .failed,
            destinationURL: URL(fileURLWithPath: "/Downloads/old.zip"),
            taskIdentifier: 88,
            resumeData: Data([9]),
            bytesReceived: 500,
            totalBytes: 1_000,
            completedAt: 900,
            failure: .init(code: "network", message: "Ошибка")
        )
        persistence = MemoryDownloadPersistence([failed])
        let manager = makeManager()
        try manager.start()

        manager.retry(failed.id)

        let updated = try XCTUnwrap(manager.downloads.first)
        XCTAssertEqual(updated.phase, .downloading)
        XCTAssertNil(updated.failure)
        XCTAssertEqual(updated.bytesReceived, 0)
        XCTAssertNil(updated.totalBytes)
        XCTAssertNil(updated.taskIdentifier)
        XCTAssertNil(updated.completedAt)
        XCTAssertNil(updated.destinationURL)
        XCTAssertEqual(transport.startCalls.first?.resumeData, Data([9]))
    }

    func testUnknownAndInvalidActionsHaveNoPersistenceOrExternalEffects() throws {
        let completed = download(
            id: id(1),
            phase: .completed,
            destinationURL: URL(fileURLWithPath: "/Downloads/done.zip"),
            completedAt: 900
        )
        persistence = MemoryDownloadPersistence([completed])
        let manager = makeManager()
        try manager.start()
        let saveCount = persistence.saveCount

        manager.pause(completed.id)
        manager.resume(completed.id)
        manager.cancel(completed.id)
        manager.retry(completed.id)
        manager.pause(id(99))
        manager.dismiss(id(99))
        manager.open(id(99))
        manager.reveal(id(99))

        XCTAssertEqual(persistence.saveCount, saveCount)
        XCTAssertTrue(transport.pausedIDs.isEmpty)
        XCTAssertTrue(transport.cancelledIDs.isEmpty)
        XCTAssertTrue(opened.isEmpty)
        XCTAssertTrue(revealed.isEmpty)
        XCTAssertEqual(manager.downloads, [completed])
    }

    func testProgressPublishesImmediatelyNormalizesValuesAndThrottlesGloballyAtTwoSeconds() throws {
        let first = download(id: id(1), phase: .downloading)
        let second = download(id: id(2), phase: .downloading)
        persistence = MemoryDownloadPersistence([first, second])
        let manager = makeManager()
        try manager.start()
        let initialSaves = persistence.saveCount

        transport.send(.progress(id: first.id, received: -10, expected: -1))
        XCTAssertEqual(manager.downloads[0].bytesReceived, 0)
        XCTAssertNil(manager.downloads[0].totalBytes)
        XCTAssertEqual(persistence.saveCount, initialSaves + 1)

        clock.advance(by: 1.999)
        transport.send(.progress(id: second.id, received: 25, expected: 100))
        XCTAssertEqual(manager.downloads[1].progress, 0.25)
        XCTAssertEqual(persistence.saveCount, initialSaves + 1)

        clock.advance(by: 0.001)
        transport.send(.progress(id: first.id, received: 50, expected: 100))
        XCTAssertEqual(persistence.saveCount, initialSaves + 2)
        XCTAssertEqual(persistence.stored.map(\.bytesReceived), [50, 25])
    }

    func testProgressSaveFailureMayStayTransientAndFailureEventFlushesLatestValues() throws {
        let active = download(id: id(1), phase: .downloading)
        persistence = MemoryDownloadPersistence([active])
        let manager = makeManager()
        try manager.start()
        persistence.saveError = TestFailure.failed

        transport.send(.progress(id: active.id, received: 40, expected: 100))

        XCTAssertEqual(manager.downloads.first?.bytesReceived, 40)
        XCTAssertEqual(persistence.stored.first?.bytesReceived, 0)
        XCTAssertEqual(
            manager.health,
            .unavailable(message: "Не удалось сохранить список загрузок")
        )

        persistence.saveError = nil
        transport.send(.failed(
            id: active.id,
            code: "task-lost",
            message: "Фоновая задача не найдена",
            resumeData: Data([4])
        ))
        XCTAssertEqual(persistence.stored.first?.phase, .failed)
        XCTAssertEqual(persistence.stored.first?.bytesReceived, 40)
        XCTAssertEqual(persistence.stored.first?.failure?.code, "task-lost")
    }

    func testFailedProgressAttemptsAreThrottledButTerminalFlushRemainsImmediate() throws {
        let active = download(id: id(1), phase: .downloading)
        persistence = MemoryDownloadPersistence([active])
        let manager = makeManager()
        try manager.start()
        persistence.saveError = TestFailure.failed
        let initialSaveCount = persistence.saveCount

        transport.send(.progress(id: active.id, received: 10, expected: 100))
        transport.send(.progress(id: active.id, received: 20, expected: 100))
        clock.advance(by: 1.999)
        transport.send(.progress(id: active.id, received: 30, expected: 100))

        XCTAssertEqual(manager.downloads.first?.bytesReceived, 30)
        XCTAssertEqual(persistence.saveCount, initialSaveCount + 1)

        clock.advance(by: 0.001)
        transport.send(.progress(id: active.id, received: 40, expected: 100))
        XCTAssertEqual(persistence.saveCount, initialSaveCount + 2)

        persistence.saveError = nil
        transport.send(.failed(
            id: active.id,
            code: "network",
            message: "Ошибка сети",
            resumeData: nil
        ))

        XCTAssertEqual(persistence.saveCount, initialSaveCount + 3)
        XCTAssertEqual(manager.downloads.first?.phase, .failed)
        XCTAssertEqual(persistence.stored.first?.bytesReceived, 40)
    }

    func testPauseFailAndStopFlushProgressOutsideThrottleWindow() throws {
        let first = download(id: id(1), phase: .downloading)
        let second = download(id: id(2), phase: .downloading)
        persistence = MemoryDownloadPersistence([first, second])
        let manager = makeManager()
        try manager.start()

        transport.send(.progress(id: first.id, received: 10, expected: 100))
        transport.send(.progress(id: second.id, received: 20, expected: 100))
        let afterProgress = persistence.saveCount
        manager.pause(second.id)
        XCTAssertEqual(persistence.saveCount, afterProgress + 1)
        XCTAssertEqual(persistence.stored[1].bytesReceived, 20)

        transport.send(.failed(id: first.id, code: "network", message: "Ошибка сети", resumeData: nil))
        let afterFailure = persistence.saveCount
        manager.stop()
        XCTAssertEqual(persistence.saveCount, afterFailure + 1)
    }

    func testRestoreTaskLostFailureIsPersistedAndDrainsQueuedRecord() throws {
        let lost = download(id: id(1), phase: .downloading, taskIdentifier: 77)
        let queued = download(id: id(2), phase: .queued)
        persistence = MemoryDownloadPersistence([lost, queued])
        transport.onRestore = { [weak transport] records in
            transport?.send(.failed(
                id: records[0].id,
                code: "task-lost",
                message: "Фоновая задача не найдена",
                resumeData: nil
            ))
        }
        let manager = makeManager(maxConcurrent: 1)

        try manager.start()

        XCTAssertEqual(manager.downloads.first { $0.id == lost.id }?.failure?.code, "task-lost")
        XCTAssertEqual(manager.downloads.first { $0.id == queued.id }?.phase, .downloading)
        XCTAssertEqual(transport.startedIDs, [queued.id])
    }

    func testRestoreReplacesStalePersistedTaskIdentifierButLateDuplicateCannotReplaceActual() throws {
        let active = download(id: id(1), phase: .downloading, taskIdentifier: 999)
        persistence = MemoryDownloadPersistence([active])
        transport.onRestore = { [weak transport] records in
            transport?.send(.started(id: records[0].id, taskIdentifier: 7))
        }
        let manager = makeManager()

        try manager.start()

        XCTAssertEqual(manager.downloads.first?.taskIdentifier, 7)
        XCTAssertEqual(persistence.stored.first?.taskIdentifier, 7)
        XCTAssertEqual(persistence.loadCount, 1)
        XCTAssertEqual(transport.restoredValues, [[active]])
        let saveCountAfterRestore = persistence.saveCount

        transport.send(.started(id: active.id, taskIdentifier: 8))

        XCTAssertEqual(manager.downloads.first?.taskIdentifier, 7)
        XCTAssertEqual(persistence.stored.first?.taskIdentifier, 7)
        XCTAssertEqual(persistence.saveCount, saveCountAfterRestore)
        XCTAssertEqual(persistence.loadCount, 1)
        XCTAssertEqual(transport.restoredValues, [[active]])
    }

    func testFailedEventOneShotSaveFailureRetriesAndDrainsWithoutTransportReplay() throws {
        let active = download(id: id(1), phase: .downloading)
        let queued = download(id: id(2), phase: .queued)
        persistence = MemoryDownloadPersistence([active, queued])
        let manager = makeManager(maxConcurrent: 1)
        try manager.start()
        persistence.saveError = TestFailure.failed

        transport.send(.failed(
            id: active.id,
            code: "network",
            message: "Ошибка сети",
            resumeData: Data([9])
        ))

        XCTAssertEqual(manager.downloads.first?.phase, .downloading)
        XCTAssertTrue(transport.startCalls.isEmpty)
        let retry = try XCTUnwrap(scheduler.activeEntries.first)

        persistence.saveError = nil
        clock.advance(by: 2)
        retry.action()

        XCTAssertEqual(manager.downloads.first { $0.id == active.id }?.phase, .failed)
        XCTAssertEqual(manager.downloads.first { $0.id == active.id }?.resumeData, Data([9]))
        XCTAssertEqual(manager.downloads.first { $0.id == queued.id }?.phase, .downloading)
        XCTAssertEqual(transport.startedIDs, [queued.id])
        XCTAssertTrue(scheduler.activeEntries.isEmpty)
    }

    func testRepeatedTerminalSaveFailureReschedulesAtTwoSecondIntervals() throws {
        let active = download(id: id(1), phase: .downloading)
        persistence = MemoryDownloadPersistence([active])
        let manager = makeManager()
        try manager.start()
        persistence.saveError = TestFailure.failed

        transport.send(.failed(
            id: active.id,
            code: "network",
            message: "Ошибка сети",
            resumeData: nil
        ))
        let firstRetry = try XCTUnwrap(scheduler.activeEntries.first)
        XCTAssertEqual(firstRetry.date, date(1_002))

        clock.advance(by: 2)
        firstRetry.action()
        let secondRetry = try XCTUnwrap(scheduler.activeEntries.first)
        XCTAssertEqual(secondRetry.date, date(1_004))
        XCTAssertEqual(manager.downloads.first?.phase, .downloading)

        persistence.saveError = nil
        clock.advance(by: 2)
        secondRetry.action()

        XCTAssertEqual(manager.downloads.first?.phase, .failed)
        XCTAssertTrue(scheduler.activeEntries.isEmpty)
    }

    func testSuccessfulCancelSupersedesPendingFailureAndStaleWakeCannotOverwriteIt() throws {
        let active = download(id: id(1), phase: .downloading)
        persistence = MemoryDownloadPersistence([active])
        let manager = makeManager()
        try manager.start()
        persistence.saveError = TestFailure.failed
        transport.send(.failed(
            id: active.id,
            code: "network",
            message: "Ошибка сети",
            resumeData: nil
        ))
        let staleRetry = try XCTUnwrap(scheduler.activeEntries.first)

        persistence.saveError = nil
        manager.cancel(active.id)

        XCTAssertEqual(manager.downloads.first?.phase, .cancelled)
        XCTAssertEqual(transport.cancelledIDs, [active.id])
        XCTAssertTrue(scheduler.activeEntries.isEmpty)

        clock.advance(by: 2)
        staleRetry.action()

        XCTAssertEqual(manager.downloads.first?.phase, .cancelled)
        XCTAssertEqual(persistence.stored.first?.phase, .cancelled)
        XCTAssertNil(manager.downloads.first?.failure)
    }

    func testStopFlushesPendingFailureAndCancelsRetryWakeWithoutStartingQueue() throws {
        let active = download(id: id(1), phase: .downloading)
        let queued = download(id: id(2), phase: .queued)
        persistence = MemoryDownloadPersistence([active, queued])
        let manager = makeManager(maxConcurrent: 1)
        try manager.start()
        persistence.saveError = TestFailure.failed
        transport.send(.failed(
            id: active.id,
            code: "network",
            message: "Ошибка сети",
            resumeData: nil
        ))
        XCTAssertEqual(scheduler.activeEntries.count, 1)

        persistence.saveError = nil
        manager.stop()

        XCTAssertEqual(manager.downloads.first { $0.id == active.id }?.phase, .failed)
        XCTAssertEqual(manager.downloads.first { $0.id == queued.id }?.phase, .queued)
        XCTAssertTrue(transport.startCalls.isEmpty)
        XCTAssertTrue(scheduler.activeEntries.isEmpty)
        XCTAssertNil(transport.eventHandler)
    }

    func testRepeatedStartContinuesPreRestoreReconciliationExactlyOnce() throws {
        let terminal = download(id: id(1), phase: .downloading)
        let remaining = download(id: id(2), phase: .downloading)
        let queued = download(id: id(3), phase: .queued)
        persistence = MemoryDownloadPersistence([terminal, remaining, queued])
        let manager = makeManager(maxConcurrent: 2)
        try manager.start()
        persistence.saveError = TestFailure.failed
        transport.send(.failed(
            id: terminal.id,
            code: "network",
            message: "Ошибка сети",
            resumeData: nil
        ))
        manager.stop()
        let loadCountBeforeColdStart = persistence.loadCount
        let restoreCountBeforeColdStart = transport.restoredValues.count

        XCTAssertThrowsError(try manager.start())
        XCTAssertEqual(persistence.loadCount - loadCountBeforeColdStart, 1)
        XCTAssertEqual(transport.restoredValues.count - restoreCountBeforeColdStart, 0)
        XCTAssertTrue(transport.startCalls.isEmpty)

        persistence.saveError = nil
        try manager.start()
        try manager.start()

        XCTAssertEqual(persistence.loadCount - loadCountBeforeColdStart, 1)
        XCTAssertEqual(transport.restoredValues.count - restoreCountBeforeColdStart, 1)
        XCTAssertEqual(transport.restoredValues.last?.map(\.id), [remaining.id])
        XCTAssertEqual(transport.startedIDs, [queued.id])
        XCTAssertEqual(manager.downloads.first { $0.id == terminal.id }?.phase, .failed)
        XCTAssertEqual(manager.downloads.first { $0.id == queued.id }?.phase, .downloading)
        XCTAssertTrue(scheduler.activeEntries.isEmpty)
    }

    func testScheduledRecoveryContinuesPreRestoreReconciliationExactlyOnce() throws {
        let terminal = download(id: id(1), phase: .downloading)
        let remaining = download(id: id(2), phase: .downloading)
        let queued = download(id: id(3), phase: .queued)
        persistence = MemoryDownloadPersistence([terminal, remaining, queued])
        let manager = makeManager(maxConcurrent: 2)
        try manager.start()
        persistence.saveError = TestFailure.failed
        transport.send(.failed(
            id: terminal.id,
            code: "network",
            message: "Ошибка сети",
            resumeData: nil
        ))
        manager.stop()
        let loadCountBeforeColdStart = persistence.loadCount
        let restoreCountBeforeColdStart = transport.restoredValues.count

        XCTAssertThrowsError(try manager.start())
        let recovery = try XCTUnwrap(scheduler.activeEntries.first)
        persistence.saveError = nil
        clock.advance(by: 2)
        recovery.action()
        try manager.start()

        XCTAssertEqual(persistence.loadCount - loadCountBeforeColdStart, 1)
        XCTAssertEqual(transport.restoredValues.count - restoreCountBeforeColdStart, 1)
        XCTAssertEqual(transport.restoredValues.last?.map(\.id), [remaining.id])
        XCTAssertEqual(transport.startedIDs, [queued.id])
        XCTAssertEqual(manager.downloads.first { $0.id == terminal.id }?.phase, .failed)
        XCTAssertEqual(manager.downloads.first { $0.id == queued.id }?.phase, .downloading)
        XCTAssertTrue(scheduler.activeEntries.isEmpty)
    }

    func testScheduledContinuationPersistsLatestSynchronousRestoreProgressFailure() throws {
        let active = download(id: id(1), phase: .downloading)
        persistence = MemoryDownloadPersistence([active])
        transport.onRestore = { [weak transport] records in
            let id = records[0].id
            transport?.send(.progress(id: id, received: 10, expected: 100))
            transport?.send(.progress(id: id, received: 40, expected: 100))
        }
        let manager = makeManager()
        persistence.saveError = TestFailure.failed

        XCTAssertThrowsError(try manager.start())

        XCTAssertEqual(manager.downloads.first?.bytesReceived, 40)
        XCTAssertEqual(persistence.stored.first?.bytesReceived, 0)
        XCTAssertEqual(persistence.loadCount, 1)
        XCTAssertEqual(transport.restoredValues.count, 1)
        XCTAssertTrue(transport.startCalls.isEmpty)
        let recovery = try XCTUnwrap(scheduler.activeEntries.first)

        persistence.saveError = nil
        clock.advance(by: 2)
        recovery.action()
        try manager.start()

        XCTAssertEqual(manager.health, .available)
        XCTAssertEqual(manager.downloads.first?.bytesReceived, 40)
        XCTAssertEqual(manager.downloads.first?.totalBytes, 100)
        XCTAssertEqual(persistence.stored.first?.bytesReceived, 40)
        XCTAssertEqual(persistence.loadCount, 1)
        XCTAssertEqual(transport.restoredValues.count, 1)
        XCTAssertTrue(transport.startCalls.isEmpty)
        XCTAssertTrue(scheduler.activeEntries.isEmpty)
    }

    func testRepeatedContinuationPersistsSynchronousRestoreStartedFailure() throws {
        let active = download(id: id(1), phase: .downloading)
        persistence = MemoryDownloadPersistence([active])
        transport.onRestore = { [weak transport] records in
            transport?.send(.started(id: records[0].id, taskIdentifier: 73))
        }
        let manager = makeManager()
        persistence.saveError = TestFailure.failed

        XCTAssertThrowsError(try manager.start())

        XCTAssertNil(manager.downloads.first?.taskIdentifier)
        XCTAssertNil(persistence.stored.first?.taskIdentifier)
        XCTAssertEqual(persistence.loadCount, 1)
        XCTAssertEqual(transport.restoredValues.count, 1)
        XCTAssertTrue(transport.startCalls.isEmpty)
        XCTAssertEqual(scheduler.activeEntries.count, 1)

        persistence.saveError = nil
        try manager.start()
        try manager.start()

        XCTAssertEqual(manager.health, .available)
        XCTAssertEqual(manager.downloads.first?.taskIdentifier, 73)
        XCTAssertEqual(persistence.stored.first?.taskIdentifier, 73)
        XCTAssertEqual(persistence.loadCount, 1)
        XCTAssertEqual(transport.restoredValues.count, 1)
        XCTAssertTrue(transport.startCalls.isEmpty)
        XCTAssertTrue(scheduler.activeEntries.isEmpty)
    }

    func testRecoveredStartMergesStartedCandidateWithoutClobberingFreshProgress() throws {
        let active = download(id: id(1), phase: .downloading)
        persistence = MemoryDownloadPersistence([active])
        let manager = makeManager()
        try manager.start()
        persistence.saveError = TestFailure.failed
        transport.send(.started(id: active.id, taskIdentifier: 73))
        manager.stop()

        persistence.stored[0].bytesReceived = 75
        persistence.stored[0].totalBytes = 100
        persistence.saveError = nil
        try manager.start()

        XCTAssertEqual(manager.downloads.first?.taskIdentifier, 73)
        XCTAssertEqual(manager.downloads.first?.bytesReceived, 75)
        XCTAssertEqual(manager.downloads.first?.totalBytes, 100)
        XCTAssertEqual(persistence.stored, manager.downloads)
        XCTAssertEqual(transport.restoredValues.last?.first?.taskIdentifier, 73)
        XCTAssertEqual(transport.restoredValues.last?.first?.bytesReceived, 75)
        XCTAssertTrue(scheduler.activeEntries.isEmpty)
    }

    func testPublicActionsStaySideEffectFreeUntilRestoreCompletesThenBecomeReady() throws {
        let active = download(id: id(1), phase: .downloading)
        let paused = download(id: id(2), phase: .paused, resumeData: Data([2]))
        let failed = download(
            id: id(3),
            phase: .failed,
            resumeData: Data([3]),
            failure: .init(code: "network", message: "Ошибка сети")
        )
        let completedURL = URL(fileURLWithPath: "/Downloads/completed.zip")
        let completed = download(
            id: id(4),
            phase: .completed,
            destinationURL: completedURL,
            completedAt: 900
        )
        persistence = MemoryDownloadPersistence([active, paused, failed, completed])
        let manager = makeManager()
        try manager.start()
        persistence.saveError = TestFailure.failed
        transport.send(.failed(
            id: active.id,
            code: "network",
            message: "Ошибка сети",
            resumeData: nil
        ))
        manager.stop()

        var recoveryTimeline: [String] = []
        transport.onRestore = { _ in recoveryTimeline.append("restore") }
        transport.onStart = { _ in recoveryTimeline.append("start") }
        XCTAssertThrowsError(try manager.start())
        persistence.saveError = nil
        let recordsBeforeActions = manager.downloads
        let saveCountBeforeActions = persistence.saveCount
        let restoreCountBeforeActions = transport.restoredValues.count
        let startCountBeforeActions = transport.startCalls.count

        XCTAssertThrowsError(try manager.enqueue("https://example.com/new.zip")) { error in
            XCTAssertEqual(error as? DownloadManagerError, .persistenceFailed)
        }
        manager.pause(active.id)
        manager.cancel(active.id)
        manager.resume(paused.id)
        manager.retry(failed.id)
        manager.open(completed.id)
        manager.reveal(completed.id)
        manager.dismiss(completed.id)

        XCTAssertEqual(manager.downloads, recordsBeforeActions)
        XCTAssertEqual(persistence.saveCount, saveCountBeforeActions)
        XCTAssertEqual(transport.restoredValues.count, restoreCountBeforeActions)
        XCTAssertEqual(transport.startCalls.count, startCountBeforeActions)
        XCTAssertTrue(transport.pausedIDs.isEmpty)
        XCTAssertTrue(transport.cancelledIDs.isEmpty)
        XCTAssertTrue(opened.isEmpty)
        XCTAssertTrue(revealed.isEmpty)
        XCTAssertTrue(files.createdDirectories.isEmpty)
        XCTAssertTrue(files.moves.isEmpty)
        XCTAssertTrue(recoveryTimeline.isEmpty)

        try manager.start()
        _ = try manager.enqueue("https://example.com/after-recovery.zip")
        manager.open(completed.id)
        manager.reveal(completed.id)

        XCTAssertEqual(persistence.loadCount, 2)
        XCTAssertEqual(transport.restoredValues.count, restoreCountBeforeActions + 1)
        XCTAssertEqual(transport.restoredValues.last, [])
        XCTAssertEqual(transport.startCalls.count, startCountBeforeActions + 1)
        XCTAssertEqual(recoveryTimeline, ["restore", "start"])
        XCTAssertEqual(opened, [completedURL])
        XCTAssertEqual(revealed, [completedURL])
        XCTAssertTrue(scheduler.activeEntries.isEmpty)
    }

    func testFinishUsesCurrentFolderCreatesUniqueDestinationAndPublishesAfterPersistedCompletion() throws {
        settings.downloadsFolder = URL(fileURLWithPath: "/Downloads/old", isDirectory: true)
        let manager = makeManager()
        try manager.start()
        let id = try manager.enqueue("https://example.com/archive.zip")
        settings.downloadsFolder = URL(fileURLWithPath: "/Downloads/new", isDirectory: true)
        files.existingPaths = ["/Downloads/new/archive.zip"]
        var timeline: [String] = []
        persistence.onSave = { records in
            if records.first?.phase == .completed { timeline.append("save") }
        }
        var completions: [OwnDownloadCompletion] = []
        let observation = manager.ownCompletionPublisher.sink {
            timeline.append("completion")
            completions.append($0)
        }
        let temporaryURL = URL(fileURLWithPath: "/tmp/transfer")

        transport.send(.finished(
            id: id,
            temporaryURL: temporaryURL,
            suggestedFilename: "archive.zip"
        ))

        let record = try XCTUnwrap(manager.downloads.first)
        let destination = URL(fileURLWithPath: "/Downloads/new/archive (2).zip")
        XCTAssertEqual(files.createdDirectories, [settings.downloadsFolder])
        XCTAssertEqual(files.moves, [.init(source: temporaryURL, destination: destination)])
        XCTAssertEqual(record.phase, .completed)
        XCTAssertEqual(record.displayName, "archive (2).zip")
        XCTAssertEqual(record.destinationURL, destination)
        XCTAssertEqual(record.progress, 1)
        XCTAssertEqual(record.completedAt, date(1_000))
        XCTAssertEqual(persistence.stored, manager.downloads)
        XCTAssertEqual(completions, [.init(fileURL: destination, occurredAt: date(1_000))])
        XCTAssertEqual(timeline, ["save", "completion"])

        transport.send(.finished(id: id, temporaryURL: temporaryURL, suggestedFilename: "archive.zip"))
        XCTAssertEqual(files.moves.count, 1)
        XCTAssertEqual(completions.count, 1)
        withExtendedLifetime(observation) {}
    }

    func testDestinationFailureBecomesRetryableFailureWithoutMovingOrCompletion() throws {
        files.createError = TestFailure.failed
        let manager = makeManager()
        try manager.start()
        let id = try manager.enqueue("https://example.com/archive.zip")
        var completions: [OwnDownloadCompletion] = []
        let observation = manager.ownCompletionPublisher.sink { completions.append($0) }

        transport.send(.finished(
            id: id,
            temporaryURL: URL(fileURLWithPath: "/tmp/transfer"),
            suggestedFilename: "archive.zip"
        ))

        XCTAssertEqual(manager.downloads.first?.phase, .failed)
        XCTAssertEqual(manager.downloads.first?.failure?.code, "destination-write")
        XCTAssertEqual(
            manager.downloads.first?.failure?.message,
            "Не удалось сохранить файл в папку загрузок"
        )
        XCTAssertTrue(files.moves.isEmpty)
        XCTAssertTrue(completions.isEmpty)

        files.createError = nil
        manager.retry(id)
        XCTAssertEqual(manager.downloads.first?.phase, .downloading)
        withExtendedLifetime(observation) {}
    }

    func testMoveFailureBecomesDestinationWriteFailureAndKeepsRetryAvailable() throws {
        files.moveError = TestFailure.failed
        let manager = makeManager()
        try manager.start()
        let id = try manager.enqueue("https://example.com/archive.zip")
        let temporaryURL = URL(fileURLWithPath: "/tmp/transfer")

        transport.send(.finished(
            id: id,
            temporaryURL: temporaryURL,
            suggestedFilename: "archive.zip"
        ))

        XCTAssertEqual(files.moves.count, 1)
        XCTAssertEqual(manager.downloads.first?.phase, .failed)
        XCTAssertEqual(manager.downloads.first?.failure?.code, "destination-write")
        files.moveError = nil
        manager.retry(id)
        XCTAssertEqual(manager.downloads.first?.phase, .downloading)
    }

    func testDestinationFailureOneShotSaveFailureRetriesWithoutSecondFileOperation() throws {
        files.moveError = TestFailure.failed
        let manager = makeManager()
        try manager.start()
        let id = try manager.enqueue("https://example.com/archive.zip")
        persistence.saveError = TestFailure.failed

        transport.send(.finished(
            id: id,
            temporaryURL: URL(fileURLWithPath: "/tmp/transfer"),
            suggestedFilename: "archive.zip"
        ))

        XCTAssertEqual(manager.downloads.first?.phase, .downloading)
        XCTAssertEqual(files.createdDirectories.count, 1)
        XCTAssertEqual(files.moves.count, 1)
        let retry = try XCTUnwrap(scheduler.activeEntries.first)

        persistence.saveError = nil
        files.moveError = nil
        clock.advance(by: 2)
        retry.action()

        XCTAssertEqual(manager.downloads.first?.phase, .failed)
        XCTAssertEqual(manager.downloads.first?.failure?.code, "destination-write")
        XCTAssertEqual(files.createdDirectories.count, 1)
        XCTAssertEqual(files.moves.count, 1)
        XCTAssertEqual(transport.startCalls.count, 1)
        XCTAssertTrue(scheduler.activeEntries.isEmpty)
    }

    func testMetadataFailureAfterMoveKeepsPublishedStateUnchangedAndDuplicateFinishRetriesWithoutSecondMove() throws {
        let manager = makeManager()
        try manager.start()
        let id = try manager.enqueue("https://example.com/archive.zip")
        persistence.saveError = TestFailure.failed
        var completions: [OwnDownloadCompletion] = []
        let observation = manager.ownCompletionPublisher.sink { completions.append($0) }
        let temporaryURL = URL(fileURLWithPath: "/tmp/transfer")
        let event = DownloadTransportEvent.finished(
            id: id,
            temporaryURL: temporaryURL,
            suggestedFilename: "archive.zip"
        )

        transport.send(event)

        XCTAssertEqual(manager.downloads.first?.phase, .downloading)
        XCTAssertEqual(files.moves.count, 1)
        XCTAssertTrue(completions.isEmpty)
        XCTAssertEqual(
            manager.health,
            .unavailable(message: "Не удалось сохранить список загрузок")
        )

        persistence.saveError = nil
        transport.send(event)

        XCTAssertEqual(manager.downloads.first?.phase, .completed)
        XCTAssertEqual(files.moves.count, 1)
        XCTAssertEqual(completions.count, 1)
        transport.send(event)
        XCTAssertEqual(files.moves.count, 1)
        XCTAssertEqual(completions.count, 1)
        withExtendedLifetime(observation) {}
    }

    func testMetadataFailureAfterMoveAutomaticallyRetriesWithoutSecondMove() throws {
        let manager = makeManager()
        try manager.start()
        let id = try manager.enqueue("https://example.com/archive.zip")
        persistence.saveError = TestFailure.failed
        var completions: [OwnDownloadCompletion] = []
        let observation = manager.ownCompletionPublisher.sink { completions.append($0) }

        transport.send(.finished(
            id: id,
            temporaryURL: URL(fileURLWithPath: "/tmp/automatic-retry"),
            suggestedFilename: "archive.zip"
        ))

        XCTAssertEqual(manager.downloads.first?.phase, .downloading)
        XCTAssertEqual(files.moves.count, 1)
        XCTAssertTrue(completions.isEmpty)
        let retry = try XCTUnwrap(scheduler.activeEntries.first)
        XCTAssertEqual(retry.date, date(1_002))

        persistence.saveError = nil
        clock.advance(by: 2)
        retry.action()

        XCTAssertEqual(manager.downloads.first?.phase, .completed)
        XCTAssertEqual(files.moves.count, 1)
        XCTAssertEqual(completions.count, 1)
        XCTAssertTrue(scheduler.activeEntries.isEmpty)
        withExtendedLifetime(observation) {}
    }

    func testStopRetriesPendingFinalizationWithoutSecondMoveBeforeDetachingLifecycle() throws {
        let manager = makeManager()
        try manager.start()
        let id = try manager.enqueue("https://example.com/archive.zip")
        persistence.saveError = TestFailure.failed
        var completions: [OwnDownloadCompletion] = []
        let observation = manager.ownCompletionPublisher.sink { completions.append($0) }
        transport.send(.finished(
            id: id,
            temporaryURL: URL(fileURLWithPath: "/tmp/transfer"),
            suggestedFilename: "archive.zip"
        ))
        persistence.saveError = nil

        manager.stop()

        XCTAssertEqual(files.moves.count, 1)
        XCTAssertEqual(manager.downloads.first?.phase, .completed)
        XCTAssertEqual(persistence.stored.first?.phase, .completed)
        XCTAssertEqual(completions.count, 1)
        XCTAssertNil(transport.eventHandler)
        withExtendedLifetime(observation) {}
    }

    func testRecoveredStartMergesPendingTerminalAndMovedFinalizationBeforeRestore() throws {
        let terminal = download(id: id(1), phase: .downloading)
        let moved = download(id: id(2), phase: .downloading)
        let remaining = download(id: id(3), phase: .downloading, bytesReceived: 25, totalBytes: 100)
        persistence = MemoryDownloadPersistence([terminal, moved, remaining])
        let manager = makeManager()
        var completions: [OwnDownloadCompletion] = []
        let observation = manager.ownCompletionPublisher.sink { completions.append($0) }
        try manager.start()
        persistence.saveError = TestFailure.failed

        transport.send(.failed(
            id: terminal.id,
            code: "network",
            message: "Ошибка сети",
            resumeData: Data([7])
        ))
        transport.send(.finished(
            id: moved.id,
            temporaryURL: URL(fileURLWithPath: "/tmp/moved"),
            suggestedFilename: "moved.zip"
        ))

        XCTAssertEqual(files.moves.count, 1)
        XCTAssertTrue(completions.isEmpty)
        manager.stop()
        XCTAssertTrue(scheduler.activeEntries.isEmpty)

        persistence.saveError = nil
        persistence.stored[2].bytesReceived = 75
        try manager.start()
        try manager.start()

        let destination = URL(fileURLWithPath: "/Users/test/Downloads/moved.zip")
        XCTAssertEqual(manager.downloads.first { $0.id == terminal.id }?.phase, .failed)
        XCTAssertEqual(manager.downloads.first { $0.id == terminal.id }?.resumeData, Data([7]))
        XCTAssertEqual(manager.downloads.first { $0.id == moved.id }?.phase, .completed)
        XCTAssertEqual(manager.downloads.first { $0.id == moved.id }?.destinationURL, destination)
        XCTAssertEqual(manager.downloads.first { $0.id == remaining.id }?.bytesReceived, 75)
        XCTAssertEqual(persistence.stored, manager.downloads)
        XCTAssertEqual(persistence.savedValues.count, 1)
        XCTAssertEqual(completions, [.init(fileURL: destination, occurredAt: date(1_000))])
        XCTAssertEqual(files.moves.count, 1)
        XCTAssertEqual(transport.restoredValues.count, 2)
        XCTAssertEqual(transport.restoredValues.last?.map(\.id), [remaining.id])
        withExtendedLifetime(observation) {}
    }

    func testRecoveredStartDiscardsPendingFinalizationMissingFromLoadedRecords() throws {
        let moved = download(id: id(1), phase: .downloading)
        let remaining = download(id: id(2), phase: .downloading)
        persistence = MemoryDownloadPersistence([moved, remaining])
        let manager = makeManager()
        var completions: [OwnDownloadCompletion] = []
        let observation = manager.ownCompletionPublisher.sink { completions.append($0) }
        try manager.start()
        persistence.saveError = TestFailure.failed
        transport.send(.finished(
            id: moved.id,
            temporaryURL: URL(fileURLWithPath: "/tmp/missing"),
            suggestedFilename: "missing.zip"
        ))
        manager.stop()

        persistence.saveError = nil
        persistence.stored = [remaining]
        try manager.start()

        XCTAssertNil(manager.downloads.first { $0.id == moved.id })
        XCTAssertTrue(completions.isEmpty)
        XCTAssertEqual(files.moves.count, 1)
        XCTAssertEqual(transport.restoredValues.last?.map(\.id), [remaining.id])
        XCTAssertTrue(scheduler.activeEntries.isEmpty)
        withExtendedLifetime(observation) {}
    }

    func testOpenRevealAndDismissOnlyCompletedDestinationThroughInjectedHandlers() throws {
        let destination = URL(fileURLWithPath: "/Downloads/done.zip")
        let completed = download(
            id: id(1),
            phase: .completed,
            destinationURL: destination,
            completedAt: 900
        )
        persistence = MemoryDownloadPersistence([completed])
        let manager = makeManager()
        try manager.start()

        manager.open(completed.id)
        manager.reveal(completed.id)

        XCTAssertEqual(opened, [destination])
        XCTAssertEqual(revealed, [destination])
        manager.dismiss(completed.id)
        XCTAssertTrue(manager.downloads.isEmpty)
        XCTAssertTrue(persistence.stored.isEmpty)
    }

    func testStoppedManagerDoesNotOpenOrRevealPreviouslyLoadedFile() throws {
        let destination = URL(fileURLWithPath: "/Downloads/done.zip")
        let completed = download(
            id: id(1),
            phase: .completed,
            destinationURL: destination,
            completedAt: 900
        )
        persistence = MemoryDownloadPersistence([completed])
        let manager = makeManager()
        try manager.start()
        manager.stop()

        manager.open(completed.id)
        manager.reveal(completed.id)

        XCTAssertTrue(opened.isEmpty)
        XCTAssertTrue(revealed.isEmpty)
    }

    func testOutOfOrderDuplicateAndUnknownTransportEventsDoNothing() throws {
        let paused = download(id: id(1), phase: .paused)
        persistence = MemoryDownloadPersistence([paused])
        let manager = makeManager()
        try manager.start()
        let saveCount = persistence.saveCount
        let temporary = URL(fileURLWithPath: "/tmp/unknown")

        transport.send(.started(id: paused.id, taskIdentifier: 3))
        transport.send(.progress(id: paused.id, received: 10, expected: 20))
        transport.send(.finished(id: paused.id, temporaryURL: temporary, suggestedFilename: nil))
        transport.send(.cancelled(id: paused.id))
        transport.send(.failed(id: id(99), code: "x", message: "Ошибка", resumeData: nil))

        XCTAssertEqual(manager.downloads, [paused])
        XCTAssertEqual(persistence.saveCount, saveCount)
        XCTAssertTrue(files.moves.isEmpty)
    }

    func testDuplicateStartedEventCannotReplacePersistedTaskIdentifier() throws {
        let queued = download(id: id(1), phase: .queued)
        persistence = MemoryDownloadPersistence([queued])
        let manager = makeManager()
        try manager.start()

        transport.send(.started(id: queued.id, taskIdentifier: 41))
        let savesAfterConfirmation = persistence.saveCount
        transport.send(.started(id: queued.id, taskIdentifier: 99))

        XCTAssertEqual(manager.downloads.first?.taskIdentifier, 41)
        XCTAssertEqual(persistence.stored.first?.taskIdentifier, 41)
        XCTAssertEqual(persistence.saveCount, savesAfterConfirmation)
    }

    func testCancelSaveFailureDoesNotPublishCancelledOrCallTransport() throws {
        let paused = download(id: id(1), phase: .paused)
        persistence = MemoryDownloadPersistence([paused])
        let manager = makeManager()
        try manager.start()
        persistence.saveError = TestFailure.failed

        manager.cancel(paused.id)

        XCTAssertEqual(manager.downloads, [paused])
        XCTAssertTrue(transport.cancelledIDs.isEmpty)
        XCTAssertEqual(
            manager.health,
            .unavailable(message: "Не удалось сохранить список загрузок")
        )
    }

    func testCancelledConfirmationOneShotSaveFailureRetriesWithoutSecondCancelCall() throws {
        let active = download(id: id(1), phase: .downloading)
        let queued = download(id: id(2), phase: .queued)
        persistence = MemoryDownloadPersistence([active, queued])
        let manager = makeManager(maxConcurrent: 1)
        try manager.start()
        manager.cancel(active.id)
        persistence.saveError = TestFailure.failed

        transport.send(.cancelled(id: active.id))

        XCTAssertEqual(manager.downloads.first?.phase, .cancelled)
        XCTAssertEqual(transport.cancelledIDs, [active.id])
        XCTAssertTrue(transport.startCalls.isEmpty)
        let retry = try XCTUnwrap(scheduler.activeEntries.first)

        persistence.saveError = nil
        clock.advance(by: 2)
        retry.action()

        XCTAssertNil(manager.downloads.first { $0.id == active.id })
        XCTAssertEqual(manager.downloads.first { $0.id == queued.id }?.phase, .downloading)
        XCTAssertEqual(transport.cancelledIDs, [active.id])
        XCTAssertEqual(transport.startedIDs, [queued.id])
        XCTAssertTrue(scheduler.activeEntries.isEmpty)
    }

    func testPauseFlushFailureDoesNotCallTransportOrCreatePendingPause() throws {
        let active = download(id: id(1), phase: .downloading)
        persistence = MemoryDownloadPersistence([active])
        let manager = makeManager()
        try manager.start()
        persistence.saveError = TestFailure.failed

        manager.pause(active.id)

        XCTAssertTrue(transport.pausedIDs.isEmpty)
        persistence.saveError = nil
        manager.pause(active.id)
        XCTAssertEqual(transport.pausedIDs, [active.id])
    }

    private func makeManager(maxConcurrent: Int = 3) -> DownloadManager {
        DownloadManager(
            clock: clock,
            scheduler: scheduler,
            persistence: persistence,
            transport: transport,
            settings: settings,
            maxConcurrent: maxConcurrent,
            fileOperations: files.operations,
            openHandler: { [weak self] in self?.opened.append($0) },
            revealHandler: { [weak self] in self?.revealed.append($0) }
        )
    }
}

private final class DownloadFileOperationsDouble {
    struct Move: Equatable {
        let source: URL
        let destination: URL
    }

    var existingPaths: Set<String> = []
    var createError: Error?
    var moveError: Error?
    private(set) var createdDirectories: [URL] = []
    private(set) var checkedPaths: [String] = []
    private(set) var moves: [Move] = []

    var operations: DownloadFileOperations {
        DownloadFileOperations(
            createDirectory: { [weak self] url in
                guard let self else { return }
                self.createdDirectories.append(url)
                if let createError { throw createError }
            },
            fileExists: { [weak self] path in
                guard let self else { return false }
                self.checkedPaths.append(path)
                return self.existingPaths.contains(path)
            },
            moveItem: { [weak self] source, destination in
                guard let self else { return }
                self.moves.append(.init(source: source, destination: destination))
                if let moveError { throw moveError }
            }
        )
    }
}

private enum TestFailure: Error {
    case failed
}

private func date(_ seconds: TimeInterval) -> Date {
    Date(timeIntervalSince1970: seconds)
}

private func id(_ suffix: Int) -> UUID {
    UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", suffix))!
}

private func download(
    id: UUID,
    phase: DownloadPhase,
    displayName: String = "archive.zip",
    destinationURL: URL? = nil,
    taskIdentifier: Int? = nil,
    resumeData: Data? = nil,
    bytesReceived: Int64 = 0,
    totalBytes: Int64? = nil,
    createdAt: TimeInterval = 1_000,
    completedAt: TimeInterval? = nil,
    failure: DownloadFailure? = nil
) -> CyclopDownload {
    CyclopDownload(
        id: id,
        remoteURL: URL(string: "https://example.com/\(id.uuidString).zip")!,
        phase: phase,
        displayName: displayName,
        destinationURL: destinationURL,
        taskIdentifier: taskIdentifier,
        resumeData: resumeData,
        bytesReceived: bytesReceived,
        totalBytes: totalBytes,
        createdAt: date(createdAt),
        completedAt: completedAt.map(date),
        failure: failure
    )
}
