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
    private var ticker: Timer?
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
        now: @escaping () -> Date
    ) {
        self.feed = feed
        self.fallbackState = fallbackState
        self.now = now
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
        clear()
        let generation = lifecycleGeneration
        feed.onUpdate = { [weak self] snapshot in
            self?.apply(snapshot, lifecycleGeneration: generation)
        }
        feed.onUnavailable = { [weak self] in
            self?.switchToScriptingFallback(lifecycleGeneration: generation)
        }
        updateTicker()
        feed.start()
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        lifecycleGeneration &+= 1
        fallbackGeneration &+= 1
        feed.stop()
        observers.forEach { DistributedNotificationCenter.default().removeObserver($0) }
        observers.removeAll()
        ticker?.invalidate()
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
        updateTicker()
        guard active, isRunning else { return }
        tick()
        if feedAvailable {
            feed.refresh()
        } else {
            refreshFromPlayers()
        }
    }

    // MARK: - Transport

    func togglePlayPause() {
        // Optimistic flip so the button feels instant; the feed corrects it.
        isPlaying.toggle()
        setAnchor(position)
        publishMediaState()
        // The per-client command set has no toggle of its own (#23) — Play
        // and Pause are sent explicitly, by the state just flipped to above.
        dispatch(feed: isPlaying ? .play : .pause, script: { PlayerBridge.playPause($0) }, key: .playPause)
    }

    func next() {
        dispatch(feed: .next, script: { PlayerBridge.next($0) }, key: .next)
    }

    func previous() {
        dispatch(feed: .previous, script: { PlayerBridge.previous($0) }, key: .previous)
    }

    func seek(to seconds: TimeInterval) {
        guard duration > 0 else { return }
        let clamped = min(max(0, seconds), duration)
        setAnchor(clamped)
        publishMediaState()
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
        key: PlayerBridge.MediaKey
    ) {
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
        guard !snapshot.isEmpty else { return clear() }

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
        updateTicker()

        if let data = snapshot.artwork {
            artworkKey = key
            decodeArtwork(data, for: key)
        } else if artworkKey != key {
            // Track changed and the payload carried no artwork; the skeleton
            // covers the gap until the system publishes the new cover.
            artworkKey = key
            artwork = nil
        }
    }

    /// JPEG decoding on the main thread is what makes a track change stutter,
    /// so it happens off it and the finished image is handed back.
    private func decodeArtwork(_ data: Data, for key: String) {
        DispatchQueue.global(qos: .userInitiated).async {
            guard let rep = NSBitmapImageRep(data: data), let cgImage = rep.cgImage else { return }
            let image = NSImage(
                cgImage: cgImage,
                size: NSSize(width: rep.pixelsWide, height: rep.pixelsHigh)
            )
            DispatchQueue.main.async { [weak self] in
                guard let self, self.artworkKey == key else { return }
                self.artwork = image
            }
        }
    }

    private func clear() {
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
        updateTicker()
    }

    // MARK: - Fallback: scriptable players only

    private func switchToScriptingFallback(lifecycleGeneration: Int) {
        guard isRunning, feedAvailable, lifecycleGeneration == self.lifecycleGeneration else { return }
        feedAvailable = false
        // The helper's system track is no longer controllable by the direct
        // Apple Music/Spotify route. Remove it before the asynchronous query,
        // then publish only a fully collected fallback result.
        clear()
        NSLog("Cyclop: Now Playing helper unavailable, falling back to Music/Spotify scripting")

        let center = DistributedNotificationCenter.default()
        for app in PlayerApp.allCases {
            observers.append(center.addObserver(
                forName: app.changeNotification, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard self?.isRunning == true, self?.feedAvailable == false else { return }
                    self?.activeApp = app
                    self?.refreshFromPlayers()
                }
            })
        }
        refreshFromPlayers()
    }

    private func refreshFromPlayers() {
        guard isRunning, !feedAvailable else { return }
        fallbackGeneration &+= 1
        let generation = fallbackGeneration
        let lifecycleGeneration = lifecycleGeneration
        fallbackState { [weak self] state in
            guard let self else { return }
            guard self.isRunning, !self.feedAvailable else { return }
            guard lifecycleGeneration == self.lifecycleGeneration else { return }
            guard generation == self.fallbackGeneration else { return }
            guard let state else { return self.clear() }

            self.activeApp = state.app
            self.sourceName = state.app.displayName
            self.track = Track(title: state.title, artist: state.artist, album: state.album, key: state.key)
            self.isPlaying = state.isPlaying
            self.duration = state.duration
            self.adopt(state.position)
            self.publishMediaState()
            self.updateTicker()

            guard self.artworkKey != state.key else { return }
            self.artworkKey = state.key
            self.artwork = nil
            PlayerBridge.artwork(for: state) { [weak self] image in
                guard let self, self.artworkKey == state.key else { return }
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

    private func updateTicker() {
        ticker?.invalidate()
        ticker = nil
        guard isPlaying, isActive else { return }
        // Four times a second: the bar advances in sub-pixel steps, so it reads
        // as smooth without any animation smoothing the seek away with it.
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        timer.tolerance = 0.05
        RunLoop.main.add(timer, forMode: .common)
        ticker = timer
    }

    private func tick() {
        guard let anchor, isPlaying else { return }
        let value = anchor.position + now().timeIntervalSince(anchor.at)
        position = duration > 0 ? min(value, duration) : value
        publishMediaState()
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
