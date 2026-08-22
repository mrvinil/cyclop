import Foundation

enum MediaAnimationStyle: String, CaseIterable, Codable {
    case universal, rockRiff, rockWall, punk, metal, alternativeIndie
    case pop, dance, electronic, techno, breakbeat, rap, lofi
    case jazzBlues, classical, folk, cinematic
}

enum GenreAnimationCatalog {
    static func style(for genre: String) -> MediaAnimationStyle {
        switch genre.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "rock", "rusrock": .rockRiff
        case "hardrock", "grunge": .rockWall
        case "punk", "hardcore": .punk
        case "metal", "alternativemetal": .metal
        case "alternative", "indie": .alternativeIndie
        case "pop", "ruspop": .pop
        case "dance", "eurodance", "hyperpopgenre": .dance
        case "electronics", "experimental": .electronic
        case "techno", "house", "trance": .techno
        case "breakbeatgenre", "drumandbass": .breakbeat
        case "rap", "rusrap": .rap
        case "lofi", "ambient", "chill", "relax": .lofi
        case "jazz", "blues": .jazzBlues
        case "classical": .classical
        case "folk", "country", "latin": .folk
        case "soundtrack", "world": .cinematic
        default: .universal
        }
    }
}
