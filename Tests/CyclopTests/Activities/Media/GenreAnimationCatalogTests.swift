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
            ("folk", .folk),
            ("soundtrack", .cinematic),
            ("disco", .groove),
            ("reggae", .reggae),
            ("latinfolk", .latin),
            ("country", .acoustic),
            ("celtic", .ethnic),
            ("postrock", .postRock),
            ("prog", .progressive),
            ("newwave", .newWave),
            ("alternative", .alternativeDrive),
            ("house", .house),
            ("trance", .trance),
            ("dubstep", .bass),
            ("ambientgenre", .ambient)
        ]

        XCTAssertEqual(Set(expected.map(\.1)), Set(MediaAnimationStyle.allCases))
        for (genre, style) in expected {
            XCTAssertEqual(GenreAnimationCatalog.style(for: genre), style)
        }
    }

    func testGenreCatalogGroupsAdditionalYandexSubgenres() {
        let expected: [(String, MediaAnimationStyle, String)] = [
            ("newwave", .newWave, "Новая волна"),
            ("postpunk", .newWave, "Постпанк"),
            ("indierock", .alternativeIndie, "Инди-рок"),
            ("stonerrock", .rockWall, "Стоунер-рок"),
            ("deathmetal", .metal, "Дэт-метал"),
            ("poppunk", .punk, "Поп-панк"),
            ("deephouse", .house, "Deep house"),
            ("jungle", .breakbeat, "Jungle"),
            ("hiphop", .rap, "Хип-хоп"),
            ("soul", .groove, "Соул"),
            ("reggae", .reggae, "Регги")
        ]

        for (genre, style, label) in expected {
            XCTAssertEqual(GenreAnimationCatalog.style(for: genre), style)
            XCTAssertEqual(GenreAnimationCatalog.label(for: genre), label)
        }
    }

    func testYandexTaxonomySnapshotCoversEverySupportedMusicTag() {
        XCTAssertEqual(GenreAnimationCatalog.knownYandexGenreCount, 165)
        XCTAssertEqual(GenreAnimationCatalog.style(for: "newwave"), .newWave)
        XCTAssertEqual(GenreAnimationCatalog.label(for: "newwave"), "Новая волна")
        XCTAssertEqual(GenreAnimationCatalog.style(for: "dnb"), .breakbeat)
        XCTAssertEqual(GenreAnimationCatalog.label(for: "dnb"), "Драм-н-бэйс")
        XCTAssertEqual(GenreAnimationCatalog.style(for: "posthardcore"), .punk)
        XCTAssertEqual(GenreAnimationCatalog.label(for: "posthardcore"), "Постхардкор")
        XCTAssertEqual(GenreAnimationCatalog.style(for: "reggaeton"), .dance)
        XCTAssertEqual(GenreAnimationCatalog.label(for: "reggaeton"), "Реггетон")
        XCTAssertEqual(GenreAnimationCatalog.style(for: "naturesounds"), .ambient)
        XCTAssertEqual(GenreAnimationCatalog.label(for: "naturesounds"), "Звуки природы и шум города")
    }

    func testManualModesResolveToExpectedStyles() {
        XCTAssertNil(MediaAnimationMode.off.resolvedManualStyle)
        XCTAssertEqual(MediaAnimationMode.automatic.resolvedManualStyle, .universal)
        XCTAssertEqual(MediaAnimationMode.metal.resolvedManualStyle, .metal)
        XCTAssertFalse(MediaAnimationMode.allCases.map(\.rawValue).contains("house"))
        XCTAssertFalse(MediaAnimationMode.allCases.map(\.rawValue).contains("ambient"))
    }

    func testExpandedAutomaticStylesSeparateApprovedSubgenres() {
        let expected: [(String, MediaAnimationStyle)] = [
            ("funk", .groove), ("dub", .reggae), ("argentinetango", .latin),
            ("bard", .acoustic), ("georgian", .ethnic),
            ("postrock", .postRock), ("progmetal", .progressive),
            ("postpunk", .newWave), ("grunge", .alternativeDrive),
            ("house", .house), ("trance", .trance),
            ("bassgenre", .bass), ("lounge", .ambient)
        ]

        for (genre, style) in expected {
            XCTAssertEqual(GenreAnimationCatalog.style(for: genre), style)
        }
    }
}
