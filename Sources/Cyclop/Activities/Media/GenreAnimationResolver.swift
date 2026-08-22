import Combine
import Foundation

struct GenreAnimationPresentation: Equatable {
    let style: MediaAnimationStyle?
    let genreLabel: String?
    let isAutomatic: Bool

    static let off = Self(style: nil, genreLabel: nil, isAutomatic: false)
}

@MainActor
final class GenreAnimationResolver: ObservableObject {
    @Published private(set) var presentation: GenreAnimationPresentation

    private let settings: ActivitySettings
    private let client: any YandexMusicGenreFetching
    private var currentState: MediaController.MediaState?
    private var generation = 0
    private var lookupTask: Task<Void, Never>?
    private var cache: [TrackCacheKey: CacheEntry] = [:]
    private var cancellables = Set<AnyCancellable>()

    init(
        mediaStatePublisher: AnyPublisher<MediaController.MediaState, Never>,
        settings: ActivitySettings,
        client: any YandexMusicGenreFetching
    ) {
        self.settings = settings
        self.client = client
        presentation = Self.manualPresentation(for: settings.mediaAnimationMode)

        mediaStatePublisher
            .sink { [weak self] state in
                self?.receive(state)
            }
            .store(in: &cancellables)

        settings.$mediaAnimationMode
            .dropFirst()
            .sink { [weak self] mode in
                self?.receiveModeChange(mode)
            }
            .store(in: &cancellables)
    }

    deinit {
        lookupTask?.cancel()
    }

    private func receive(_ state: MediaController.MediaState) {
        currentState = state
        resolve(state)
    }

    private func receiveModeChange(_ mode: MediaAnimationMode) {
        guard let currentState else {
            cancelLookup()
            presentation = Self.manualPresentation(for: mode)
            return
        }
        resolve(currentState, mode: mode)
    }

    private func resolve(
        _ state: MediaController.MediaState,
        mode: MediaAnimationMode? = nil
    ) {
        cancelLookup()

        let resolvedMode = mode ?? settings.mediaAnimationMode
        guard resolvedMode == .automatic else {
            presentation = Self.manualPresentation(for: resolvedMode)
            return
        }

        guard let track = state.track,
              Self.isYandexMusic(state.sourceName),
              !track.title.isEmpty,
              !track.artist.isEmpty else {
            presentation = .init(style: .universal, genreLabel: nil, isAutomatic: true)
            return
        }

        let cacheKey = TrackCacheKey(track: track)
        switch cache[cacheKey] {
        case let .found(result):
            presentation = Self.automaticPresentation(for: result)
        case .notFound:
            presentation = .init(style: .universal, genreLabel: nil, isAutomatic: true)
        case nil:
            presentation = .init(style: .universal, genreLabel: nil, isAutomatic: true)
            lookup(track: track, source: state.sourceName, cacheKey: cacheKey)
        }
    }

    private func lookup(
        track: MediaController.Track,
        source: String?,
        cacheKey: TrackCacheKey
    ) {
        let lookupGeneration = generation
        let request = GenreLookupRequest(title: track.title, artist: track.artist, album: track.album)
        let client = client

        lookupTask = Task { [weak self] in
            let result = await client.genre(for: request)
            guard let self,
                  !Task.isCancelled,
                  self.generation == lookupGeneration,
                  self.currentState?.track?.key == track.key,
                  self.settings.mediaAnimationMode == .automatic,
                  Self.isYandexMusic(self.currentState?.sourceName),
                  self.currentState?.sourceName == source else {
                return
            }

            if let result {
                self.cache[cacheKey] = .found(result)
                self.presentation = Self.automaticPresentation(for: result)
            } else {
                self.cache[cacheKey] = .notFound
                self.presentation = .init(style: .universal, genreLabel: nil, isAutomatic: true)
            }
        }
    }

    private func cancelLookup() {
        generation &+= 1
        lookupTask?.cancel()
        lookupTask = nil
    }

    private static func manualPresentation(for mode: MediaAnimationMode) -> GenreAnimationPresentation {
        guard let style = mode.resolvedManualStyle else {
            return .off
        }
        return .init(style: style, genreLabel: nil, isAutomatic: false)
    }

    private static func automaticPresentation(for result: GenreLookupResult) -> GenreAnimationPresentation {
        .init(style: result.style, genreLabel: result.genreTag, isAutomatic: true)
    }

    private static func isYandexMusic(_ source: String?) -> Bool {
        source == "Yandex Music" || source == "Яндекс Музыка"
    }
}

private struct TrackCacheKey: Hashable {
    let title: String
    let artist: String
    let album: String

    init(track: MediaController.Track) {
        title = Self.normalize(track.title)
        artist = Self.normalize(track.artist)
        album = Self.normalize(track.album)
    }

    private static func normalize(_ value: String) -> String {
        let locale = Locale(identifier: "en_US_POSIX")
        return value
            .folding(options: [.diacriticInsensitive], locale: locale)
            .lowercased(with: locale)
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }
}

private enum CacheEntry {
    case found(GenreLookupResult)
    case notFound
}
