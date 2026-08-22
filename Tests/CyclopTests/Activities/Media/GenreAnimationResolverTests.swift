import Combine
import Foundation
import XCTest
@testable import Cyclop

@MainActor
final class GenreAnimationResolverTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "GenreAnimationResolverTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    func testYandexTrackUsesResolvedStyleAndMemoryCache() async {
        let states = CurrentValueSubject<MediaController.MediaState, Never>(emptyState())
        let settings = makeSettings()
        let client = GenreClientFake(result: .init(genreTag: "punk", style: .punk))
        let resolver = GenreAnimationResolver(
            mediaStatePublisher: states.eraseToAnyPublisher(),
            settings: settings,
            client: client
        )
        settings.mediaAnimationMode = .automatic

        let state = mediaState(source: "Yandex Music")
        states.send(state)
        await waitForTasks()

        XCTAssertEqual(resolver.presentation, .init(style: .punk, genreLabel: "Панк", isAutomatic: true))
        let initialRequestCount = await client.requestsCount()
        XCTAssertEqual(initialRequestCount, 1)

        states.send(state)
        await waitForTasks()

        XCTAssertEqual(resolver.presentation, .init(style: .punk, genreLabel: "Панк", isAutomatic: true))
        let cachedRequestCount = await client.requestsCount()
        XCTAssertEqual(cachedRequestCount, 1)
    }

    func testNonYandexSourceDoesNotCallClient() async {
        let states = CurrentValueSubject<MediaController.MediaState, Never>(emptyState())
        let settings = makeSettings()
        let client = GenreClientFake(result: .init(genreTag: "punk", style: .punk))
        let resolver = GenreAnimationResolver(
            mediaStatePublisher: states.eraseToAnyPublisher(),
            settings: settings,
            client: client
        )
        settings.mediaAnimationMode = .automatic

        states.send(mediaState(source: "Spotify"))
        await waitForTasks()

        let requestCount = await client.requestsCount()
        XCTAssertEqual(requestCount, 0)
        XCTAssertEqual(resolver.presentation, .init(style: .universal, genreLabel: nil, isAutomatic: true))
    }

    func testRussianYandexSourceUsesLookup() async {
        let states = CurrentValueSubject<MediaController.MediaState, Never>(emptyState())
        let settings = makeSettings()
        let client = GenreClientFake(result: .init(genreTag: "rap", style: .rap))
        let resolver = GenreAnimationResolver(
            mediaStatePublisher: states.eraseToAnyPublisher(),
            settings: settings,
            client: client
        )
        settings.mediaAnimationMode = .automatic

        states.send(mediaState(source: "Яндекс Музыка"))
        await waitForTasks()

        XCTAssertEqual(resolver.presentation, .init(style: .rap, genreLabel: "Рэп", isAutomatic: true))
        let requestCount = await client.requestsCount()
        XCTAssertEqual(requestCount, 1)
    }

    func testMissingSourceDoesNotCallClient() async {
        let states = CurrentValueSubject<MediaController.MediaState, Never>(emptyState())
        let settings = makeSettings()
        let client = GenreClientFake(result: .init(genreTag: "punk", style: .punk))
        let resolver = GenreAnimationResolver(
            mediaStatePublisher: states.eraseToAnyPublisher(),
            settings: settings,
            client: client
        )
        settings.mediaAnimationMode = .automatic

        states.send(mediaState(source: nil))
        await waitForTasks()

        let requestCount = await client.requestsCount()
        XCTAssertEqual(requestCount, 0)
        XCTAssertEqual(resolver.presentation, .init(style: .universal, genreLabel: nil, isAutomatic: true))
    }

    func testMissingGenreIsNegativeCached() async {
        let states = CurrentValueSubject<MediaController.MediaState, Never>(emptyState())
        let settings = makeSettings()
        let client = GenreClientFake(result: nil)
        let resolver = GenreAnimationResolver(
            mediaStatePublisher: states.eraseToAnyPublisher(),
            settings: settings,
            client: client
        )
        settings.mediaAnimationMode = .automatic

        let state = mediaState(source: "Yandex Music")
        states.send(state)
        await waitForTasks()
        states.send(emptyState())
        states.send(state)
        await waitForTasks()

        XCTAssertEqual(resolver.presentation, .init(style: .universal, genreLabel: nil, isAutomatic: true))
        let requestCount = await client.requestsCount()
        XCTAssertEqual(requestCount, 1)
    }

    func testOutdatedLookupCannotOverwriteNewTrack() async {
        let states = CurrentValueSubject<MediaController.MediaState, Never>(emptyState())
        let settings = makeSettings()
        let client = GenreClientDeferredFake()
        let resolver = GenreAnimationResolver(
            mediaStatePublisher: states.eraseToAnyPublisher(),
            settings: settings,
            client: client
        )
        settings.mediaAnimationMode = .automatic

        states.send(mediaState(title: "Трек A", source: "Yandex Music"))
        await waitForRequests(client, expectedCount: 1)
        states.send(mediaState(title: "Трек B", source: "Yandex Music"))
        await waitForRequests(client, expectedCount: 2)

        await client.resolve(
            title: "Трек A",
            result: .init(genreTag: "punk", style: .punk)
        )
        await waitForTasks()

        XCTAssertEqual(resolver.presentation, .init(style: .universal, genreLabel: nil, isAutomatic: true))

        await client.resolve(
            title: "Трек B",
            result: .init(genreTag: "rap", style: .rap)
        )
        await waitForTasks()

        XCTAssertEqual(resolver.presentation, .init(style: .rap, genreLabel: "Рэп", isAutomatic: true))
    }

    func testPositionUpdateKeepsCurrentLookupAndAppliesItsResult() async {
        let states = CurrentValueSubject<MediaController.MediaState, Never>(emptyState())
        let settings = makeSettings()
        let client = GenreClientDeferredFake()
        let resolver = GenreAnimationResolver(
            mediaStatePublisher: states.eraseToAnyPublisher(),
            settings: settings,
            client: client
        )
        settings.mediaAnimationMode = .automatic

        states.send(mediaState(source: "Yandex Music", position: 30))
        await waitForRequests(client, expectedCount: 1)
        states.send(mediaState(source: "Yandex Music", position: 31))
        await waitForTasks()

        let requestCount = await client.requestsCount()
        XCTAssertEqual(requestCount, 1)

        await client.resolve(title: "Песня", result: .init(genreTag: "punk", style: .punk))
        await waitForTasks()

        XCTAssertEqual(resolver.presentation, .init(style: .punk, genreLabel: "Панк", isAutomatic: true))
    }

    func testUnknownGenreKeepsUniversalStyleWithoutTechnicalLabel() async {
        let states = CurrentValueSubject<MediaController.MediaState, Never>(emptyState())
        let settings = makeSettings()
        let client = GenreClientFake(result: .init(genreTag: "undocumented-tag", style: .universal))
        let resolver = GenreAnimationResolver(
            mediaStatePublisher: states.eraseToAnyPublisher(),
            settings: settings,
            client: client
        )
        settings.mediaAnimationMode = .automatic

        states.send(mediaState(source: "Yandex Music"))
        await waitForTasks()

        XCTAssertEqual(resolver.presentation, .init(style: .universal, genreLabel: nil, isAutomatic: true))
    }

    func testBreakbeatGenreUsesHumanReadableLabel() async {
        let states = CurrentValueSubject<MediaController.MediaState, Never>(emptyState())
        let settings = makeSettings()
        let client = GenreClientFake(result: .init(genreTag: "breakbeatgenre", style: .breakbeat))
        let resolver = GenreAnimationResolver(
            mediaStatePublisher: states.eraseToAnyPublisher(),
            settings: settings,
            client: client
        )
        settings.mediaAnimationMode = .automatic

        states.send(mediaState(source: "Yandex Music"))
        await waitForTasks()

        XCTAssertEqual(
            resolver.presentation,
            .init(style: .breakbeat, genreLabel: "Breakbeat / DnB", isAutomatic: true)
        )
    }

    func testManualAndOffModesCancelAutomaticPresentation() async {
        let states = CurrentValueSubject<MediaController.MediaState, Never>(emptyState())
        let settings = makeSettings()
        let client = GenreClientDeferredFake()
        let resolver = GenreAnimationResolver(
            mediaStatePublisher: states.eraseToAnyPublisher(),
            settings: settings,
            client: client
        )
        settings.mediaAnimationMode = .automatic
        states.send(mediaState(source: "Yandex Music"))
        await waitForRequests(client, expectedCount: 1)

        settings.mediaAnimationMode = .metal
        await waitForTasks()
        XCTAssertEqual(resolver.presentation, .init(style: .metal, genreLabel: nil, isAutomatic: false))

        await client.resolve(
            title: "Песня",
            result: .init(genreTag: "punk", style: .punk)
        )
        await waitForTasks()
        XCTAssertEqual(resolver.presentation, .init(style: .metal, genreLabel: nil, isAutomatic: false))

        settings.mediaAnimationMode = .off
        await waitForTasks()
        XCTAssertEqual(resolver.presentation, .off)
    }

    func testLookupCannotOverwriteWhenSourceChangesToSpotify() async {
        let states = CurrentValueSubject<MediaController.MediaState, Never>(emptyState())
        let settings = makeSettings()
        let client = GenreClientDeferredFake()
        let resolver = GenreAnimationResolver(
            mediaStatePublisher: states.eraseToAnyPublisher(),
            settings: settings,
            client: client
        )
        settings.mediaAnimationMode = .automatic

        states.send(mediaState(source: "Yandex Music"))
        await waitForRequests(client, expectedCount: 1)
        states.send(mediaState(source: "Spotify"))

        await client.resolve(title: "Песня", result: .init(genreTag: "punk", style: .punk))
        await waitForTasks()

        XCTAssertEqual(resolver.presentation, .init(style: .universal, genreLabel: nil, isAutomatic: true))
    }

    func testLookupCannotOverwriteWhenAutomaticModeTurnsOff() async {
        let states = CurrentValueSubject<MediaController.MediaState, Never>(emptyState())
        let settings = makeSettings()
        let client = GenreClientDeferredFake()
        let resolver = GenreAnimationResolver(
            mediaStatePublisher: states.eraseToAnyPublisher(),
            settings: settings,
            client: client
        )
        settings.mediaAnimationMode = .automatic

        states.send(mediaState(source: "Yandex Music"))
        await waitForRequests(client, expectedCount: 1)
        settings.mediaAnimationMode = .off
        await waitForTasks()

        await client.resolve(title: "Песня", result: .init(genreTag: "punk", style: .punk))
        await waitForTasks()

        XCTAssertEqual(resolver.presentation, .off)
    }

    private func makeSettings() -> ActivitySettings {
        ActivitySettings(defaults: defaults)
    }

    private func emptyState() -> MediaController.MediaState {
        .init(track: nil, isPlaying: false, duration: 0, position: 0, sourceName: nil, canSkip: true)
    }

    private func mediaState(
        title: String = "Песня",
        artist: String = "Артист",
        album: String = "Альбом",
        source: String?,
        position: TimeInterval = 30
    ) -> MediaController.MediaState {
        .init(
            track: .init(title: title, artist: artist, album: album, key: "\(title)|\(artist)|\(album)"),
            isPlaying: true,
            duration: 180,
            position: position,
            sourceName: source,
            canSkip: true
        )
    }

    private func waitForTasks() async {
        for _ in 0 ..< 50 {
            await Task.yield()
        }
    }

    private func waitForRequests(_ client: GenreClientDeferredFake, expectedCount: Int) async {
        for _ in 0 ..< 20 {
            if await client.requestsCount() >= expectedCount {
                break
            }
            await Task.yield()
        }
        let requestCount = await client.requestsCount()
        XCTAssertEqual(requestCount, expectedCount)
    }
}

private actor GenreClientFake: YandexMusicGenreFetching {
    private let result: GenreLookupResult?
    private(set) var requestCount = 0

    init(result: GenreLookupResult?) {
        self.result = result
    }

    func genre(for request: GenreLookupRequest) async -> GenreLookupResult? {
        requestCount += 1
        return result
    }

    func requestsCount() -> Int {
        requestCount
    }
}

private actor GenreClientDeferredFake: YandexMusicGenreFetching {
    private var continuations: [String: CheckedContinuation<GenreLookupResult?, Never>] = [:]
    private(set) var requestCount = 0

    func genre(for request: GenreLookupRequest) async -> GenreLookupResult? {
        requestCount += 1
        return await withCheckedContinuation { continuation in
            continuations[request.title] = continuation
        }
    }

    func resolve(title: String, result: GenreLookupResult?) {
        continuations.removeValue(forKey: title)?.resume(returning: result)
    }

    func requestsCount() -> Int {
        requestCount
    }
}
