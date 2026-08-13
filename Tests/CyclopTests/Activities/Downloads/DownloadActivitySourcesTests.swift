import Combine
import Foundation
import XCTest
@testable import Cyclop

@MainActor
final class DownloadActivitySourcesTests: XCTestCase {
    func testOwnSourceMapsEveryPhaseIdentityProgressOccurrenceAndActionMatrix() throws {
        let records = [
            download(id: id(1), phase: .queued, name: "В очереди.zip", createdAt: 101),
            download(
                id: id(2),
                phase: .downloading,
                name: "Загружается.zip",
                bytesReceived: 150,
                totalBytes: 100,
                createdAt: 102
            ),
            download(
                id: id(3),
                phase: .paused,
                name: "Пауза.zip",
                bytesReceived: -10,
                totalBytes: 100,
                createdAt: 103
            ),
            download(
                id: id(4),
                phase: .failed,
                name: "Ошибка.zip",
                bytesReceived: 50,
                totalBytes: 100,
                createdAt: 104,
                failure: DownloadFailure(code: "network", message: "Ошибка сети")
            ),
            download(
                id: id(5),
                phase: .completed,
                name: "Готово.zip",
                destinationURL: URL(fileURLWithPath: "/Downloads/Готово.zip"),
                createdAt: 105,
                completedAt: 205
            ),
            download(id: id(6), phase: .cancelled, name: "Отменено.zip", createdAt: 106),
        ]
        let context = try makeManager(records: records, maxConcurrent: 0)
        let source = OwnDownloadActivitySource(manager: context.manager)

        let state = try currentState(of: source)

        XCTAssertEqual(source.sourceID, "downloads.own")
        XCTAssertEqual(state.health, .available)
        XCTAssertEqual(state.snapshots, [
            ownSnapshot(
                records[0],
                phase: .ambient,
                progress: nil,
                occurredAt: date(101),
                actions: [.cancel]
            ),
            ownSnapshot(
                records[1],
                phase: .active,
                progress: 1,
                occurredAt: date(102),
                actions: [.pause, .cancel]
            ),
            ownSnapshot(
                records[2],
                phase: .paused,
                progress: 0,
                occurredAt: date(103),
                actions: [.resume, .cancel]
            ),
            ownSnapshot(
                records[3],
                phase: .failed,
                progress: 0.5,
                occurredAt: date(104),
                actions: [.retry, .cancel]
            ),
            ownSnapshot(
                records[4],
                phase: .completed,
                progress: 1,
                occurredAt: date(205),
                actions: [.open, .reveal, .dismiss]
            ),
        ])
        XCTAssertTrue(state.snapshots.allSatisfy { $0.id.source == source.sourceID })
        XCTAssertTrue(state.snapshots.allSatisfy { $0.sourceID == source.sourceID })
        XCTAssertEqual(state.snapshots.map(\.id.local), records.prefix(5).map { $0.id.uuidString })
        XCTAssertTrue(state.snapshots.allSatisfy { !$0.title.contains("https://") })
        XCTAssertTrue(state.snapshots.allSatisfy { !$0.subtitle.contains("https://") })
    }

    func testOwnIdentityAndOccurrenceRemainStableAcrossProgressUpdatesAndReload() throws {
        let active = download(
            id: id(1),
            phase: .downloading,
            name: "Большой файл.iso",
            bytesReceived: 10,
            totalBytes: 100,
            createdAt: 333
        )
        let firstContext = try makeManager(records: [active])
        let firstSource = OwnDownloadActivitySource(manager: firstContext.manager)
        let first = try XCTUnwrap(currentState(of: firstSource).snapshots.first)

        firstContext.transport.send(.progress(id: active.id, received: 90, expected: 100))
        let progressed = try XCTUnwrap(currentState(of: firstSource).snapshots.first)

        let persisted = try XCTUnwrap(firstContext.persistence.stored.first)
        let relaunchedContext = try makeManager(records: [persisted])
        let relaunched = try XCTUnwrap(
            currentState(of: OwnDownloadActivitySource(manager: relaunchedContext.manager))
                .snapshots.first
        )

        XCTAssertEqual(first.id, ActivityID(source: "downloads.own", local: active.id.uuidString))
        XCTAssertEqual(progressed.id, first.id)
        XCTAssertEqual(relaunched.id, first.id)
        XCTAssertEqual(first.occurredAt, date(333))
        XCTAssertEqual(progressed.occurredAt, date(333))
        XCTAssertEqual(relaunched.occurredAt, date(333))
        XCTAssertEqual(first.progress, 0.1)
        XCTAssertEqual(progressed.progress, 0.9)
    }

    func testRepeatedFailureGetsNewPersistedOccurrenceAndSecondAttentionClaim() throws {
        let active = download(
            id: id(1),
            phase: .downloading,
            bytesReceived: 40,
            totalBytes: 100,
            createdAt: 100
        )
        let context = try makeManager(records: [active])
        let source = OwnDownloadActivitySource(manager: context.manager)
        let defaults = UserDefaults(
            suiteName: "DownloadRepeatedFailureTests-\(UUID().uuidString)"
        )!
        let ledger = ActivityAttentionLedger(defaults: defaults, clock: context.clock)

        let beforeFirst = try currentState(of: source).snapshots
        context.transport.send(.failed(
            id: active.id,
            code: "network-1",
            message: "Первая ошибка",
            resumeData: nil
        ))
        let firstFailed = try currentState(of: source).snapshots
        let firstEvent = try XCTUnwrap(ActivityAttentionPolicy.events(
            previous: beforeFirst,
            current: firstFailed,
            now: context.clock.now
        ).first)
        XCTAssertTrue(ledger.claim(firstEvent))
        XCTAssertEqual(firstFailed.first?.progress, 0.4)
        XCTAssertEqual(firstFailed.first?.occurredAt, date(1_000))
        XCTAssertEqual(context.persistence.stored.first?.failedAt, date(1_000))

        source.perform(.retry, activityID: ownID(active.id))
        XCTAssertNil(context.manager.downloads.first?.failedAt)
        context.clock.advance(by: 5)
        context.transport.send(.progress(id: active.id, received: 70, expected: 100))
        let retried = try currentState(of: source).snapshots
        context.transport.send(.failed(
            id: active.id,
            code: "network-2",
            message: "Вторая ошибка",
            resumeData: nil
        ))
        let secondFailed = try currentState(of: source).snapshots
        let secondEvent = try XCTUnwrap(ActivityAttentionPolicy.events(
            previous: retried,
            current: secondFailed,
            now: context.clock.now
        ).first)

        XCTAssertEqual(retried.first?.progress, 0.7)
        XCTAssertEqual(secondFailed.first?.progress, 0.7)
        XCTAssertEqual(secondFailed.first?.occurredAt, date(1_005))
        XCTAssertEqual(context.persistence.stored.first?.failedAt, date(1_005))
        XCTAssertNotEqual(secondEvent.id, firstEvent.id)
        XCTAssertTrue(ledger.claim(secondEvent))

        let relaunched = try makeManager(records: context.persistence.stored)
        XCTAssertEqual(
            try currentState(of: OwnDownloadActivitySource(manager: relaunched.manager))
                .snapshots.first?.occurredAt,
            date(1_005)
        )
    }

    func testOwnUnfinishedUnknownLengthHasNoProgressWhileCompletedIsExactlyOne() throws {
        let unknown = download(
            id: id(1),
            phase: .downloading,
            bytesReceived: 500,
            totalBytes: nil
        )
        let completed = download(
            id: id(2),
            phase: .completed,
            bytesReceived: 0,
            totalBytes: nil,
            completedAt: 1_100
        )
        let context = try makeManager(records: [unknown, completed])
        let snapshots = try currentState(of: OwnDownloadActivitySource(manager: context.manager))
            .snapshots

        XCTAssertNil(snapshots[0].progress)
        XCTAssertEqual(snapshots[1].progress, 1)
    }

    func testOwnSourceRoutesEverySupportedActionAndHidesCancelledImmediately() throws {
        let queued = download(id: id(1), phase: .queued)
        let queuedContext = try makeManager(records: [queued], maxConcurrent: 0)
        let queuedSource = OwnDownloadActivitySource(manager: queuedContext.manager)
        queuedSource.perform(.cancel, activityID: ownID(queued.id))
        XCTAssertEqual(queuedContext.manager.downloads.first?.phase, .cancelled)
        XCTAssertEqual(queuedContext.transport.cancelledIDs, [queued.id])
        XCTAssertTrue(try currentState(of: queuedSource).snapshots.isEmpty)

        let active = download(id: id(2), phase: .downloading)
        let activeContext = try makeManager(records: [active])
        let activeSource = OwnDownloadActivitySource(manager: activeContext.manager)
        activeSource.perform(.pause, activityID: ownID(active.id))
        XCTAssertEqual(activeContext.transport.pausedIDs, [active.id])

        let paused = download(id: id(3), phase: .paused, bytesReceived: 30, totalBytes: 100)
        let pausedContext = try makeManager(records: [paused])
        let pausedSource = OwnDownloadActivitySource(manager: pausedContext.manager)
        pausedSource.perform(.resume, activityID: ownID(paused.id))
        XCTAssertEqual(pausedContext.manager.downloads.first?.phase, .downloading)
        XCTAssertEqual(pausedContext.transport.startedIDs, [paused.id])

        let failed = download(
            id: id(4),
            phase: .failed,
            failure: DownloadFailure(code: "network", message: "Ошибка")
        )
        let failedContext = try makeManager(records: [failed])
        let failedSource = OwnDownloadActivitySource(manager: failedContext.manager)
        failedSource.perform(.retry, activityID: ownID(failed.id))
        XCTAssertEqual(failedContext.manager.downloads.first?.phase, .downloading)
        XCTAssertEqual(failedContext.transport.startedIDs, [failed.id])

        let destination = URL(fileURLWithPath: "/Downloads/готово.zip")
        let completed = download(
            id: id(5),
            phase: .completed,
            destinationURL: destination,
            completedAt: 1_100
        )
        let completedContext = try makeManager(records: [completed])
        let completedSource = OwnDownloadActivitySource(manager: completedContext.manager)
        completedSource.perform(.open, activityID: ownID(completed.id))
        completedSource.perform(.reveal, activityID: ownID(completed.id))
        XCTAssertEqual(completedContext.opened, [destination])
        XCTAssertEqual(completedContext.revealed, [destination])
        completedSource.perform(.dismiss, activityID: ownID(completed.id))
        XCTAssertTrue(completedContext.manager.downloads.isEmpty)
        XCTAssertTrue(try currentState(of: completedSource).snapshots.isEmpty)
    }

    func testOwnCompletedCanBeDismissedSynchronouslyInsidePublishedCallback() throws {
        let active = download(id: id(1), phase: .downloading, name: "готово.zip")
        let context = try makeManager(records: [active])
        let source = OwnDownloadActivitySource(manager: context.manager)
        var states: [ActivitySourceState] = []
        let observation = source.statePublisher.sink { state in
            states.append(state)
            guard let completed = state.snapshots.first(where: { $0.phase == .completed }) else {
                return
            }
            source.perform(.dismiss, activityID: completed.id)
        }

        context.transport.send(.finished(
            id: active.id,
            temporaryURL: URL(fileURLWithPath: "/tmp/готово"),
            suggestedFilename: "готово.zip"
        ))

        XCTAssertTrue(context.manager.downloads.isEmpty)
        XCTAssertEqual(states.last, .init(snapshots: [], health: .available))
        XCTAssertEqual(states.filter { $0.snapshots.first?.phase == .completed }.count, 1)
        withExtendedLifetime(observation) {}
    }

    func testOwnCancelRoutesForEveryCancellablePhaseAndHidesEachImmediately() throws {
        for (offset, phase) in [
            DownloadPhase.queued,
            .downloading,
            .paused,
            .failed,
        ].enumerated() {
            let record = download(
                id: id(offset + 1),
                phase: phase,
                failure: phase == .failed
                    ? DownloadFailure(code: "network", message: "Ошибка")
                    : nil
            )
            let context = try makeManager(
                records: [record],
                maxConcurrent: phase == .queued ? 0 : 3
            )
            let source = OwnDownloadActivitySource(manager: context.manager)

            source.perform(.cancel, activityID: ownID(record.id))

            XCTAssertEqual(context.manager.downloads.first?.phase, .cancelled)
            XCTAssertEqual(context.transport.cancelledIDs, [record.id])
            XCTAssertTrue(try currentState(of: source).snapshots.isEmpty)
        }
    }

    func testOwnSourceRejectsForeignMalformedAndUnsupportedActionsWithoutSideEffects() throws {
        let completed = download(
            id: id(1),
            phase: .completed,
            destinationURL: URL(fileURLWithPath: "/Downloads/готово.zip"),
            completedAt: 1_100
        )
        let context = try makeManager(records: [completed])
        let source = OwnDownloadActivitySource(manager: context.manager)
        let initial = context.manager.downloads
        let initialSaveCount = context.persistence.saveCount

        source.perform(
            .dismiss,
            activityID: ActivityID(source: "downloads.external", local: completed.id.uuidString)
        )
        source.perform(
            .dismiss,
            activityID: ActivityID(source: "downloads.own", local: "не-uuid")
        )
        source.perform(.pause, activityID: ownID(completed.id))

        XCTAssertEqual(context.manager.downloads, initial)
        XCTAssertEqual(context.persistence.saveCount, initialSaveCount)
        XCTAssertTrue(context.opened.isEmpty)
        XCTAssertTrue(context.revealed.isEmpty)
    }

    func testOwnMissingDestinationOpenAndRevealAreSafeRussianDiagnosticNoOps() throws {
        let completed = download(id: id(1), phase: .completed, completedAt: 1_100)
        let context = try makeManager(records: [completed])
        let source = OwnDownloadActivitySource(manager: context.manager)

        source.perform(.open, activityID: ownID(completed.id))
        source.perform(.reveal, activityID: ownID(completed.id))

        XCTAssertTrue(context.opened.isEmpty)
        XCTAssertTrue(context.revealed.isEmpty)
        XCTAssertEqual(
            try currentState(of: source).health,
            .unavailable(message: "Файл загрузки недоступен")
        )

        source.perform(.dismiss, activityID: ownID(completed.id))
        XCTAssertEqual(
            try currentState(of: source),
            ActivitySourceState(snapshots: [], health: .available)
        )
    }

    func testOwnSourceMirrorsManagerHealthAndPublishesRecoveryAtomically() throws {
        let paused = download(id: id(1), phase: .paused, bytesReceived: 20, totalBytes: 100)
        let context = try makeManager(records: [paused], maxConcurrent: 0)
        let source = OwnDownloadActivitySource(manager: context.manager)
        var states: [ActivitySourceState] = []
        let observation = source.statePublisher.sink { states.append($0) }

        context.persistence.saveError = DownloadSourceTestError.failed
        source.perform(.resume, activityID: ownID(paused.id))
        context.persistence.saveError = nil
        source.perform(.resume, activityID: ownID(paused.id))

        XCTAssertEqual(states, [
            .init(
                snapshots: [ownSnapshot(
                    paused,
                    phase: .paused,
                    progress: 0.2,
                    occurredAt: paused.createdAt,
                    actions: [.resume, .cancel]
                )],
                health: .available
            ),
            .init(
                snapshots: [ownSnapshot(
                    paused,
                    phase: .paused,
                    progress: 0.2,
                    occurredAt: paused.createdAt,
                    actions: [.resume, .cancel]
                )],
                health: .unavailable(message: "Не удалось сохранить список загрузок")
            ),
            .init(
                snapshots: [ownSnapshot(
                    replacingPhase(of: paused, with: .queued),
                    phase: .ambient,
                    progress: 0.2,
                    occurredAt: paused.createdAt,
                    actions: [.cancel]
                )],
                health: .available
            ),
        ])
        withExtendedLifetime(observation) {}
    }

    func testOwnSourceReflectsLoadFailureAndRecovery() throws {
        let context = makeUnstartedManager(records: [])
        context.persistence.loadError = DownloadSourceTestError.failed
        let source = OwnDownloadActivitySource(manager: context.manager)

        XCTAssertThrowsError(try context.manager.start())
        XCTAssertEqual(
            try currentState(of: source).health,
            .unavailable(message: "Не удалось загрузить список загрузок")
        )

        context.persistence.loadError = nil
        try context.manager.start()

        XCTAssertEqual(try currentState(of: source).health, .available)
    }

    func testExternalSourceUsesExactStableCompletionIDFilenameAndNoProgress() throws {
        let folder = URL(fileURLWithPath: "/Downloads", isDirectory: true)
        let file = folder.appendingPathComponent("Отчёт #1 [финал].zip")
        let context = makeWatcher(folder: folder)
        let source = ExternalDownloadActivitySource(
            watcher: context.watcher,
            openHandler: { context.opened.append($0) },
            revealHandler: { context.revealed.append($0) }
        )
        context.watcher.start()

        emitExternal(file, in: context)

        let snapshot = try XCTUnwrap(currentState(of: source).snapshots.first)
        XCTAssertEqual(source.sourceID, "downloads.external")
        XCTAssertEqual(
            snapshot.id,
            ActivityID(
                source: "downloads.external",
                local: "path:/Downloads/Отчёт #1 [финал].zip|1001800"
            )
        )
        XCTAssertEqual(snapshot.sourceID, "downloads.external")
        XCTAssertEqual(snapshot.kind, .download)
        XCTAssertEqual(snapshot.phase, .completed)
        XCTAssertEqual(snapshot.title, "Отчёт #1 [финал].zip")
        XCTAssertEqual(snapshot.subtitle, "")
        XCTAssertNil(snapshot.progress)
        XCTAssertNil(snapshot.deadline)
        XCTAssertEqual(snapshot.occurredAt, date(1_001.8))
        XCTAssertEqual(snapshot.availableActions, [.open, .reveal, .dismiss])
        XCTAssertTrue(snapshot.containsSensitiveText)

        let reattached = try XCTUnwrap(
            currentState(of: ExternalDownloadActivitySource(watcher: context.watcher))
                .snapshots.first
        )
        XCTAssertEqual(reattached.id, snapshot.id)
        XCTAssertEqual(reattached.occurredAt, snapshot.occurredAt)
    }

    func testExternalSourceRoutesOpenRevealAndDismissExactlyOnce() throws {
        let folder = URL(fileURLWithPath: "/Downloads", isDirectory: true)
        let file = folder.appendingPathComponent("файл с # и %.zip")
        let context = makeWatcher(folder: folder)
        let source = ExternalDownloadActivitySource(
            watcher: context.watcher,
            openHandler: { context.opened.append($0) },
            revealHandler: { context.revealed.append($0) }
        )
        context.watcher.start()
        emitExternal(file, in: context)
        let activityID = try XCTUnwrap(currentState(of: source).snapshots.first?.id)
        var states: [ActivitySourceState] = []
        let observation = source.statePublisher.sink { states.append($0) }

        source.perform(.open, activityID: activityID)
        source.perform(.reveal, activityID: activityID)
        context.watcher.dismiss("unknown")
        XCTAssertEqual(context.watcher.completions.count, 1)
        XCTAssertEqual(states.count, 1)
        source.perform(.dismiss, activityID: activityID)
        source.perform(.dismiss, activityID: activityID)

        XCTAssertEqual(context.opened, [file])
        XCTAssertEqual(context.revealed, [file])
        XCTAssertTrue(context.watcher.completions.isEmpty)
        XCTAssertEqual(states.count, 2)
        XCTAssertEqual(states.last, .init(snapshots: [], health: .available))

        context.watcher.folderDidChange()
        advanceAndFire(clock: context.clock, scheduler: context.scheduler, by: 0.3)
        XCTAssertTrue(context.watcher.completions.isEmpty)
        XCTAssertEqual(states.count, 2)
        withExtendedLifetime(observation) {}
    }

    func testExternalCompletionActionsWorkSynchronouslyInsidePublishedCallback() throws {
        let folder = URL(fileURLWithPath: "/Downloads", isDirectory: true)
        let file = folder.appendingPathComponent("синхронно.zip")
        let context = makeWatcher(folder: folder)
        let source = ExternalDownloadActivitySource(
            watcher: context.watcher,
            openHandler: { context.opened.append($0) },
            revealHandler: { context.revealed.append($0) }
        )
        var states: [ActivitySourceState] = []
        let observation = source.statePublisher.sink { state in
            states.append(state)
            guard let completion = state.snapshots.first else { return }
            source.perform(.open, activityID: completion.id)
            source.perform(.reveal, activityID: completion.id)
            source.perform(.dismiss, activityID: completion.id)
        }
        context.watcher.start()

        emitExternal(file, in: context)

        XCTAssertEqual(context.opened, [file])
        XCTAssertEqual(context.revealed, [file])
        XCTAssertTrue(context.watcher.completions.isEmpty)
        XCTAssertEqual(states.last, .init(snapshots: [], health: .available))
        XCTAssertEqual(states.filter { !$0.snapshots.isEmpty }.count, 1)
        withExtendedLifetime(observation) {}
    }

    func testExternalSourceRejectsForeignUnknownAndUnsupportedActions() throws {
        let folder = URL(fileURLWithPath: "/Downloads", isDirectory: true)
        let file = folder.appendingPathComponent("оставить.zip")
        let context = makeWatcher(folder: folder)
        let source = ExternalDownloadActivitySource(
            watcher: context.watcher,
            openHandler: { context.opened.append($0) },
            revealHandler: { context.revealed.append($0) }
        )
        context.watcher.start()
        emitExternal(file, in: context)
        let activityID = try XCTUnwrap(currentState(of: source).snapshots.first?.id)

        source.perform(
            .dismiss,
            activityID: ActivityID(source: "downloads.own", local: activityID.local)
        )
        source.perform(
            .open,
            activityID: ActivityID(source: "downloads.external", local: "missing")
        )
        source.perform(.pause, activityID: activityID)

        XCTAssertEqual(context.watcher.completions.count, 1)
        XCTAssertTrue(context.opened.isEmpty)
        XCTAssertTrue(context.revealed.isEmpty)
    }

    func testExternalSourceMirrorsWatcherUnavailableAndRecoveryWithoutMixedState() throws {
        let firstFolder = URL(fileURLWithPath: "/Missing", isDirectory: true)
        let context = makeWatcher(folder: firstFolder)
        let source = ExternalDownloadActivitySource(watcher: context.watcher)
        var states: [ActivitySourceState] = []
        let observation = source.statePublisher.sink { states.append($0) }
        context.provider.error = DownloadSourceTestError.failed

        context.watcher.start()
        context.provider.error = nil
        context.watcher.replaceFolder(
            with: URL(fileURLWithPath: "/Recovered", isDirectory: true)
        )

        XCTAssertEqual(states, [
            .init(snapshots: [], health: .available),
            .init(
                snapshots: [],
                health: .unavailable(message: "Папка загрузок недоступна")
            ),
            .init(snapshots: [], health: .available),
        ])
        withExtendedLifetime(observation) {}
    }

    func testOwnCompletionSuppressionKeepsExternalActivitySourceEmptyEndToEnd() throws {
        let folder = URL(fileURLWithPath: "/Downloads", isDirectory: true)
        let settings = settings(downloadsFolder: folder)
        let clock = MutableActivityClock(now: date(1_000))
        let scheduler = ManualActivityScheduler()
        let transport = FakeDownloadTransport()
        let persistence = MemoryDownloadPersistence([
            download(id: id(1), phase: .downloading, name: "own.zip"),
        ])
        let files = DownloadSourceFilesDouble()
        let manager = DownloadManager(
            clock: clock,
            scheduler: scheduler,
            persistence: persistence,
            transport: transport,
            settings: settings,
            fileOperations: files.operations
        )
        try manager.start()
        let ownSource = OwnDownloadActivitySource(manager: manager)
        let provider = DownloadSourceFolderProvider()
        let watcher = DownloadsFolderWatcher(
            settings: settings,
            clock: clock,
            scheduler: scheduler,
            snapshotProvider: provider,
            ownCompletionPublisher: manager.ownCompletionPublisher,
            eventMonitor: DownloadSourceFolderMonitor()
        )
        let externalSource = ExternalDownloadActivitySource(watcher: watcher)
        watcher.start()

        transport.send(.finished(
            id: id(1),
            temporaryURL: URL(fileURLWithPath: "/tmp/own"),
            suggestedFilename: "own.zip"
        ))
        let destination = folder.appendingPathComponent("own.zip")
        provider.files = [folderSnapshot(destination)]
        watcher.folderDidChange()
        advanceAndFire(clock: clock, scheduler: scheduler, by: 0.3)
        advanceAndFire(clock: clock, scheduler: scheduler, by: 1.5)

        XCTAssertEqual(try currentState(of: ownSource).snapshots.map(\.phase), [.completed])
        XCTAssertTrue(try currentState(of: externalSource).snapshots.isEmpty)
        XCTAssertTrue(watcher.completions.isEmpty)
    }

    private func emitExternal(_ file: URL, in context: WatcherContext) {
        context.provider.files = [folderSnapshot(file)]
        context.watcher.folderDidChange()
        advanceAndFire(clock: context.clock, scheduler: context.scheduler, by: 0.3)
        advanceAndFire(clock: context.clock, scheduler: context.scheduler, by: 1.5)
    }

    private func makeManager(
        records: [CyclopDownload],
        maxConcurrent: Int = 3
    ) throws -> ManagerContext {
        let context = makeUnstartedManager(records: records, maxConcurrent: maxConcurrent)
        try context.manager.start()
        return context
    }

    private func makeUnstartedManager(
        records: [CyclopDownload],
        maxConcurrent: Int = 3
    ) -> ManagerContext {
        let clock = MutableActivityClock(now: date(1_000))
        let persistence = MemoryDownloadPersistence(records)
        let transport = FakeDownloadTransport()
        let opened = URLRecorder()
        let revealed = URLRecorder()
        let manager = DownloadManager(
            clock: clock,
            scheduler: ManualActivityScheduler(),
            persistence: persistence,
            transport: transport,
            settings: settings(downloadsFolder: URL(fileURLWithPath: "/Downloads")),
            maxConcurrent: maxConcurrent,
            fileOperations: DownloadSourceFilesDouble().operations,
            openHandler: { opened.values.append($0) },
            revealHandler: { revealed.values.append($0) }
        )
        return ManagerContext(
            manager: manager,
            clock: clock,
            persistence: persistence,
            transport: transport,
            openedRecorder: opened,
            revealedRecorder: revealed
        )
    }

    private func makeWatcher(folder: URL) -> WatcherContext {
        let clock = MutableActivityClock(now: date(1_000))
        let scheduler = ManualActivityScheduler()
        let provider = DownloadSourceFolderProvider()
        let opened = URLRecorder()
        let revealed = URLRecorder()
        let watcher = DownloadsFolderWatcher(
            settings: settings(downloadsFolder: folder),
            clock: clock,
            scheduler: scheduler,
            snapshotProvider: provider,
            ownCompletionPublisher: Empty(completeImmediately: false).eraseToAnyPublisher(),
            eventMonitor: DownloadSourceFolderMonitor()
        )
        return WatcherContext(
            watcher: watcher,
            clock: clock,
            scheduler: scheduler,
            provider: provider,
            openedRecorder: opened,
            revealedRecorder: revealed
        )
    }

    private func settings(downloadsFolder: URL) -> ActivitySettings {
        let defaults = UserDefaults(
            suiteName: "DownloadActivitySourcesTests-\(UUID().uuidString)"
        )!
        let settings = ActivitySettings(
            defaults: defaults,
            homeDirectory: downloadsFolder.deletingLastPathComponent()
        )
        settings.downloadsFolder = downloadsFolder
        return settings
    }

    private func currentState(of source: any ActivitySource) throws -> ActivitySourceState {
        var current: ActivitySourceState?
        let observation = source.statePublisher.prefix(1).sink { current = $0 }
        defer { observation.cancel() }
        return try XCTUnwrap(current)
    }

    private func ownSnapshot(
        _ record: CyclopDownload,
        phase: ActivityPhase,
        progress: Double?,
        occurredAt: Date,
        actions: Set<ActivityAction>
    ) -> ActivitySnapshot {
        ActivitySnapshot(
            id: ownID(record.id),
            sourceID: "downloads.own",
            kind: .download,
            phase: phase,
            title: record.displayName,
            subtitle: "",
            progress: progress,
            deadline: nil,
            occurredAt: occurredAt,
            availableActions: actions,
            containsSensitiveText: true
        )
    }

    private func ownID(_ id: UUID) -> ActivityID {
        ActivityID(source: "downloads.own", local: id.uuidString)
    }

    private func replacingPhase(
        of record: CyclopDownload,
        with phase: DownloadPhase
    ) -> CyclopDownload {
        var updated = record
        updated.phase = phase
        updated.taskIdentifier = nil
        updated.failure = nil
        updated.completedAt = nil
        updated.failedAt = nil
        return updated
    }

    private func download(
        id: UUID,
        phase: DownloadPhase,
        name: String = "archive.zip",
        destinationURL: URL? = nil,
        bytesReceived: Int64 = 0,
        totalBytes: Int64? = nil,
        createdAt: TimeInterval = 1_000,
        completedAt: TimeInterval? = nil,
        failedAt: TimeInterval? = nil,
        failure: DownloadFailure? = nil
    ) -> CyclopDownload {
        CyclopDownload(
            id: id,
            remoteURL: URL(string: "https://secret.example/\(id.uuidString)?token=private")!,
            phase: phase,
            displayName: name,
            destinationURL: destinationURL,
            taskIdentifier: phase == .downloading ? 42 : nil,
            resumeData: nil,
            bytesReceived: bytesReceived,
            totalBytes: totalBytes,
            createdAt: date(createdAt),
            completedAt: completedAt.map(date),
            failedAt: failedAt.map(date),
            failure: failure
        )
    }

    private func id(_ suffix: Int) -> UUID {
        UUID(uuidString: String(format: "60000000-0000-0000-0000-%012d", suffix))!
    }

    private func date(_ seconds: TimeInterval) -> Date {
        Date(timeIntervalSince1970: seconds)
    }

    private func folderSnapshot(_ url: URL) -> FolderFileSnapshot {
        FolderFileSnapshot(
            url: url,
            fileResourceIdentifier: nil,
            size: 100,
            modifiedAt: date(900)
        )
    }

    private func advanceAndFire(
        clock: MutableActivityClock,
        scheduler: ManualActivityScheduler,
        by interval: TimeInterval
    ) {
        clock.advance(by: interval)
        let entry = scheduler.activeEntries.min { $0.date < $1.date }
        entry?.cancellation.cancel()
        entry?.action()
    }
}

private struct ManagerContext {
    let manager: DownloadManager
    let clock: MutableActivityClock
    let persistence: MemoryDownloadPersistence
    let transport: FakeDownloadTransport
    let openedRecorder: URLRecorder
    let revealedRecorder: URLRecorder

    var opened: [URL] { openedRecorder.values }
    var revealed: [URL] { revealedRecorder.values }
}

private struct WatcherContext {
    let watcher: DownloadsFolderWatcher
    let clock: MutableActivityClock
    let scheduler: ManualActivityScheduler
    let provider: DownloadSourceFolderProvider
    let openedRecorder: URLRecorder
    let revealedRecorder: URLRecorder

    var opened: [URL] {
        get { openedRecorder.values }
        nonmutating set { openedRecorder.values = newValue }
    }

    var revealed: [URL] {
        get { revealedRecorder.values }
        nonmutating set { revealedRecorder.values = newValue }
    }
}

private final class URLRecorder {
    var values: [URL] = []
}

private enum DownloadSourceTestError: Error {
    case failed
}

private final class DownloadSourceFolderProvider: FolderSnapshotProviding {
    var files: [FolderFileSnapshot] = []
    var error: Error?

    func snapshots(in _: URL) throws -> [FolderFileSnapshot] {
        if let error { throw error }
        return files
    }
}

@MainActor
private final class DownloadSourceFolderMonitor: DownloadsFolderEventMonitoring {
    func start(
        folder _: URL,
        handler _: @escaping @MainActor (DownloadsFolderEvent) -> Void
    ) throws {}

    func stop() {}
}

private final class DownloadSourceFilesDouble {
    var operations: DownloadFileOperations {
        DownloadFileOperations(
            createDirectory: { _ in },
            fileExists: { _ in false },
            moveItem: { _, _ in }
        )
    }
}
