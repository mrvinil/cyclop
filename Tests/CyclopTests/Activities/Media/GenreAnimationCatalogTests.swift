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

    func testGenreCatalogGroupsAdditionalYandexSubgenres() {
        let expected: [(String, MediaAnimationStyle, String)] = [
            ("newwave", .alternativeIndie, "Новая волна"),
            ("postpunk", .alternativeIndie, "Постпанк"),
            ("indierock", .alternativeIndie, "Инди-рок"),
            ("stonerrock", .rockWall, "Стоунер-рок"),
            ("deathmetal", .metal, "Дэт-метал"),
            ("poppunk", .punk, "Поп-панк"),
            ("deephouse", .techno, "Deep house"),
            ("jungle", .breakbeat, "Jungle"),
            ("hiphop", .rap, "Хип-хоп"),
            ("soul", .jazzBlues, "Соул"),
            ("reggae", .folk, "Регги")
        ]

        for (genre, style, label) in expected {
            XCTAssertEqual(GenreAnimationCatalog.style(for: genre), style)
            XCTAssertEqual(GenreAnimationCatalog.label(for: genre), label)
        }
    }

    func testYandexTaxonomySnapshotCoversEverySupportedMusicTag() {
        XCTAssertEqual(GenreAnimationCatalog.knownYandexGenreCount, 165)
        XCTAssertEqual(GenreAnimationCatalog.style(for: "newwave"), .alternativeIndie)
        XCTAssertEqual(GenreAnimationCatalog.label(for: "newwave"), "Новая волна")
        XCTAssertEqual(GenreAnimationCatalog.style(for: "dnb"), .breakbeat)
        XCTAssertEqual(GenreAnimationCatalog.label(for: "dnb"), "Драм-н-бэйс")
        XCTAssertEqual(GenreAnimationCatalog.style(for: "posthardcore"), .punk)
        XCTAssertEqual(GenreAnimationCatalog.label(for: "posthardcore"), "Постхардкор")
        XCTAssertEqual(GenreAnimationCatalog.style(for: "reggaeton"), .dance)
        XCTAssertEqual(GenreAnimationCatalog.label(for: "reggaeton"), "Реггетон")
        XCTAssertEqual(GenreAnimationCatalog.style(for: "naturesounds"), .lofi)
        XCTAssertEqual(GenreAnimationCatalog.label(for: "naturesounds"), "Звуки природы и шум города")
    }

    func testManualModesResolveToExpectedStyles() {
        XCTAssertNil(MediaAnimationMode.off.resolvedManualStyle)
        XCTAssertEqual(MediaAnimationMode.automatic.resolvedManualStyle, .universal)
        XCTAssertEqual(MediaAnimationMode.metal.resolvedManualStyle, .metal)
    }
}
