import XCTest
@testable import Cyclop

final class GenreAnimationCatalogTests: XCTestCase {
    func testGenreCatalogMapsKnownTagsAndFallsBackToUniversal() {
        XCTAssertEqual(GenreAnimationCatalog.style(for: "alternativemetal"), .metal)
        XCTAssertEqual(GenreAnimationCatalog.style(for: "BREAKBEATGENRE"), .breakbeat)
        XCTAssertEqual(GenreAnimationCatalog.style(for: "unknown-tag"), .universal)
    }

    func testGenreCatalogMapsEveryStyle() {
        let expected: [(String, MediaAnimationStyle)] = [
            ("unknown", .universal),
            ("rock", .rockRiff),
            ("hardrock", .rockWall),
            ("punk", .punk),
            ("metal", .metal),
            ("indie", .alternativeIndie),
            ("pop", .pop),
            ("dance", .dance),
            ("electronics", .electronic),
            ("techno", .techno),
            ("drumandbass", .breakbeat),
            ("rap", .rap),
            ("lofi", .lofi),
            ("jazz", .jazzBlues),
            ("classical", .classical),
            ("country", .folk),
            ("soundtrack", .cinematic)
        ]

        XCTAssertEqual(Set(expected.map(\.1)), Set(MediaAnimationStyle.allCases))
        for (genre, style) in expected {
            XCTAssertEqual(GenreAnimationCatalog.style(for: genre), style)
        }
    }

    func testManualModesResolveToExpectedStyles() {
        XCTAssertNil(MediaAnimationMode.off.resolvedManualStyle)
        XCTAssertEqual(MediaAnimationMode.automatic.resolvedManualStyle, .universal)
        XCTAssertEqual(MediaAnimationMode.metal.resolvedManualStyle, .metal)
    }
}
