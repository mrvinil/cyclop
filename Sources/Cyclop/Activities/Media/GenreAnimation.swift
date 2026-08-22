import Foundation

enum MediaAnimationStyle: String, CaseIterable, Codable {
    case universal, rockRiff, rockWall, punk, metal, alternativeIndie
    case pop, dance, electronic, techno, breakbeat, rap, lofi
    case jazzBlues, classical, folk, cinematic
}

enum GenreAnimationCatalog {
    static func style(for genre: String) -> MediaAnimationStyle {
        entry(for: genre)?.style ?? .universal
    }

    static func label(for genre: String) -> String? {
        entry(for: genre)?.label
    }

    private static func entry(for genre: String) -> Entry? {
        switch genre.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "rock", "rusrock": .init(style: .rockRiff, label: "Рок: Рифф")
        case "hardrock", "grunge", "stonerrock": .init(style: .rockWall, label: "Рок: Стена")
        case "punk", "hardcore", "poppunk": .init(style: .punk, label: "Панк")
        case "metal", "alternativemetal", "deathmetal": .init(style: .metal, label: "Металл")
        case "alternative", "indie", "newwave", "postpunk", "indierock":
            .init(style: .alternativeIndie, label: "Альтернатива / инди")
        case "pop", "ruspop": .init(style: .pop, label: "Поп")
        case "dance", "eurodance", "hyperpopgenre": .init(style: .dance, label: "Танцевальная")
        case "electronics", "experimental": .init(style: .electronic, label: "Электроника")
        case "techno", "house", "trance", "deephouse": .init(style: .techno, label: "Техно / house / trance")
        case "breakbeatgenre", "drumandbass", "jungle": .init(style: .breakbeat, label: "Breakbeat / DnB")
        case "rap", "rusrap", "hiphop": .init(style: .rap, label: "Рэп")
        case "lofi", "ambient", "chill", "relax": .init(style: .lofi, label: "Лоу-фай / ambient")
        case "jazz", "blues", "soul": .init(style: .jazzBlues, label: "Джаз / блюз")
        case "classical": .init(style: .classical, label: "Классика")
        case "folk", "country", "latin", "reggae": .init(style: .folk, label: "Фолк / country / Latin")
        case "soundtrack", "world": .init(style: .cinematic, label: "Саундтрек / world")
        default: nil
        }
    }

    private struct Entry {
        let style: MediaAnimationStyle
        let label: String
    }
}
