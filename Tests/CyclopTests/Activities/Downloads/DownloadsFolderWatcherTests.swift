import Combine
import Darwin
import Dispatch
import Foundation
import XCTest
@testable import Cyclop

@MainActor
final class DownloadsFolderWatcherTests: XCTestCase {
    func testLiveSnapshotProviderReturnsOnlyVisibleRegularFilesWithoutReadingContents() throws {
        let fileManager = FileManager.default
        let folder = fileManager.temporaryDirectory
            .appendingPathComponent("CyclopFolderSnapshotTests-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: folder) }

        XCTAssertTrue(fileManager.createFile(
            atPath: folder.appendingPathComponent("archive.zip").path,
            contents: Data([1, 2, 3])
        ))
        XCTAssertTrue(fileManager.createFile(
            atPath: folder.appendingPathComponent(".hidden.zip").path,
            contents: Data()
        ))
        for name in [
            "one.crdownload", "two.DOWNLOAD", "three.Part", "four.PARTIAL", "five.TmP"
        ] {
            XCTAssertTrue(fileManager.createFile(
                atPath: folder.appendingPathComponent(name).path,
                contents: Data()
            ))
        }
        try fileManager.createDirectory(
            at: folder.appendingPathComponent("nested", isDirectory: true),
            withIntermediateDirectories: true
        )
        try fileManager.createSymbolicLink(
            at: folder.appendingPathComponent("archive-link.zip"),
            withDestinationURL: folder.appendingPathComponent("archive.zip")
        )

        let snapshots = try FileManagerFolderSnapshotProvider(fileManager: fileManager)
            .snapshots(in: folder)

        XCTAssertEqual(snapshots.map(\.url.lastPathComponent), [
            "archive.zip",
            "five.TmP",
            "four.PARTIAL",
            "one.crdownload",
            "three.Part",
            "two.DOWNLOAD"
        ])
        let archive = try XCTUnwrap(snapshots.first { $0.url.lastPathComponent == "archive.zip" })
        XCTAssertEqual(archive.size, 3)
        XCTAssertNotNil(archive.fileResourceIdentifier)
    }

    func testLiveSnapshotProviderPropagatesMissingFolderError() {
        let missingFolder = FileManager.default.temporaryDirectory
            .appendingPathComponent("CyclopMissingFolder-\(UUID().uuidString)", isDirectory: true)

        XCTAssertThrowsError(
            try FileManagerFolderSnapshotProvider().snapshots(in: missingFolder)
        )
    }

    func testLiveSnapshotProviderSkipsEntryThatDisappearsDuringMetadataRead() throws {
        let fileManager = FileManager.default
        let folder = fileManager.temporaryDirectory
            .appendingPathComponent("CyclopFolderRaceTests-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: folder) }
        let stable = folder.appendingPathComponent("stable.zip")
        let transient = folder.appendingPathComponent("transient.zip")
        XCTAssertTrue(fileManager.createFile(atPath: stable.path, contents: Data([1])))
        XCTAssertTrue(fileManager.createFile(atPath: transient.path, contents: Data([2])))
        let provider = FileManagerFolderSnapshotProvider(
            fileManager: fileManager,
            resourceValues: { url, keys in
                if url.lastPathComponent == "transient.zip" {
                    throw SnapshotFailure.unavailable
                }
                return try url.resourceValues(forKeys: keys)
            }
        )

        let snapshots = try provider.snapshots(in: folder)

        XCTAssertEqual(snapshots.map(\.url.lastPathComponent), ["stable.zip"])
    }

    func testHardLinksWithSameResourceIdentityDoNotCrashWatcherBaseline() throws {
        let fileManager = FileManager.default
        let folder = fileManager.temporaryDirectory
            .appendingPathComponent("CyclopHardLinkTests-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: folder) }
        let first = folder.appendingPathComponent("first.zip")
        let second = folder.appendingPathComponent("second.zip")
        XCTAssertTrue(fileManager.createFile(atPath: first.path, contents: Data([1, 2, 3])))
        try fileManager.linkItem(at: first, to: second)
        let provider = FileManagerFolderSnapshotProvider(fileManager: fileManager)
        let snapshots = try provider.snapshots(in: folder)
        let resourceID = try XCTUnwrap(snapshots.first?.fileResourceIdentifier)
        XCTAssertEqual(snapshots.map(\.fileResourceIdentifier), [resourceID, resourceID])
        let defaults = UserDefaults(suiteName: "DownloadsFolderWatcherHardLinks-\(UUID().uuidString)")!
        let settings = ActivitySettings(defaults: defaults, homeDirectory: folder.deletingLastPathComponent())
        settings.downloadsFolder = folder
        let watcher = DownloadsFolderWatcher(
            settings: settings,
            clock: MutableActivityClock(now: date(1_000)),
            scheduler: ManualActivityScheduler(),
            snapshotProvider: provider,
            ownCompletionPublisher: Empty(completeImmediately: false).eraseToAnyPublisher(),
            eventMonitor: FolderEventMonitorDouble()
        )

        watcher.start()

        XCTAssertEqual(watcher.health, .available)
        XCTAssertTrue(watcher.completions.isEmpty)
    }

    func testProductionMonitorUsesExactDescriptorMaskMapsEventsAndClosesExactlyOnce() throws {
        let descriptors = FolderDescriptorOperationsDouble()
        let firstSource = FolderDispatchSourceDouble()
        let secondSource = FolderDispatchSourceDouble()
        var sources = [firstSource, secondSource]
        var requestedMasks: [DispatchSource.FileSystemEvent] = []
        let monitor = DispatchDownloadsFolderEventMonitor(
            descriptorOperations: descriptors.operations,
            sourceFactory: { descriptor, mask in
                XCTAssertEqual(descriptor, sources.count == 2 ? 41 : 42)
                requestedMasks.append(mask)
                return sources.removeFirst()
            }
        )
        let folder = URL(fileURLWithPath: "/Downloads", isDirectory: true)
        var events: [DownloadsFolderEvent] = []

        try monitor.start(folder: folder) { events.append($0) }

        XCTAssertEqual(descriptors.openCalls, [.init(path: folder.path, flags: O_EVTONLY)])
        XCTAssertEqual(requestedMasks, [[.write, .rename, .extend, .attrib]])
        firstSource.data = .write
        firstSource.fireEvent()
        firstSource.data = [.write, .rename]
        firstSource.fireEvent()
        XCTAssertEqual(events, [.contentsChanged, .folderReplaced])

        monitor.stop()
        monitor.stop()
        XCTAssertEqual(firstSource.cancelCount, 1)
        XCTAssertTrue(descriptors.closedDescriptors.isEmpty)
        firstSource.fireCancel()
        firstSource.fireCancel()
        XCTAssertEqual(descriptors.closedDescriptors, [41])

        try monitor.start(folder: folder) { events.append($0) }
        monitor.stop()
        secondSource.fireCancel()
        XCTAssertEqual(descriptors.closedDescriptors, [41, 42])
    }

    func testProductionMonitorOpenFailureDoesNotCreateSourceOrCloseInvalidDescriptor() {
        let descriptors = FolderDescriptorOperationsDouble()
        descriptors.nextDescriptors = [-1]
        var sourceCreationCount = 0
        let monitor = DispatchDownloadsFolderEventMonitor(
            descriptorOperations: descriptors.operations,
            sourceFactory: { _, _ in
                sourceCreationCount += 1
                return FolderDispatchSourceDouble()
            }
        )

        XCTAssertThrowsError(
            try monitor.start(folder: URL(fileURLWithPath: "/Missing")) { _ in }
        )
        XCTAssertEqual(sourceCreationCount, 0)
        XCTAssertTrue(descriptors.closedDescriptors.isEmpty)
    }

    func testStartBuildsBaselineAndTemporarySuffixesNeverBecomeCandidates() {
        let folder = URL(fileURLWithPath: "/Downloads", isDirectory: true)
        let provider = MutableFolderSnapshotProvider([
            file("old.zip", folder: folder, resourceID: "old", size: 100),
            file("movie.crdownload", folder: folder, resourceID: "temp", size: 200)
        ])
        let monitor = FolderEventMonitorDouble()
        let scheduler = ManualActivityScheduler()
        let watcher = makeWatcher(
            folder: folder,
            provider: provider,
            scheduler: scheduler,
            monitor: monitor
        )

        watcher.start()
        provider.files.append(
            file("new.PaRt", folder: folder, resourceID: "new-temp", size: 50)
        )
        watcher.folderDidChange()

        XCTAssertTrue(watcher.completions.isEmpty)
        XCTAssertEqual(watcher.health, .available)
        XCTAssertEqual(provider.requestedFolders, [folder])
        XCTAssertEqual(monitor.startedFolders, [folder])
        XCTAssertEqual(scheduler.activeEntries.map(\.date), [date(1_000.3)])
    }

    func testUnavailableFolderPublishesRussianHealthAndDoesNotMonitorOrPoll() {
        let folder = URL(fileURLWithPath: "/Missing", isDirectory: true)
        let provider = MutableFolderSnapshotProvider()
        provider.error = SnapshotFailure.unavailable
        let monitor = FolderEventMonitorDouble()
        let scheduler = ManualActivityScheduler()
        let watcher = makeWatcher(
            folder: folder,
            provider: provider,
            scheduler: scheduler,
            monitor: monitor
        )

        watcher.start()

        XCTAssertEqual(watcher.health, .unavailable(message: "Папка загрузок недоступна"))
        XCTAssertTrue(watcher.completions.isEmpty)
        XCTAssertEqual(monitor.startedFolders, [folder])
        XCTAssertEqual(monitor.stopCount, 1)
        XCTAssertTrue(scheduler.activeEntries.isEmpty)
        XCTAssertEqual(provider.requestedFolders, [folder])
    }

    func testStartArmsMonitorBeforeBaselineAndRollsBackMonitorWhenBaselineFails() {
        let folder = URL(fileURLWithPath: "/Downloads", isDirectory: true)
        var timeline: [String] = []
        let provider = MutableFolderSnapshotProvider()
        provider.onSnapshots = { timeline.append("snapshot") }
        let monitor = FolderEventMonitorDouble()
        monitor.onStart = { timeline.append("monitor") }
        let watcher = makeWatcher(folder: folder, provider: provider, monitor: monitor)

        watcher.start()

        XCTAssertEqual(timeline, ["monitor", "snapshot"])
        XCTAssertEqual(watcher.health, .available)

        let failingProvider = MutableFolderSnapshotProvider()
        failingProvider.error = SnapshotFailure.unavailable
        let failingMonitor = FolderEventMonitorDouble()
        let failingWatcher = makeWatcher(
            folder: folder,
            provider: failingProvider,
            monitor: failingMonitor
        )
        failingWatcher.start()
        XCTAssertEqual(failingMonitor.startedFolders, [folder])
        XCTAssertEqual(failingMonitor.stopCount, 1)
        XCTAssertEqual(
            failingWatcher.health,
            .unavailable(message: "Папка загрузок недоступна")
        )
    }

    func testStableFileEmitsOnlyAtExactOnePointFiveSecondBoundaryAndExactlyOnce() throws {
        let folder = URL(fileURLWithPath: "/Downloads", isDirectory: true)
        let clock = MutableActivityClock(now: date(1_000))
        let scheduler = ManualActivityScheduler()
        let provider = MutableFolderSnapshotProvider()
        let watcher = makeWatcher(
            folder: folder,
            provider: provider,
            clock: clock,
            scheduler: scheduler
        )
        watcher.start()
        provider.files = [file("archive.zip", resourceID: "archive", size: 100)]

        watcher.folderDidChange()
        clock.advance(by: 0.3)
        fire(try XCTUnwrap(scheduler.activeEntries.last))

        XCTAssertTrue(watcher.completions.isEmpty)
        XCTAssertEqual(scheduler.activeEntries.last?.date, date(1_001.8))

        clock.advance(by: 1.499)
        XCTAssertTrue(watcher.completions.isEmpty)
        clock.advance(by: 0.001)
        fire(try XCTUnwrap(scheduler.activeEntries.last))

        let completion = try XCTUnwrap(watcher.completions.first)
        XCTAssertEqual(watcher.completions.count, 1)
        XCTAssertEqual(completion.fileURL, folder.appendingPathComponent("archive.zip"))
        XCTAssertEqual(completion.occurredAt, date(1_001.8))
        XCTAssertFalse(completion.id.isEmpty)

        watcher.folderDidChange()
        clock.advance(by: 0.3)
        fire(try XCTUnwrap(scheduler.activeEntries.last))
        XCTAssertEqual(watcher.completions, [completion])
    }

    func testTemporaryRenameToFinalWithSameResourceIdentityEmitsImmediately() throws {
        let folder = URL(fileURLWithPath: "/Downloads", isDirectory: true)
        let clock = MutableActivityClock(now: date(1_000))
        let scheduler = ManualActivityScheduler()
        let provider = MutableFolderSnapshotProvider([
            file("archive.crdownload", folder: folder, resourceID: "transfer", size: 100)
        ])
        let watcher = makeWatcher(
            folder: folder,
            provider: provider,
            clock: clock,
            scheduler: scheduler
        )
        watcher.start()
        provider.files = [
            file("archive.zip", folder: folder, resourceID: "transfer", size: 100)
        ]

        watcher.folderDidChange()
        clock.advance(by: 0.3)
        fire(try XCTUnwrap(scheduler.activeEntries.last))

        XCTAssertEqual(watcher.completions.count, 1)
        XCTAssertEqual(watcher.completions.first?.fileURL, folder.appendingPathComponent("archive.zip"))
        XCTAssertEqual(watcher.completions.first?.occurredAt, date(1_000.3))
        XCTAssertTrue(scheduler.activeEntries.isEmpty)
    }

    func testRenameOfAlreadyEmittedResourceIdentityDoesNotPublishDuplicate() throws {
        let folder = URL(fileURLWithPath: "/Downloads", isDirectory: true)
        let clock = MutableActivityClock(now: date(1_000))
        let scheduler = ManualActivityScheduler()
        let provider = MutableFolderSnapshotProvider()
        let watcher = makeWatcher(
            folder: folder,
            provider: provider,
            clock: clock,
            scheduler: scheduler
        )
        watcher.start()
        provider.files = [file("first.zip", resourceID: "same-file", size: 100)]
        watcher.folderDidChange()
        clock.advance(by: 0.3)
        fire(try XCTUnwrap(scheduler.activeEntries.last))
        clock.advance(by: 1.5)
        fire(try XCTUnwrap(scheduler.activeEntries.last))
        let completion = try XCTUnwrap(watcher.completions.first)

        provider.files = [file("renamed.zip", resourceID: "same-file", size: 100)]
        watcher.folderDidChange()
        clock.advance(by: 0.3)
        fire(try XCTUnwrap(scheduler.activeEntries.last))

        XCTAssertEqual(watcher.completions, [completion])
        XCTAssertTrue(scheduler.activeEntries.isEmpty)
    }

    func testFingerprintChangeOfContinuouslyObservedEmittedResourceDoesNotPublishDuplicate() throws {
        let clock = MutableActivityClock(now: date(1_000))
        let scheduler = ManualActivityScheduler()
        let provider = MutableFolderSnapshotProvider()
        let watcher = makeWatcher(
            folder: URL(fileURLWithPath: "/Downloads", isDirectory: true),
            provider: provider,
            clock: clock,
            scheduler: scheduler
        )
        watcher.start()
        provider.files = [file("archive.zip", resourceID: "same-file", size: 100)]
        watcher.folderDidChange()
        clock.advance(by: 0.3)
        fire(try XCTUnwrap(scheduler.activeEntries.last))
        clock.advance(by: 1.5)
        fire(try XCTUnwrap(scheduler.activeEntries.last))
        let completion = try XCTUnwrap(watcher.completions.first)

        provider.files = [
            file("archive.zip", resourceID: "same-file", size: 101, modifiedAt: 901)
        ]
        watcher.folderDidChange()
        clock.advance(by: 0.3)
        fire(try XCTUnwrap(scheduler.activeEntries.last))
        clock.advance(by: 1.5)
        watcher.folderDidChange()
        clock.advance(by: 0.3)
        fire(try XCTUnwrap(scheduler.activeEntries.last))

        XCTAssertEqual(watcher.completions, [completion])
    }

    func testOneMetadataGapBeforeRenameKeepsEmittedResourceExactlyOnce() throws {
        let folder = URL(fileURLWithPath: "/Downloads", isDirectory: true)
        let clock = MutableActivityClock(now: date(1_000))
        let scheduler = ManualActivityScheduler()
        let provider = MutableFolderSnapshotProvider()
        let watcher = makeWatcher(
            folder: folder,
            provider: provider,
            clock: clock,
            scheduler: scheduler
        )
        watcher.start()
        provider.files = [file("before.zip", folder: folder, resourceID: "same-file", size: 100)]
        watcher.folderDidChange()
        clock.advance(by: 0.3)
        fire(try XCTUnwrap(scheduler.activeEntries.last))
        clock.advance(by: 1.5)
        fire(try XCTUnwrap(scheduler.activeEntries.last))
        let completion = try XCTUnwrap(watcher.completions.first)

        provider.files = []
        watcher.folderDidChange()
        clock.advance(by: 0.3)
        fire(try XCTUnwrap(scheduler.activeEntries.last))
        provider.files = [file("after.zip", folder: folder, resourceID: "same-file", size: 100)]
        watcher.folderDidChange()
        clock.advance(by: 0.3)
        fire(try XCTUnwrap(scheduler.activeEntries.last))
        clock.advance(by: 1.5)
        watcher.folderDidChange()
        clock.advance(by: 0.3)
        fire(try XCTUnwrap(scheduler.activeEntries.last))

        XCTAssertEqual(watcher.completions, [completion])
    }

    func testOneMetadataGapBeforeRenameKeepsBaselineResourceSilent() throws {
        let folder = URL(fileURLWithPath: "/Downloads", isDirectory: true)
        let clock = MutableActivityClock(now: date(1_000))
        let scheduler = ManualActivityScheduler()
        let provider = MutableFolderSnapshotProvider([
            file("before.zip", folder: folder, resourceID: "baseline", size: 100)
        ])
        let watcher = makeWatcher(
            folder: folder,
            provider: provider,
            clock: clock,
            scheduler: scheduler
        )
        watcher.start()

        provider.files = []
        watcher.folderDidChange()
        clock.advance(by: 0.3)
        fire(try XCTUnwrap(scheduler.activeEntries.last))
        provider.files = [
            file("after.zip", folder: folder, resourceID: "baseline", size: 101, modifiedAt: 901)
        ]
        watcher.folderDidChange()
        clock.advance(by: 0.3)
        fire(try XCTUnwrap(scheduler.activeEntries.last))

        XCTAssertTrue(watcher.completions.isEmpty)
        XCTAssertTrue(scheduler.activeEntries.isEmpty)
    }

    func testTwoConsecutiveMissingScansConfirmDeletionAndAllowResourceIdentityReuse() throws {
        let folder = URL(fileURLWithPath: "/Downloads", isDirectory: true)
        let clock = MutableActivityClock(now: date(1_000))
        let scheduler = ManualActivityScheduler()
        let provider = MutableFolderSnapshotProvider()
        let watcher = makeWatcher(
            folder: folder,
            provider: provider,
            clock: clock,
            scheduler: scheduler
        )
        watcher.start()
        provider.files = [file("first.zip", folder: folder, resourceID: "reused", size: 100)]
        watcher.folderDidChange()
        clock.advance(by: 0.3)
        fire(try XCTUnwrap(scheduler.activeEntries.last))
        clock.advance(by: 1.5)
        fire(try XCTUnwrap(scheduler.activeEntries.last))
        let firstCompletion = try XCTUnwrap(watcher.completions.first)

        provider.files = []
        watcher.folderDidChange()
        clock.advance(by: 0.3)
        fire(try XCTUnwrap(scheduler.activeEntries.last))
        watcher.folderDidChange()
        clock.advance(by: 0.3)
        fire(try XCTUnwrap(scheduler.activeEntries.last))

        provider.files = [
            file("second.zip", folder: folder, resourceID: "reused", size: 200, modifiedAt: 902)
        ]
        watcher.folderDidChange()
        clock.advance(by: 0.3)
        fire(try XCTUnwrap(scheduler.activeEntries.last))
        clock.advance(by: 1.5)
        watcher.folderDidChange()
        clock.advance(by: 0.3)
        fire(try XCTUnwrap(scheduler.activeEntries.last))

        XCTAssertEqual(watcher.completions.count, 2)
        XCTAssertEqual(watcher.completions.last?.fileURL, folder.appendingPathComponent("second.zip"))
        XCTAssertNotEqual(watcher.completions.last?.id, firstCompletion.id)
    }

    func testSingleMissingScanSchedulesBoundedConfirmationAndAllowsResourceIdentityReuse() throws {
        let folder = URL(fileURLWithPath: "/Downloads", isDirectory: true)
        let clock = MutableActivityClock(now: date(1_000))
        let scheduler = ManualActivityScheduler()
        let provider = MutableFolderSnapshotProvider()
        let watcher = makeWatcher(
            folder: folder,
            provider: provider,
            clock: clock,
            scheduler: scheduler
        )
        watcher.start()
        provider.files = [file("first.zip", folder: folder, resourceID: "reused", size: 100)]
        watcher.folderDidChange()
        clock.advance(by: 0.3)
        fire(try XCTUnwrap(scheduler.activeEntries.last))
        clock.advance(by: 1.5)
        fire(try XCTUnwrap(scheduler.activeEntries.last))

        provider.files = []
        watcher.folderDidChange()
        clock.advance(by: 0.3)
        fire(try XCTUnwrap(scheduler.activeEntries.last))
        let confirmation = try XCTUnwrap(scheduler.activeEntries.last)
        XCTAssertEqual(
            confirmation.date.timeIntervalSince1970,
            1_003.6,
            accuracy: 0.000_001
        )
        clock.advance(by: 1.5)
        fire(confirmation)

        provider.files = [
            file("second.zip", folder: folder, resourceID: "reused", size: 200, modifiedAt: 902)
        ]
        watcher.folderDidChange()
        clock.advance(by: 0.3)
        fire(try XCTUnwrap(scheduler.activeEntries.last))
        clock.advance(by: 1.5)
        fire(try XCTUnwrap(scheduler.activeEntries.last))

        XCTAssertEqual(watcher.completions.count, 2)
        XCTAssertEqual(watcher.completions.last?.fileURL, folder.appendingPathComponent("second.zip"))
    }

    func testSizeAndModificationChangesEachRestartFullStabilityWindow() throws {
        let clock = MutableActivityClock(now: date(1_000))
        let scheduler = ManualActivityScheduler()
        let provider = MutableFolderSnapshotProvider()
        let watcher = makeWatcher(
            folder: URL(fileURLWithPath: "/Downloads", isDirectory: true),
            provider: provider,
            clock: clock,
            scheduler: scheduler
        )
        watcher.start()
        provider.files = [file("archive.zip", resourceID: "archive", size: 100, modifiedAt: 900)]
        watcher.folderDidChange()
        clock.advance(by: 0.3)
        fire(try XCTUnwrap(scheduler.activeEntries.last))

        provider.files = [file("archive.zip", resourceID: "archive", size: 101, modifiedAt: 900)]
        clock.advance(by: 1.5)
        fire(try XCTUnwrap(scheduler.activeEntries.last))
        XCTAssertTrue(watcher.completions.isEmpty)
        XCTAssertEqual(scheduler.activeEntries.last?.date, date(1_003.3))

        provider.files = [file("archive.zip", resourceID: "archive", size: 101, modifiedAt: 901)]
        clock.advance(by: 1.5)
        fire(try XCTUnwrap(scheduler.activeEntries.last))
        XCTAssertTrue(watcher.completions.isEmpty)
        XCTAssertEqual(scheduler.activeEntries.last?.date, date(1_004.8))

        clock.advance(by: 1.5)
        fire(try XCTUnwrap(scheduler.activeEntries.last))
        XCTAssertEqual(watcher.completions.count, 1)
        XCTAssertEqual(watcher.completions.first?.occurredAt, date(1_004.8))
    }

    func testSamePathWithNewResourceIdentityAfterRemovalEmitsNewStableCompletion() throws {
        let folder = URL(fileURLWithPath: "/Downloads", isDirectory: true)
        let clock = MutableActivityClock(now: date(1_000))
        let scheduler = ManualActivityScheduler()
        let provider = MutableFolderSnapshotProvider()
        let watcher = makeWatcher(
            folder: folder,
            provider: provider,
            clock: clock,
            scheduler: scheduler
        )
        watcher.start()

        provider.files = [
            file("archive.zip", folder: folder, resourceID: "old-identity", size: 100)
        ]
        watcher.folderDidChange()
        clock.advance(by: 0.3)
        fire(try XCTUnwrap(scheduler.activeEntries.last))
        clock.advance(by: 1.5)
        fire(try XCTUnwrap(scheduler.activeEntries.last))
        let firstCompletion = try XCTUnwrap(watcher.completions.first)

        provider.files = []
        watcher.folderDidChange()
        clock.advance(by: 0.3)
        fire(try XCTUnwrap(scheduler.activeEntries.last))
        provider.files = [
            file("archive.zip", folder: folder, resourceID: "new-identity", size: 100)
        ]
        watcher.folderDidChange()
        clock.advance(by: 0.3)
        fire(try XCTUnwrap(scheduler.activeEntries.last))
        clock.advance(by: 1.5)
        fire(try XCTUnwrap(scheduler.activeEntries.last))

        XCTAssertEqual(watcher.completions.count, 2)
        XCTAssertEqual(watcher.completions.map(\.fileURL), [
            folder.appendingPathComponent("archive.zip"),
            folder.appendingPathComponent("archive.zip")
        ])
        XCTAssertNotEqual(watcher.completions.last?.id, firstCompletion.id)
    }

    func testNilResourceIdentityPathReuseWithChangedFingerprintEmitsSecondCompletion() throws {
        let folder = URL(fileURLWithPath: "/Downloads", isDirectory: true)
        let clock = MutableActivityClock(now: date(1_000))
        let scheduler = ManualActivityScheduler()
        let provider = MutableFolderSnapshotProvider()
        let watcher = makeWatcher(
            folder: folder,
            provider: provider,
            clock: clock,
            scheduler: scheduler
        )
        watcher.start()
        provider.files = [file("archive.zip", resourceID: nil, size: 100, modifiedAt: 900)]
        watcher.folderDidChange()
        clock.advance(by: 0.3)
        fire(try XCTUnwrap(scheduler.activeEntries.last))
        clock.advance(by: 1.5)
        fire(try XCTUnwrap(scheduler.activeEntries.last))
        let first = try XCTUnwrap(watcher.completions.first)

        provider.files = [file("archive.zip", resourceID: nil, size: 200, modifiedAt: 901)]
        watcher.folderDidChange()
        clock.advance(by: 0.3)
        fire(try XCTUnwrap(scheduler.activeEntries.last))
        XCTAssertEqual(watcher.completions, [first])
        let secondDeadline = try XCTUnwrap(scheduler.activeEntries.last?.date)
        XCTAssertEqual(
            secondDeadline.timeIntervalSince1970,
            1_003.6,
            accuracy: 0.000_001
        )
        clock.advance(by: 1.5)
        fire(try XCTUnwrap(scheduler.activeEntries.last))

        XCTAssertEqual(watcher.completions.count, 2)
        XCTAssertNotEqual(watcher.completions.last?.id, first.id)
        XCTAssertEqual(watcher.completions.last?.fileURL, folder.appendingPathComponent("archive.zip"))
    }

    func testCanonicalOwnSuppressionIsActiveBeforeTenSecondsAndConsumedOnce() throws {
        let folder = URL(fileURLWithPath: "/Downloads", isDirectory: true)
        let clock = MutableActivityClock(now: date(1_000))
        let scheduler = ManualActivityScheduler()
        let provider = MutableFolderSnapshotProvider()
        let watcher = makeWatcher(
            folder: folder,
            provider: provider,
            clock: clock,
            scheduler: scheduler
        )
        watcher.start()
        watcher.suppressOwnCompletion(
            fileURL: URL(fileURLWithPath: "/Downloads/subfolder/../archive.zip"),
            at: date(991.801)
        )
        provider.files = [file("archive.zip", resourceID: "first", size: 100)]

        watcher.folderDidChange()
        clock.advance(by: 0.3)
        fire(try XCTUnwrap(scheduler.activeEntries.last))
        clock.advance(by: 1.5)
        fire(try XCTUnwrap(scheduler.activeEntries.last))
        XCTAssertTrue(watcher.completions.isEmpty)

        provider.files = []
        watcher.folderDidChange()
        clock.advance(by: 0.3)
        fire(try XCTUnwrap(scheduler.activeEntries.last))
        provider.files = [file("archive.zip", resourceID: "second", size: 100)]
        watcher.folderDidChange()
        clock.advance(by: 0.3)
        fire(try XCTUnwrap(scheduler.activeEntries.last))
        clock.advance(by: 1.5)
        fire(try XCTUnwrap(scheduler.activeEntries.last))

        XCTAssertEqual(watcher.completions.count, 1)
    }

    func testOwnSuppressionExpiresAtExactTenSecondBoundary() throws {
        let folder = URL(fileURLWithPath: "/Downloads", isDirectory: true)
        let clock = MutableActivityClock(now: date(1_000))
        let scheduler = ManualActivityScheduler()
        let provider = MutableFolderSnapshotProvider()
        let watcher = makeWatcher(
            folder: folder,
            provider: provider,
            clock: clock,
            scheduler: scheduler
        )
        watcher.start()
        watcher.suppressOwnCompletion(
            fileURL: folder.appendingPathComponent("archive.zip"),
            at: date(991.8)
        )
        provider.files = [file("archive.zip", resourceID: "archive", size: 100)]

        watcher.folderDidChange()
        clock.advance(by: 0.3)
        fire(try XCTUnwrap(scheduler.activeEntries.last))
        clock.advance(by: 1.5)
        fire(try XCTUnwrap(scheduler.activeEntries.last))

        XCTAssertEqual(watcher.completions.count, 1)
        XCTAssertEqual(watcher.completions.first?.occurredAt, date(1_001.8))
    }

    func testOwnSuppressionSchedulesExactCleanupAndStaleCleanupCannotDeleteRefresh() throws {
        let folder = URL(fileURLWithPath: "/Downloads", isDirectory: true)
        let clock = MutableActivityClock(now: date(1_000))
        let scheduler = ManualActivityScheduler()
        let provider = MutableFolderSnapshotProvider([
            file("archive.part", folder: folder, resourceID: "transfer", size: 100)
        ])
        let watcher = makeWatcher(
            folder: folder,
            provider: provider,
            clock: clock,
            scheduler: scheduler
        )
        watcher.start()
        let destination = folder.appendingPathComponent("archive.zip")

        watcher.suppressOwnCompletion(fileURL: destination, at: date(1_000))
        let firstCleanup = try XCTUnwrap(scheduler.entries.last)
        XCTAssertEqual(firstCleanup.date, date(1_010))
        clock.advance(by: 1)
        watcher.suppressOwnCompletion(fileURL: destination, at: date(1_001))
        let secondCleanup = try XCTUnwrap(scheduler.entries.last)
        XCTAssertTrue(firstCleanup.cancellation.isCancelled)
        XCTAssertEqual(secondCleanup.date, date(1_011))

        clock.advance(by: 9)
        firstCleanup.action()
        provider.files = [
            file("archive.zip", folder: folder, resourceID: "transfer", size: 100)
        ]
        watcher.folderDidChange()
        clock.advance(by: 0.3)
        fire(try XCTUnwrap(scheduler.activeEntries.last))

        XCTAssertTrue(watcher.completions.isEmpty)
        XCTAssertTrue(secondCleanup.cancellation.isCancelled)
    }

    func testOwnCompletionPublisherSuppressesManagerDestinationEndToEnd() throws {
        let folder = URL(fileURLWithPath: "/Downloads", isDirectory: true)
        let defaults = UserDefaults(suiteName: "DownloadsFolderWatcherManager-\(UUID().uuidString)")!
        let settings = ActivitySettings(defaults: defaults, homeDirectory: folder.deletingLastPathComponent())
        settings.downloadsFolder = folder
        let clock = MutableActivityClock(now: date(1_000))
        let scheduler = ManualActivityScheduler()
        let transport = FakeDownloadTransport()
        let manager = DownloadManager(
            clock: clock,
            scheduler: scheduler,
            persistence: MemoryDownloadPersistence(),
            transport: transport,
            settings: settings,
            fileOperations: DownloadFileOperations(
                createDirectory: { _ in },
                fileExists: { _ in false },
                moveItem: { _, _ in }
            )
        )
        let provider = MutableFolderSnapshotProvider()
        let watcher = DownloadsFolderWatcher(
            settings: settings,
            clock: clock,
            scheduler: scheduler,
            snapshotProvider: provider,
            ownCompletionPublisher: manager.ownCompletionPublisher,
            eventMonitor: FolderEventMonitorDouble()
        )
        watcher.start()
        try manager.start()
        let id = try manager.enqueue("https://example.com/archive.zip")

        transport.send(.finished(
            id: id,
            temporaryURL: URL(fileURLWithPath: "/tmp/transfer"),
            suggestedFilename: "archive.zip"
        ))
        provider.files = [file("archive.zip", resourceID: "manager-file", size: 100)]
        watcher.folderDidChange()
        clock.advance(by: 0.3)
        fire(try XCTUnwrap(scheduler.activeEntries.last))
        clock.advance(by: 1.5)
        fire(try XCTUnwrap(scheduler.activeEntries.last))

        XCTAssertEqual(manager.downloads.first?.destinationURL, folder.appendingPathComponent("archive.zip"))
        XCTAssertTrue(watcher.completions.isEmpty)
    }

    func testBurstDebounceCancelsEarlierWakeAndStaleCallbackCannotScan() throws {
        let folder = URL(fileURLWithPath: "/Downloads", isDirectory: true)
        let clock = MutableActivityClock(now: date(1_000))
        let scheduler = ManualActivityScheduler()
        let provider = MutableFolderSnapshotProvider()
        let watcher = makeWatcher(
            folder: folder,
            provider: provider,
            clock: clock,
            scheduler: scheduler
        )
        watcher.start()

        watcher.folderDidChange()
        let first = try XCTUnwrap(scheduler.entries.last)
        clock.advance(by: 0.1)
        watcher.folderDidChange()
        let second = try XCTUnwrap(scheduler.entries.last)

        XCTAssertTrue(first.cancellation.isCancelled)
        XCTAssertEqual(second.date, date(1_000.4))
        first.action()
        XCTAssertEqual(provider.requestedFolders, [folder])

        clock.advance(by: 0.3)
        fire(second)
        XCTAssertEqual(provider.requestedFolders, [folder, folder])
    }

    func testStopRestartCancelsOldWakeAndBuildsFreshBaselineWithoutOldFiles() throws {
        let folder = URL(fileURLWithPath: "/Downloads", isDirectory: true)
        let clock = MutableActivityClock(now: date(1_000))
        let scheduler = ManualActivityScheduler()
        let provider = MutableFolderSnapshotProvider()
        let monitor = FolderEventMonitorDouble()
        let watcher = makeWatcher(
            folder: folder,
            provider: provider,
            clock: clock,
            scheduler: scheduler,
            monitor: monitor
        )
        watcher.start()
        watcher.folderDidChange()
        let staleWake = try XCTUnwrap(scheduler.entries.last)
        provider.files = [file("during-stop.zip", resourceID: "stopped", size: 100)]

        watcher.stop()
        watcher.start()
        staleWake.action()

        XCTAssertEqual(provider.requestedFolders, [folder, folder])
        XCTAssertEqual(monitor.startedFolders, [folder, folder])
        XCTAssertEqual(monitor.stopCount, 1)
        XCTAssertTrue(watcher.completions.isEmpty)
        XCTAssertTrue(scheduler.activeEntries.isEmpty)
    }

    func testFolderSettingReplacementClosesOldMonitorRecoversHealthAndBaselinesNewFolder() {
        let oldFolder = URL(fileURLWithPath: "/Missing", isDirectory: true)
        let newFolder = URL(fileURLWithPath: "/NewDownloads", isDirectory: true)
        let defaults = UserDefaults(suiteName: "DownloadsFolderWatcherSettings-\(UUID().uuidString)")!
        let settings = ActivitySettings(
            defaults: defaults,
            homeDirectory: oldFolder.deletingLastPathComponent()
        )
        settings.downloadsFolder = oldFolder
        let provider = MutableFolderSnapshotProvider()
        provider.error = SnapshotFailure.unavailable
        let monitor = FolderEventMonitorDouble()
        let watcher = DownloadsFolderWatcher(
            settings: settings,
            clock: MutableActivityClock(now: date(1_000)),
            scheduler: ManualActivityScheduler(),
            snapshotProvider: provider,
            ownCompletionPublisher: Empty(completeImmediately: false).eraseToAnyPublisher(),
            eventMonitor: monitor
        )
        watcher.start()
        XCTAssertEqual(watcher.health, .unavailable(message: "Папка загрузок недоступна"))

        provider.error = nil
        provider.files = [file("existing.zip", folder: newFolder, resourceID: "baseline", size: 100)]
        settings.downloadsFolder = newFolder

        XCTAssertEqual(provider.requestedFolders, [oldFolder, newFolder])
        XCTAssertEqual(monitor.startedFolders, [oldFolder, newFolder])
        XCTAssertEqual(monitor.stopCount, 1)
        XCTAssertEqual(watcher.health, .available)
        XCTAssertTrue(watcher.completions.isEmpty)
    }

    func testFolderRenameEventClosesDescriptorAndRebuildsBaseline() throws {
        let folder = URL(fileURLWithPath: "/Downloads", isDirectory: true)
        let provider = MutableFolderSnapshotProvider()
        let monitor = FolderEventMonitorDouble()
        let scheduler = ManualActivityScheduler()
        let watcher = makeWatcher(
            folder: folder,
            provider: provider,
            scheduler: scheduler,
            monitor: monitor
        )
        watcher.start()
        provider.files = [file("after-rename.zip", resourceID: "replacement", size: 100)]

        monitor.send(.folderReplaced, fromStart: 0)

        XCTAssertEqual(monitor.stopCount, 1)
        XCTAssertEqual(monitor.startedFolders, [folder, folder])
        XCTAssertEqual(provider.requestedFolders, [folder, folder])
        XCTAssertTrue(watcher.completions.isEmpty)
        XCTAssertTrue(scheduler.activeEntries.isEmpty)
    }

    private func makeWatcher(
        folder: URL,
        provider: MutableFolderSnapshotProvider,
        clock: MutableActivityClock = MutableActivityClock(now: date(1_000)),
        scheduler: ManualActivityScheduler? = nil,
        monitor: FolderEventMonitorDouble? = nil,
        ownCompletions: AnyPublisher<OwnDownloadCompletion, Never> = Empty(
            completeImmediately: false
        ).eraseToAnyPublisher()
    ) -> DownloadsFolderWatcher {
        let defaults = UserDefaults(suiteName: "DownloadsFolderWatcherTests-\(UUID().uuidString)")!
        let settings = ActivitySettings(
            defaults: defaults,
            homeDirectory: folder.deletingLastPathComponent()
        )
        settings.downloadsFolder = folder
        return DownloadsFolderWatcher(
            settings: settings,
            clock: clock,
            scheduler: scheduler ?? ManualActivityScheduler(),
            snapshotProvider: provider,
            ownCompletionPublisher: ownCompletions,
            eventMonitor: monitor ?? FolderEventMonitorDouble()
        )
    }

    private func fire(_ entry: ManualActivityScheduler.Entry) {
        entry.cancellation.cancel()
        entry.action()
    }
}

private enum SnapshotFailure: Error {
    case unavailable
}

private final class FolderDescriptorOperationsDouble {
    struct OpenCall: Equatable {
        let path: String
        let flags: Int32
    }

    var nextDescriptors: [Int32] = [41, 42]
    private(set) var openCalls: [OpenCall] = []
    private(set) var closedDescriptors: [Int32] = []

    var operations: DownloadsFolderDescriptorOperations {
        DownloadsFolderDescriptorOperations(
            open: { [weak self] path, flags in
                guard let self else { return -1 }
                self.openCalls.append(.init(path: path, flags: flags))
                return self.nextDescriptors.removeFirst()
            },
            close: { [weak self] descriptor in
                self?.closedDescriptors.append(descriptor)
            }
        )
    }
}

private final class FolderDispatchSourceDouble: DownloadsFolderDispatchSource {
    var data: DispatchSource.FileSystemEvent = []
    private var eventHandler: (() -> Void)?
    private var cancelHandler: (() -> Void)?
    private(set) var resumeCount = 0
    private(set) var cancelCount = 0

    func setEventHandler(_ handler: @escaping () -> Void) {
        eventHandler = handler
    }

    func setCancelHandler(_ handler: @escaping () -> Void) {
        cancelHandler = handler
    }

    func resume() {
        resumeCount += 1
    }

    func cancel() {
        cancelCount += 1
    }

    func fireEvent() {
        eventHandler?()
    }

    func fireCancel() {
        cancelHandler?()
    }
}

private final class MutableFolderSnapshotProvider: FolderSnapshotProviding {
    var files: [FolderFileSnapshot]
    var error: Error?
    var onSnapshots: (() -> Void)?
    private(set) var requestedFolders: [URL] = []

    init(_ files: [FolderFileSnapshot] = []) {
        self.files = files
    }

    func snapshots(in folder: URL) throws -> [FolderFileSnapshot] {
        requestedFolders.append(folder)
        onSnapshots?()
        if let error { throw error }
        return files
    }
}

@MainActor
private final class FolderEventMonitorDouble: DownloadsFolderEventMonitoring {
    var onStart: (() -> Void)?
    private(set) var startedFolders: [URL] = []
    private(set) var stopCount = 0
    private(set) var handlers: [@MainActor (DownloadsFolderEvent) -> Void] = []

    func start(
        folder: URL,
        handler: @escaping @MainActor (DownloadsFolderEvent) -> Void
    ) throws {
        onStart?()
        startedFolders.append(folder)
        handlers.append(handler)
    }

    func stop() {
        stopCount += 1
    }

    func send(_ event: DownloadsFolderEvent, fromStart index: Int) {
        handlers[index](event)
    }
}

private func file(
    _ name: String,
    folder: URL = URL(fileURLWithPath: "/Downloads", isDirectory: true),
    resourceID: AnyHashable? = nil,
    size: Int64,
    modifiedAt: TimeInterval = 900
) -> FolderFileSnapshot {
    FolderFileSnapshot(
        url: folder.appendingPathComponent(name),
        fileResourceIdentifier: resourceID,
        size: size,
        modifiedAt: date(modifiedAt)
    )
}

private func date(_ seconds: TimeInterval) -> Date {
    Date(timeIntervalSince1970: seconds)
}
