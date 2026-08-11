import Foundation
import XCTest
@testable import Cyclop

final class DownloadRequestTests: XCTestCase {
    func testAcceptsTrimmedAbsoluteHTTPAndHTTPSCaseInsensitively() throws {
        let https = try DownloadRequestParser.parse("  \nHTTPS://example.com/archive.zip\t")
        let http = try DownloadRequestParser.parse("http://example.com/archive.zip")

        XCTAssertEqual(https.absoluteString, "HTTPS://example.com/archive.zip")
        XCTAssertEqual(https.scheme?.lowercased(), "https")
        XCTAssertEqual(https.host, "example.com")
        XCTAssertEqual(http.scheme, "http")
        XCTAssertEqual(http.host, "example.com")
    }

    func testRejectsEmptyInputWithExactError() {
        for value in ["", " ", "\n\t"] {
            assertParse(value, throws: .empty)
        }
    }

    func testRejectsUnsupportedAndNonAbsoluteSchemesWithExactError() {
        for value in [
            "file:///tmp/archive.zip",
            "ftp://example.com/archive.zip",
            "javascript:alert(1)",
            "example.com/archive.zip",
            "/archive.zip",
            "//example.com/archive.zip",
        ] {
            assertParse(value, throws: .unsupportedScheme)
        }
    }

    func testRejectsHTTPURLsWithoutNonemptyHostWithExactError() {
        for value in [
            "https://",
            "https:///archive.zip",
            "http:/archive.zip",
        ] {
            assertParse(value, throws: .missingHost)
        }
    }

    func testRejectsMalformedURLWithExactError() {
        for value in [
            "https://exa mple.com/archive.zip",
            "https://example.com:invalid/archive.zip",
            "https://example.com/archive name.zip",
            "https://example.com/archive\tname.zip",
            "https://example.com/archive\nname.zip",
            "https://example.com/%ZZ.zip",
        ] {
            assertParse(value, throws: .malformedURL)
        }
    }

    func testRejectsEmbeddedUserOrPasswordCredentialsWithExactError() {
        for value in [
            "https://user@example.com/archive.zip",
            "https://user:password@example.com/archive.zip",
            "https://:password@example.com/archive.zip",
        ] {
            assertParse(value, throws: .credentialsNotSupported)
        }
    }

    private func assertParse(
        _ raw: String,
        throws expected: DownloadRequestError,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(
            try DownloadRequestParser.parse(raw),
            file: file,
            line: line
        ) { error in
            XCTAssertEqual(error as? DownloadRequestError, expected, file: file, line: line)
        }
    }
}
