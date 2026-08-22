import Foundation

struct GenreLookupRequest: Equatable, Hashable, Sendable {
    let title: String
    let artist: String
    let album: String
}

struct GenreLookupResult: Equatable, Sendable {
    let genreTag: String
    let style: MediaAnimationStyle
}

protocol YandexMusicGenreFetching: Sendable {
    func genre(for request: GenreLookupRequest) async -> GenreLookupResult?
}

struct GenreTrackCandidate: Equatable, Sendable {
    let title: String
    let artistNames: [String]
    let albumTitle: String
    let albumGenre: String
}

enum YandexMusicGenreMatcher {
    static func score(_ request: GenreLookupRequest, _ candidate: GenreTrackCandidate) -> Int {
        let normalizedTitle = normalize(request.title)
        let normalizedArtist = normalize(request.artist)
        let normalizedAlbum = normalize(request.album)

        var score = 0
        if !normalizedTitle.isEmpty && normalizedTitle == normalize(candidate.title) {
            score += 65
        }
        if !normalizedArtist.isEmpty && candidate.artistNames.contains(where: { normalize($0) == normalizedArtist }) {
            score += 30
        }
        if !normalizedAlbum.isEmpty && normalizedAlbum == normalize(candidate.albumTitle) {
            score += 10
        }
        return score
    }

    static func bestMatch(for request: GenreLookupRequest, candidates: [GenreTrackCandidate]) -> GenreTrackCandidate? {
        candidates
            .map { ($0, score(request, $0)) }
            .max { $0.1 < $1.1 }
            .flatMap { $0.1 >= 95 ? $0.0 : nil }
    }

    private static func normalize(_ value: String) -> String {
        value
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }
}

protocol YandexMusicGenreTransport: Sendable {
    func data(for request: URLRequest) async throws -> (Data, URLResponse)
}

struct YandexMusicGenreClient: YandexMusicGenreFetching {
    static let live = YandexMusicGenreClient()

    private let transport: any YandexMusicGenreTransport

    init(transport: any YandexMusicGenreTransport = URLSessionGenreTransport()) {
        self.transport = transport
    }

    func genre(for request: GenreLookupRequest) async -> GenreLookupResult? {
        guard let urlRequest = makeRequest(for: request) else {
            return nil
        }

        do {
            let (data, response) = try await transport.data(for: urlRequest)
            guard let httpResponse = response as? HTTPURLResponse,
                  (200...299).contains(httpResponse.statusCode) else {
                return nil
            }

            let payload = try JSONDecoder().decode(SearchResponse.self, from: data)
            let candidates = payload.result.tracks.results.compactMap(GenreTrackCandidate.init)
            guard let match = YandexMusicGenreMatcher.bestMatch(for: request, candidates: candidates) else {
                return nil
            }

            return GenreLookupResult(
                genreTag: match.albumGenre,
                style: GenreAnimationCatalog.style(for: match.albumGenre)
            )
        } catch {
            return nil
        }
    }

    private func makeRequest(for lookup: GenreLookupRequest) -> URLRequest? {
        guard var components = URLComponents(string: "https://api.music.yandex.net/search") else {
            return nil
        }
        components.queryItems = [
            URLQueryItem(name: "type", value: "track"),
            URLQueryItem(name: "page", value: "0"),
            URLQueryItem(name: "text", value: "\(lookup.artist) \(lookup.title)")
        ]
        guard let url = components.url else {
            return nil
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("CyclopGenreLookup/1.0", forHTTPHeaderField: "User-Agent")
        return request
    }
}

private struct URLSessionGenreTransport: YandexMusicGenreTransport {
    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        try await URLSession.shared.data(for: request)
    }
}

private struct SearchResponse: Decodable {
    let result: SearchResult

    struct SearchResult: Decodable {
        let tracks: Tracks
    }

    struct Tracks: Decodable {
        let results: [Track]
    }

    struct Track: Decodable {
        let title: String
        let artists: [Artist]
        let albums: [Album]
    }

    struct Artist: Decodable {
        let name: String
    }

    struct Album: Decodable {
        let title: String
        let genre: String
    }
}

private extension GenreTrackCandidate {
    init?(_ track: SearchResponse.Track) {
        guard let album = track.albums.first else {
            return nil
        }
        self.init(
            title: track.title,
            artistNames: track.artists.map(\.name),
            albumTitle: album.title,
            albumGenre: album.genre
        )
    }
}
