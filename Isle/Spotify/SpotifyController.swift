import AppKit
import Combine

struct SpotifyTrack: Equatable {
    var id: String
    var name: String
    var artist: String
    var album: String
    var duration: TimeInterval
    var artworkURL: URL?
}

enum LyricsState: Equatable {
    case idle, loading, found, missing
}

/// Single source of truth for what Spotify is playing.
/// Track/state changes come from Spotify's distributed notification; a light poll
/// keeps shuffle/repeat/volume in sync. Position is interpolated locally.
@MainActor
final class SpotifyController: ObservableObject {
    static let shared = SpotifyController()
    static let bundleID = "com.spotify.client"

    @Published private(set) var isRunning = false
    @Published private(set) var track: SpotifyTrack?
    @Published private(set) var isPlaying = false
    @Published private(set) var shuffling = false
    @Published private(set) var repeating = false
    @Published private(set) var volume: Double = 0.5
    @Published private(set) var artwork: ProcessedArtwork?
    @Published private(set) var lyrics: Lyrics?
    @Published private(set) var lyricsState: LyricsState = .idle
    @Published private(set) var output = AudioOutput.current()
    @Published private(set) var permissionDenied = false

    private var basePosition: TimeInterval = 0
    private var baseDate = Date()
    private let runner = AppleScriptRunner()
    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []
    private var artworkTask: Task<Void, Never>?
    private var lyricsTask: Task<Void, Never>?
    private var volumeTask: Task<Void, Never>?
    private var refreshInFlight = false
    private var refreshQueued = false
    private var suppressPollUntil = Date.distantPast
    private var started = false

    // MARK: - Lifecycle

    func start() {
        guard !started else { return }
        started = true

        let dnc = DistributedNotificationCenter.default()
        observers.append(dnc.addObserver(
            forName: .init("com.spotify.client.PlaybackStateChanged"), object: nil, queue: .main
        ) { [weak self] note in
            let info = note.userInfo
            MainActor.assumeIsolated { self?.handlePlaybackNotification(info) }
        })

        let wnc = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            observers.append(wnc.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                guard app?.bundleIdentifier == SpotifyController.bundleID else { return }
                MainActor.assumeIsolated { self?.refresh() }
            })
        }

        timer = Timer.scheduledTimer(withTimeInterval: 2.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        refresh()
    }

    // MARK: - Position

    func position(at date: Date = Date()) -> TimeInterval {
        guard let track else { return 0 }
        var p = basePosition
        if isPlaying { p += date.timeIntervalSince(baseDate) }
        return min(max(0, p), max(0, track.duration))
    }

    // MARK: - Refresh

    func refresh() {
        if refreshInFlight {
            refreshQueued = true
            return
        }
        refreshInFlight = true
        Task {
            await performRefresh()
            refreshInFlight = false
            if refreshQueued {
                refreshQueued = false
                refresh()
            }
        }
    }

    private func performRefresh() async {
        let out = AudioOutput.current()
        if out != output { output = out }

        let running = !NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleID).isEmpty
        if isRunning != running { isRunning = running }
        guard running else {
            clear()
            return
        }

        let result = await runner.run(SpotifyScripts.state, cache: true)
        if let code = result.errorCode {
            // -1743: user has not allowed Automation for Spotify
            if code == -1743, !permissionDenied { permissionDenied = true }
            return
        }
        if permissionDenied { permissionDenied = false }
        apply(result.output ?? "")
    }

    private func apply(_ raw: String) {
        let f = raw.components(separatedBy: "\u{1E}")
        guard f.count >= 11 else {
            if raw == "notrunning" || raw == "stopped" { clear() }
            return
        }
        let playing = f[0] == "playing"
        let newTrack = SpotifyTrack(
            id: f[1],
            name: f[2],
            artist: f[3],
            album: f[4],
            duration: (Self.number(f[5]) ?? 0) / 1000,
            artworkURL: URL(string: f[7])
        )
        if isPlaying != playing { isPlaying = playing }
        basePosition = Self.number(f[6]) ?? 0
        baseDate = Date()

        if Date() > suppressPollUntil {
            let sh = f[8] == "true"
            let rp = f[9] == "true"
            let vol = (Self.number(f[10]) ?? 50) / 100
            if shuffling != sh { shuffling = sh }
            if repeating != rp { repeating = rp }
            if abs(volume - vol) > 0.005 { volume = vol }
        }

        if track != newTrack {
            let old = track
            track = newTrack
            if old?.artworkURL != newTrack.artworkURL { loadArtwork(newTrack) }
            if old?.id != newTrack.id { loadLyrics(newTrack) }
        }
    }

    private func handlePlaybackNotification(_ info: [AnyHashable: Any]?) {
        let state = info?["Player State"] as? String
        if state == "Stopped" {
            clear()
            return
        }
        if let state {
            let p = state == "Playing"
            if isPlaying != p { isPlaying = p }
        }
        if let pos = info?["Playback Position"] as? Double {
            basePosition = pos
            baseDate = Date()
        }
        refresh()
    }

    private func clear() {
        if isPlaying { isPlaying = false }
        guard track != nil else { return }
        artworkTask?.cancel()
        lyricsTask?.cancel()
        track = nil
        artwork = nil
        lyrics = nil
        lyricsState = .idle
    }

    private static func number(_ s: String) -> Double? {
        Double(s.replacingOccurrences(of: ",", with: ".").trimmingCharacters(in: .whitespacesAndNewlines))
    }

    // MARK: - Artwork & lyrics

    private func loadArtwork(_ t: SpotifyTrack) {
        artworkTask?.cancel()
        guard let url = t.artworkURL else {
            artwork = nil
            return
        }
        let frame = NSScreen.screens.first?.frame.size ?? CGSize(width: 16, height: 10)
        let aspect = frame.width / max(frame.height, 1)
        artworkTask = Task {
            let art = await ArtworkProcessor.process(url: url, screenAspect: aspect)
            guard !Task.isCancelled, track?.artworkURL == url, let art else { return }
            artwork = art
        }
    }

    private func loadLyrics(_ t: SpotifyTrack) {
        lyricsTask?.cancel()
        lyrics = nil
        lyricsState = .loading
        lyricsTask = Task {
            let found = await LyricsService.shared.lyrics(for: t)
            guard !Task.isCancelled, track?.id == t.id else { return }
            lyrics = found
            lyricsState = found == nil ? .missing : .found
        }
    }

    // MARK: - Commands

    func togglePlayPause() {
        basePosition = position()
        baseDate = Date()
        isPlaying.toggle()
        send("playpause")
    }

    func nextTrack() { send("next track") }

    func previousTrack() { send("previous track") }

    func seek(to t: TimeInterval) {
        basePosition = t
        baseDate = Date()
        objectWillChange.send()
        send("set player position to \(t)")
    }

    func setShuffling(_ value: Bool) {
        shuffling = value
        suppressPollUntil = Date() + 1.5
        send("set shuffling to \(value)")
    }

    func setRepeating(_ value: Bool) {
        repeating = value
        suppressPollUntil = Date() + 1.5
        send("set repeating to \(value)")
    }

    /// Coalesces fast slider drags into one AppleScript call.
    func setVolume(_ value: Double) {
        let v = min(max(0, value), 1)
        volume = v
        suppressPollUntil = Date() + 1.5
        volumeTask?.cancel()
        volumeTask = Task {
            try? await Task.sleep(nanoseconds: 60_000_000)
            guard !Task.isCancelled else { return }
            _ = await runner.run(SpotifyScripts.command("set sound volume to \(Int((v * 100).rounded()))"))
        }
    }

    func openSpotify() {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.bundleID) else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }

    private func send(_ body: String) {
        Task {
            _ = await runner.run(SpotifyScripts.command(body))
            try? await Task.sleep(nanoseconds: 250_000_000)
            refresh()
        }
    }

    // MARK: - Debug

    /// Used by the snapshot renderer when Spotify is not running.
    func debugInject(track: SpotifyTrack, playing: Bool, position: TimeInterval, artwork: ProcessedArtwork?, lyrics: Lyrics?) {
        self.track = track
        isPlaying = playing
        basePosition = position
        baseDate = Date()
        self.artwork = artwork
        self.lyrics = lyrics
        lyricsState = lyrics == nil ? .missing : .found
    }
}
