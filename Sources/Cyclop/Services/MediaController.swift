import AppKit
import Combine

/// Now Playing for whatever the system is playing — browser tabs included.
///
/// Primary source is `NowPlayingFeed`, which reaches MediaRemote through a
/// helper hosted by `/usr/bin/perl`. If that route ever closes, the controller
/// falls back to scripting Apple Music and Spotify directly.
@MainActor
final class MediaController: ObservableObject {
    typealias FallbackStateFetching = (@escaping (PlayerState?) -> Void) -> Void

    struct LifecycleHooks {
        let observePlayer: (PlayerApp, @escaping () -> Void) -> Any
        let removeObserver: (Any) -> Void
        let scheduleTicker: (@escaping () -> Void) -> Any
        let cancelTicker: (Any) -> Void
        let requestArtwork: (PlayerState, @escaping (NSImage?) -> Void) -> Void

        static let live = LifecycleHooks(
            observePlayer: { app, callback in
                DistributedNotificationCenter.default().addObserver(
                    forName: app.changeNotification,
                    object: nil,
                    queue: .main
                ) { _ in callback() }
            },
            removeObserver: { observer in
                DistributedNotificationCenter.default().removeObserver(observer)
            },
            scheduleTicker: { callback in
                let timer = Timer(timeInterval: 0.25, repeats: true) { _ in callback() }
                timer.tolerance = 0.05
                RunLoop.main.add(timer, forMode: .common)
                return timer
            },
            cancelTicker: { ticker in
                (ticker as? Timer)?.invalidate()
            },
            requestArtwork: PlayerBridge.artwork
        )
    }

    struct Track: Equatable {
        var title: String
        var artist: String
        var album: String
        var key: String
    }

    struct MediaState: Equatable {
        enum Transport: Equatable {
            case systemNowPlaying
            case scriptingFallback
        }

        var track: Track?
        var isPlaying: Bool
        var duration: TimeInterval
        var position: TimeInterval
        var sourceName: String?
        var canSkip: Bool
        var transport: Transport = .systemNowPlaying
    }

    @Published private(set) var track: Track?
    @Published private(set) var artwork: NSImage?
    @Published private(set) var isPlaying = false
    @Published private(set) var duration: TimeInterval = 0
    @Published private(set) var position: TimeInterval = 0
    @Published private(set) var sourceName: String?
    /// Whether the player accepts skipping at all. A browser tab playing one
    /// video registers no handler for it — the command leaves and nothing
    /// happens — so the buttons go dim rather than dead, the way the system's
    /// own Now Playing widget dims them for the same session. True until told
    /// otherwise: the scripted fallback below drives Music and Spotify, and
    /// both skip fine.
    @Published private(set) var canSkip = true

    private let feed: NowPlayingFeed
    private let fallbackState: FallbackStateFetching
    private let now: () -> Date
    private let lifecycleHooks: LifecycleHooks
    private let mediaState: NonReentrantCurrentValueSubject<MediaState>
    private var lastAcceptedMediaState: MediaState
    private var feedAvailable = true
    private var fallbackGeneration = 0
    private var lifecycleGeneration = 0
    private var isRunning = false

    private var activeApp: PlayerApp?
    private var artworkKey: String?
    private var anchor: (position: TimeInterval, at: Date)?
    /// Where we asked the player to jump, and when — see `apply`.
    private var pendingSeek: (target: TimeInterval, at: Date)?
    private var ticker: Any?
    private var observers: [Any] = []
    /// Whether the panel is open — the ticker below runs only then.
    private var isActive = false

    var mediaStatePublisher: AnyPublisher<MediaState, Never> {
        mediaState.publisher
    }

    convenience init() {
        self.init(feed: NowPlayingFeed())
    }

    convenience init(feed: NowPlayingFeed) {
        self.init(feed: feed, fallbackState: { completion in
            PlayerBridge.currentState(completion: completion)
        }, now: { Date() })
    }

    init(
        feed: NowPlayingFeed,
        fallbackState: @escaping FallbackStateFetching,
        now: @escaping () -> Date,
        lifecycleHooks: LifecycleHooks = .live
    ) {
        self.feed = feed
        self.fallbackState = fallbackState
        self.now = now
        self.lifecycleHooks = lifecycleHooks
        let initialMediaState = MediaState(
            track: nil,
            isPlaying: false,
            duration: 0,
            position: 0,
            sourceName: nil,
            canSkip: true,
            transport: .systemNowPlaying
        )
        mediaState = NonReentrantCurrentValueSubject(initialMediaState)
        lastAcceptedMediaState = initialMediaState
    }

    // MARK: - Lifecycle

    func start() {
        guard !isRunning else { return }
        isRunning = true
        lifecycleGeneration &+= 1
        fallbackGeneration &+= 1
        feedAvailable = true
        let generation = lifecycleGeneration
        anchor = nil
        pendingSeek = nil
        clear(lifecycleGeneration: generation)
        guard isCurrentLifecycle(generation) else { return }
        feed.onUpdate = { [weak self] snapshot in
            self?.apply(snapshot, lifecycleGeneration: generation)
        }
        feed.onUnavailable = { [weak self] in
            self?.switchToScriptingFallback(lifecycleGeneration: generation)
        }
        updateTicker(lifecycleGeneration: generation)
        guard isCurrentLifecycle(generation) else { return }
        feed.start()
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        lifecycleGeneration &+= 1
        fallbackGeneration &+= 1
        feed.stop()
        observers.forEach(lifecycleHooks.removeObserver)
        observers.removeAll()
        if let ticker { lifecycleHooks.cancelTicker(ticker) }
        ticker = nil
    }

    /// Panel visibility. The position ticker hangs off this: it exists to move
    /// a bar, and a bar in a collapsed panel is painted for nobody — at four
    /// wake-ups a second for as long as anything plays. The position itself is
    /// never lost, because the anchor records where it stood and when: opening
    /// computes it from there instantly, and the feed's fresh answer corrects
    /// whatever drifted a beat later.
    func setActive(_ active: Bool) {
        isActive = active
        guard isRunning else { return }
        let generation = lifecycleGeneration
        updateTicker(lifecycleGeneration: generation)
        guard active, isCurrentLifecycle(generation) else { return }
        tick(lifecycleGeneration: generation)
        guard isCurrentLifecycle(generation) else { return }
        if feedAvailable {
            feed.refresh()
        } else {
            refreshFromPlayers()
        }
    }

    // MARK: - Transport

    func togglePlayPause() {
        guard isRunning else { return }
        let generation = lifecycleGeneration
        // Optimistic flip so the button feels instant; the feed corrects it.
        isPlaying.toggle()
        setAnchor(position)
        publishMediaState()
        guard isCurrentLifecycle(generation) else { return }
        // The per-client command set has no toggle of its own (#23) — Play
        // and Pause are sent explicitly, by the state just flipped to above.
        dispatch(
            feed: isPlaying ? .play : .pause,
            script: { PlayerBridge.playPause($0) },
            key: .playPause,
            lifecycleGeneration: generation
        )
    }

    func next() {
        dispatch(feed: .next, script: { PlayerBridge.next($0) }, key: .next, lifecycleGeneration: lifecycleGeneration)
    }

    func previous() {
        dispatch(feed: .previous, script: { PlayerBridge.previous($0) }, key: .previous, lifecycleGeneration: lifecycleGeneration)
    }

    func seek(to seconds: TimeInterval) {
        guard isRunning, duration > 0 else { return }
        let generation = lifecycleGeneration
        let clamped = min(max(0, seconds), duration)
        setAnchor(clamped)
        publishMediaState()
        guard isCurrentLifecycle(generation) else { return }
        pendingSeek = (clamped, now())
        if feedAvailable {
            feed.seek(to: clamped)
        } else if let activeApp {
            PlayerBridge.seek(activeApp, to: clamped)
        }
    }

    private func dispatch(
        feed command: NowPlayingFeed.Command,
        script: (PlayerApp) -> Void,
        key: PlayerBridge.MediaKey,
        lifecycleGeneration: Int
    ) {
        guard isCurrentLifecycle(lifecycleGeneration) else { return }
        if feedAvailable {
            feed.send(command)
        } else if let activeApp {
            script(activeApp)
        } else {
            PlayerBridge.postMediaKey(key.rawValue)
        }
    }

    // MARK: - Feed

    private func apply(_ snapshot: NowPlayingFeed.Snapshot, lifecycleGeneration: Int) {
        guard isRunning, feedAvailable, lifecycleGeneration == self.lifecycleGeneration else { return }
        guard !snapshot.isEmpty else { return clear(lifecycleGeneration: lifecycleGeneration) }

        let key = "\(snapshot.title)|\(snapshot.artist)|\(snapshot.album)"
        track = Track(title: snapshot.title, artist: snapshot.artist, album: snapshot.album, key: key)
        isPlaying = snapshot.isPlaying || snapshot.rate > 0
        duration = snapshot.duration
        sourceName = snapshot.source
        // Both directions travel together: no player has ever offered one
        // without the other, and two separately dimmed arrows would read as
        // a glitch rather than a limit.
        canSkip = snapshot.offers(.next) && snapshot.offers(.previous)

        let reported = reportedPosition(from: snapshot)

        // A player needs a moment to act on a seek, and until it does it keeps
        // reporting the old position. Accepting that would yank the bar back.
        if let pending = pendingSeek {
            let settled = abs(reported - pending.target) < 2.5
            let expired = now().timeIntervalSince(pending.at) > 1.5
            if settled || expired {
                pendingSeek = nil
                adopt(reported)
            }
        } else {
            adopt(reported)
        }
        publishMediaState()
        guard isCurrentLifecycle(lifecycleGeneration) else { return }
        updateTicker(lifecycleGeneration: lifecycleGeneration)
        guard isCurrentLifecycle(lifecycleGeneration) else { return }

        if let data = snapshot.artwork {
            artworkKey = key
            decodeArtwork(data, for: key, lifecycleGeneration: lifecycleGeneration)
        } else if artworkKey != key {
            // Track changed and the payload carried no artwork; the skeleton
            // covers the gap until the system publishes the new cover.
            artworkKey = key
            artwork = nil
        }
    }

    /// JPEG decoding on the main thread is what makes a track change stutter,
    /// so it happens off it and the finished image is handed back.
    private func decodeArtwork(_ data: Data, for key: String, lifecycleGeneration: Int) {
        DispatchQueue.global(qos: .userInitiated).async {
            guard let rep = NSBitmapImageRep(data: data), let cgImage = rep.cgImage else { return }
            let image = NSImage(
                cgImage: cgImage,
                size: NSSize(width: rep.pixelsWide, height: rep.pixelsHigh)
            )
            DispatchQueue.main.async { [weak self] in
                guard let self,
                      self.isCurrentLifecycle(lifecycleGeneration),
                      self.artworkKey == key else { return }
                self.artwork = image
            }
        }
    }

    private func clear(lifecycleGeneration: Int) {
        activeApp = nil
        track = nil
        artwork = nil
        artworkKey = nil
        isPlaying = false
        duration = 0
        position = 0
        sourceName = nil
        canSkip = true
        publishMediaState()
        guard isCurrentLifecycle(lifecycleGeneration) else { return }
        updateTicker(lifecycleGeneration: lifecycleGeneration)
    }

    // MARK: - Fallback: scriptable players only

    private func switchToScriptingFallback(lifecycleGeneration: Int) {
        guard isRunning, feedAvailable, lifecycleGeneration == self.lifecycleGeneration else { return }
        feedAvailable = false
        // The helper's system track is no longer controllable by the direct
        // Apple Music/Spotify route. Remove it before the asynchronous query,
        // then publish only a fully collected fallback result.
        clear(lifecycleGeneration: lifecycleGeneration)
        guard isCurrentLifecycle(lifecycleGeneration), !feedAvailable else { return }
        NSLog("Cyclop: Now Playing helper unavailable, falling back to Music/Spotify scripting")

        var newObservers: [Any] = []
        for app in PlayerApp.allCases {
            newObservers.append(lifecycleHooks.observePlayer(app) { [weak self] in
                MainActor.assumeIsolated {
                    guard self?.isCurrentLifecycle(lifecycleGeneration) == true,
                          self?.feedAvailable == false else { return }
                    self?.activeApp = app
                    self?.refreshFromPlayers()
                }
            })
        }
        guard isCurrentLifecycle(lifecycleGeneration), !feedAvailable else {
            newObservers.forEach(lifecycleHooks.removeObserver)
            return
        }
        observers.append(contentsOf: newObservers)
        refreshFromPlayers(lifecycleGeneration: lifecycleGeneration)
    }

    private func refreshFromPlayers(lifecycleGeneration: Int? = nil) {
        let lifecycleGeneration = lifecycleGeneration ?? self.lifecycleGeneration
        guard isCurrentLifecycle(lifecycleGeneration), !feedAvailable else { return }
        fallbackGeneration &+= 1
        let generation = fallbackGeneration
        fallbackState { [weak self] state in
            guard let self else { return }
            guard self.isCurrentLifecycle(lifecycleGeneration), !self.feedAvailable else { return }
            guard generation == self.fallbackGeneration else { return }
            guard let state else { return self.clear(lifecycleGeneration: lifecycleGeneration) }

            self.activeApp = state.app
            self.sourceName = state.app.displayName
            self.track = Track(title: state.title, artist: state.artist, album: state.album, key: state.key)
            self.isPlaying = state.isPlaying
            self.duration = state.duration
            self.adopt(state.position)
            self.publishMediaState()
            guard self.isCurrentLifecycle(lifecycleGeneration) else { return }
            self.updateTicker(lifecycleGeneration: lifecycleGeneration)
            guard self.isCurrentLifecycle(lifecycleGeneration) else { return }

            guard self.artworkKey != state.key else { return }
            self.artworkKey = state.key
            self.artwork = nil
            self.lifecycleHooks.requestArtwork(state) { [weak self] image in
                guard let self,
                      self.isCurrentLifecycle(lifecycleGeneration),
                      self.artworkKey == state.key else { return }
                self.artwork = image
            }
        }
    }

    // MARK: - Position

    /// What a report actually says by the time it is read.
    ///
    /// MediaRemote does not keep the elapsed time running. The field is a
    /// reading taken when the session last changed state, and the timestamp
    /// beside it says when — a tab playing for three minutes keeps reporting
    /// the second it started at, and many browsers report a plain zero. Taken
    /// literally, every refresh describes the beginning of the track, and
    /// `adopt` reads the gap as a seek made in the player and obeys it. Which
    /// is exactly what hovering did: open the panel, refresh, bar to zero.
    ///
    /// So the reading is aged by the clock that came with it. A paused session
    /// is left alone — its reading is not moving and there is nothing to add.
    private func reportedPosition(from snapshot: NowPlayingFeed.Snapshot) -> TimeInterval {
        guard snapshot.isPlaying || snapshot.rate > 0, let takenAt = snapshot.takenAt else {
            return snapshot.elapsed
        }
        let since = now().timeIntervalSince(takenAt)
        // A stamp from the future is not a clock to add to. Trust the reading.
        guard since >= 0 else { return snapshot.elapsed }
        let rate = snapshot.rate > 0 ? snapshot.rate : 1
        let aged = snapshot.elapsed + since * rate
        return snapshot.duration > 0 ? min(aged, snapshot.duration) : aged
    }

    private func setAnchor(_ value: TimeInterval) {
        position = value
        anchor = (value, now())
    }

    /// Below this a forward correction is pipeline jitter, not movement.
    private let forwardTolerance: TimeInterval = 0.75
    /// A disagreement this large is an event — a seek made in the player
    /// itself, or a track change — not a discrepancy to be smoothed over.
    private let seekThreshold: TimeInterval = 2

    /// Takes a position reported by the player, without letting the report undo
    /// what has already been shown.
    ///
    /// Every reading arrives late: the helper, the pipe and the parse sit
    /// between the player's clock and ours, so a report is normally a little
    /// *behind* the bar. Accepting it moves the bar backwards — and backwards
    /// is the one direction anybody notices, because time does not do it. So
    /// the two directions get different rules rather than one shared tolerance:
    /// backwards only for something big enough to be a real event, forwards for
    /// anything past the jitter. Left alone, the bar keeps its own count, which
    /// runs at exactly the speed the music does.
    private func adopt(_ reported: TimeInterval) {
        var value = max(0, reported)
        if duration > 0 { value = min(value, duration) }
        let delta = value - position

        if delta >= forwardTolerance || delta <= -seekThreshold {
            position = value
            anchor = (value, now())
        } else {
            // Keep what is on screen and re-base the clock under it, so the
            // ignored difference cannot accumulate into the next comparison.
            anchor = (position, now())
        }
    }

    private func updateTicker(lifecycleGeneration: Int) {
        if let ticker { lifecycleHooks.cancelTicker(ticker) }
        ticker = nil
        guard isCurrentLifecycle(lifecycleGeneration), isPlaying, isActive else { return }
        // Four times a second: the bar advances in sub-pixel steps, so it reads
        // as smooth without any animation smoothing the seek away with it.
        ticker = lifecycleHooks.scheduleTicker { [weak self] in
            MainActor.assumeIsolated { self?.tick(lifecycleGeneration: lifecycleGeneration) }
        }
    }

    private func tick(lifecycleGeneration: Int) {
        guard isCurrentLifecycle(lifecycleGeneration), let anchor, isPlaying else { return }
        let value = anchor.position + now().timeIntervalSince(anchor.at)
        position = duration > 0 ? min(value, duration) : value
        publishMediaState()
    }

    private func isCurrentLifecycle(_ generation: Int) -> Bool {
        isRunning && generation == lifecycleGeneration
    }

    private func publishMediaState() {
        let updated = MediaState(
            track: track,
            isPlaying: isPlaying,
            duration: duration,
            position: position,
            sourceName: sourceName,
            canSkip: canSkip,
            transport: feedAvailable ? .systemNowPlaying : .scriptingFallback
        )
        guard lastAcceptedMediaState != updated else { return }
        lastAcceptedMediaState = updated
        mediaState.send(updated)
    }
}
