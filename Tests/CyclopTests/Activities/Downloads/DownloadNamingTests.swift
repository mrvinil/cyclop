import Foundation
import XCTest
@testable import Cyclop

final class DownloadNamingTests: XCTestCase {
    private let folder = URL(
        fileURLWithPath: "/private/tmp/Cyclop Download Naming",
        isDirectory: true
    )

    func testUsesResponseFilenameThenDecodedURLComponentThenDownloadFallback() {
        XCTAssertEqual(
            destination(
                responseFilename: "server-name.bin",
                remoteURL: "https://example.com/url-name.zip"
            ).lastPathComponent,
            "server-name.bin"
        )
        XCTAssertEqual(
            destination(
                responseFilename: nil,
                remoteURL: "https://example.com/%D0%BE%D1%82%D1%87%D1%91%D1%82%20%F0%9F%9A%80.zip"
            ).lastPathComponent,
            "отчёт 🚀.zip"
        )
        XCTAssertEqual(
            destination(
                responseFilename: nil,
                remoteURL: "https://example.com?token=secret"
            ).lastPathComponent,
            "Загрузка"
        )
    }

    func testEmptyAndTraversalOnlySuggestionsFallBackToURLThenDownload() {
        for responseFilename in ["", "   ", ".", "..", "../../", "..\\..\\"] {
            XCTAssertEqual(
                destination(
                    responseFilename: responseFilename,
                    remoteURL: "https://example.com/fallback.zip"
                ).lastPathComponent,
                "fallback.zip"
            )
        }

        XCTAssertEqual(
            destination(responseFilename: "..", remoteURL: "https://example.com").lastPathComponent,
            "Загрузка"
        )
    }

    func testDropsTraversalComponentsAndSanitizesBackslashColonNULAndControls() {
        XCTAssertEqual(
            destination(
                responseFilename: "../../archive.zip",
                remoteURL: "https://example.com/fallback"
            ).lastPathComponent,
            "archive.zip"
        )
        XCTAssertEqual(
            destination(
                responseFilename: "..\\..\\secret.txt",
                remoteURL: "https://example.com/fallback"
            ).lastPathComponent,
            "secret.txt"
        )
        XCTAssertEqual(
            destination(
                responseFilename: "report:\u{0000}\u{0001}\u{007F}.zip",
                remoteURL: "https://example.com/fallback"
            ).lastPathComponent,
            "report____.zip"
        )
    }

    func testRemovesBidiFormatControlsPreservesZWJAndUsesRussianFallback() {
        XCTAssertEqual(
            destination(
                responseFilename: "safe\u{202E}gpj.exe\u{2066}.zip",
                remoteURL: "https://example.com/fallback"
            ).lastPathComponent,
            "safegpj.exe.zip"
        )
        XCTAssertEqual(
            destination(
                responseFilename: "семья 👩‍👩‍👧‍👦.zip",
                remoteURL: "https://example.com/fallback"
            ).lastPathComponent,
            "семья 👩‍👩‍👧‍👦.zip"
        )
        XCTAssertEqual(
            destination(responseFilename: nil, remoteURL: "https://example.com")
                .lastPathComponent,
            "Загрузка"
        )
    }

    func testPreservesSafeDotfileCyrillicAndEmojiNamesDeterministically() {
        for name in [".env", "данные.json", "архив 🛰️.zip"] {
            XCTAssertEqual(
                destination(
                    responseFilename: name,
                    remoteURL: "https://example.com/fallback"
                ).lastPathComponent,
                name
            )
        }
    }

    func testNeverLeavesExactFolderAndUsesFullCandidatePathForCollisionChecks() {
        var checkedPaths: [String] = []
        let existing = Set([
            folder.appendingPathComponent("archive.zip").path,
            folder.appendingPathComponent("archive (2).zip").path,
        ])

        let result = DownloadNaming.destination(
            folder: folder,
            responseFilename: "../../archive.zip",
            remoteURL: URL(string: "https://example.com/fallback")!,
            fileExists: { path in
                checkedPaths.append(path)
                return existing.contains(path)
            }
        )

        XCTAssertEqual(result.lastPathComponent, "archive (3).zip")
        XCTAssertEqual(result.deletingLastPathComponent(), folder)
        XCTAssertEqual(
            checkedPaths,
            [
                folder.appendingPathComponent("archive.zip").path,
                folder.appendingPathComponent("archive (2).zip").path,
                folder.appendingPathComponent("archive (3).zip").path,
            ]
        )
    }

    func testAddsCollisionSuffixForNamesWithoutExtension() {
        let originalPath = folder.appendingPathComponent("README").path

        let result = DownloadNaming.destination(
            folder: folder,
            responseFilename: "README",
            remoteURL: URL(string: "https://example.com/fallback")!,
            fileExists: { $0 == originalPath }
        )

        XCTAssertEqual(result.lastPathComponent, "README (2)")
    }

    func testLimitsUnicodeNameTo240UTF8BytesWithoutSplittingGraphemeAndPreservesExtension() {
        let grapheme = "👩🏽‍💻"
        let result = destination(
            responseFilename: String(repeating: grapheme, count: 40) + ".zip",
            remoteURL: "https://example.com/fallback"
        ).lastPathComponent

        XCTAssertLessThanOrEqual(result.utf8.count, 240)
        XCTAssertTrue(result.hasSuffix(".zip"))
        let base = String(result.dropLast(4))
        XCTAssertFalse(base.isEmpty)
        XCTAssertTrue(base.allSatisfy { String($0) == grapheme })
    }

    func testCollisionSuffixIsIncludedInByteLimitWhileExtensionIsPreserved() {
        let longName = String(repeating: "я", count: 160) + ".archive"
        var checks = 0

        let result = DownloadNaming.destination(
            folder: folder,
            responseFilename: longName,
            remoteURL: URL(string: "https://example.com/fallback")!,
            fileExists: { _ in
                checks += 1
                return checks < 1_000
            }
        ).lastPathComponent

        XCTAssertEqual(checks, 1_000)
        XCTAssertLessThanOrEqual(result.utf8.count, 240)
        XCTAssertTrue(result.hasSuffix(" (1000).archive"))
    }

    func testPreservesExtensionWhenItExactlyFills240ByteLimit() {
        let extensionOnly = "." + String(repeating: "a", count: 239)

        let result = destination(
            responseFilename: "base" + extensionOnly,
            remoteURL: "https://example.com/fallback"
        ).lastPathComponent

        XCTAssertEqual(result, extensionOnly)
        XCTAssertEqual(result.utf8.count, 240)
    }

    func testDoesNotCreateOrAccessAbsentFolderOutsideInjectedExistenceCheck() {
        let absentFolder = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "CyclopAbsentDownloads-\(UUID().uuidString)",
                isDirectory: true
            )
        var checkedPaths: [String] = []
        XCTAssertFalse(FileManager.default.fileExists(atPath: absentFolder.path))

        let result = DownloadNaming.destination(
            folder: absentFolder,
            responseFilename: "archive.zip",
            remoteURL: URL(string: "https://example.com/fallback")!,
            fileExists: { path in
                checkedPaths.append(path)
                return false
            }
        )

        XCTAssertEqual(result, absentFolder.appendingPathComponent("archive.zip"))
        XCTAssertEqual(checkedPaths, [result.path])
        XCTAssertFalse(FileManager.default.fileExists(atPath: absentFolder.path))
    }

    private func destination(
        responseFilename: String?,
        remoteURL: String
    ) -> URL {
        DownloadNaming.destination(
            folder: folder,
            responseFilename: responseFilename,
            remoteURL: URL(string: remoteURL)!,
            fileExists: { _ in false }
        )
    }
}
