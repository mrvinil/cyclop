import Foundation
import XCTest
@testable import Cyclop

final class YandexMusicGenreClientTests: XCTestCase {
    func testExactTitleArtistAndAlbumProducesAcceptedGenre() {
        let request = GenreLookupRequest(
            title: "Born too Slow",
            artist: "The Crystal Method",
            album: "Legion of Boom"
        )
        let candidate = GenreTrackCandidate(
            title: "Born too Slow",
            artistNames: ["The Crystal Method"],
            albumTitle: "Legion of Boom",
            albumGenre: "breakbeatgenre"
        )

        XCTAssertEqual(YandexMusicGenreMatcher.score(request, candidate), 105)
        XCTAssertEqual(
            YandexMusicGenreMatcher.bestMatch(for: request, candidates: [candidate])?.albumGenre,
            "breakbeatgenre"
        )
    }

    func testTitleOnlyMatchIsRejectedBelowAcceptanceThreshold() {
        let request = GenreLookupRequest(title: "Прощай", artist: "VEIGEL", album: "Прощай")
        let candidate = GenreTrackCandidate(
            title: "Прощай",
            artistNames: ["Другой артист"],
            albumTitle: "Другой альбом",
            albumGenre: "pop"
        )

        XCTAssertEqual(YandexMusicGenreMatcher.score(request, candidate), 65)
        XCTAssertNil(YandexMusicGenreMatcher.bestMatch(for: request, candidates: [candidate]))
    }

    func testScoreAwardsArtistAndAlbumOnlyForExactNormalizedMatches() {
        let request = GenreLookupRequest(title: "Titre", artist: "Beyoncé", album: "Album  Name")
        let artistOnly = GenreTrackCandidate(
            title: "Другой трек",
            artistNames: ["BEYONCE"],
            albumTitle: "Другой альбом",
            albumGenre: "pop"
        )
        let albumOnly = GenreTrackCandidate(
            title: "Другой трек",
            artistNames: ["Другой артист"],
            albumTitle: "album name",
            albumGenre: "pop"
        )

        XCTAssertEqual(YandexMusicGenreMatcher.score(request, artistOnly), 30)
        XCTAssertEqual(YandexMusicGenreMatcher.score(request, albumOnly), 10)
    }

    func testGenreBuildsReadOnlySearchRequestAndDecodesAcceptedGenre() async throws {
        let transport = RecordingTransport(json: Self.searchResponse)
        let client = YandexMusicGenreClient(transport: transport)
        let request = GenreLookupRequest(
            title: "Born too Slow",
            artist: "The Crystal Method",
            album: "Legion of Boom"
        )

        let result = await client.genre(for: request)

        XCTAssertEqual(result?.genreTag, "breakbeatgenre")
        XCTAssertEqual(result?.style, .breakbeat)

        let urlRequest = await transport.recordedRequest
        XCTAssertEqual(urlRequest?.httpMethod, "GET")
        XCTAssertEqual(urlRequest?.url?.scheme, "https")
        XCTAssertEqual(urlRequest?.url?.host, "api.music.yandex.net")
        XCTAssertEqual(urlRequest?.url?.path, "/search")
        let queryItems = URLComponents(url: try XCTUnwrap(urlRequest?.url), resolvingAgainstBaseURL: false)?.queryItems
        XCTAssertEqual(queryItems?.first(where: { $0.name == "type" })?.value, "track")
        XCTAssertEqual(queryItems?.first(where: { $0.name == "page" })?.value, "0")
        XCTAssertEqual(queryItems?.first(where: { $0.name == "text" })?.value, "The Crystal Method Born too Slow")
        XCTAssertEqual(urlRequest?.value(forHTTPHeaderField: "User-Agent"), "CyclopGenreLookup/1.0")
        XCTAssertNil(urlRequest?.value(forHTTPHeaderField: "Authorization"))
        XCTAssertNil(urlRequest?.value(forHTTPHeaderField: "Cookie"))
    }

    private static let searchResponse = #"""
    {
      "result": {
        "tracks": {
          "results": [
            {
              "title": "Born too Slow",
              "artists": [{ "name": "The Crystal Method" }],
              "albums": [{ "title": "Legion of Boom", "genre": "breakbeatgenre" }]
            }
          ]
        }
      }
    }
    """#
}

private actor RecordingTransport: YandexMusicGenreTransport {
    private let responseData: Data
    private(set) var recordedRequest: URLRequest?

    init(json: String) {
        responseData = Data(json.utf8)
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        recordedRequest = request
        let response = HTTPURLResponse(
            url: try XCTUnwrap(request.url),
            statusCode: 200,
            httpVersion: nil,
            headerFields: nil
        )!
        return (responseData, response)
    }
}
