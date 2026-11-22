import SwiftUI

/// Full-screen Now Playing for the lock screen.
/// Layers, back to front: blurred art → sharp art → vignette → clock → cut-out subject
/// (Clock Depth: the subject stands in front of the clock) → controls.
struct LockScreenView: View {
    @ObservedObject var spotify: SpotifyController
    var input: PasswordInputMonitor?
    var onClose: () -> Void
    /// Remembered across locks.
    @AppStorage("lockShowLyrics") private var storedShowLyrics = false
    /// Snapshot override.
    private let forcedLyrics: Bool?
    private var showLyrics: Bool { forcedLyrics ?? storedShowLyrics }

    @AppStorage(PrefKey.clockDepth) private var clockDepth = true
    @AppStorage(PrefKey.clockStyle) private var clockStyleRaw = ClockStyle.large.rawValue

    init(spotify: SpotifyController, input: PasswordInputMonitor? = nil, onClose: @escaping () -> Void, showLyrics: Bool? = nil) {
        self.spotify = spotify
        self.input = input
        self.onClose = onClose
        forcedLyrics = showLyrics
    }

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            let style = ClockStyle(rawValue: clockStyleRaw) ?? .large
            ZStack {
                ArtBackdrop(artwork: spotify.artwork, size: size)
                LockClock(style: style, size: size)
                if clockDepth, let artwork = spotify.artwork, let subject = artwork.subject {
                    SubjectLayer(image: subject, size: size)
                        .id(artwork.url)
                        .transition(.opacity)
                }
                controls(size: size)
            }
            .frame(width: size.width, height: size.height)
            .clipped()
            .animation(.easeInOut(duration: 0.7), value: spotify.artwork?.url)
        }
        .ignoresSafeArea()
        .environment(\.colorScheme, .dark)
    }

    private func controls(size: CGSize) -> some View {
        let playerWidth = min(showLyrics ? 560 : 640, size.width * (showLyrics ? 0.38 : 0.42))
        return ZStack(alignment: .bottom) {
            HStack(alignment: .bottom, spacing: size.width * 0.07) {
                LockPlayer(spotify: spotify)
                    .frame(width: playerWidth)
                if showLyrics {
                    LockLyrics(spotify: spotify)
                        .frame(width: playerWidth, height: size.height * 0.46)
                        .transition(.opacity.combined(with: .move(edge: .trailing)))
                }
            }
            .padding(.bottom, size.height * 0.115)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)

            HStack(alignment: .bottom) {
                Image(systemName: spotify.output.symbol)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.9))
                    .frame(width: 46, height: 46)
                    .isleGlass(Circle())
                    .help(spotify.output.name)
                Spacer()
                HStack(spacing: 2) {
                    IconButton(systemName: "quote.bubble", size: 16, opacity: showLyrics ? 1 : 0.75) {
                        storedShowLyrics.toggle()
                    }
                    IconButton(systemName: "eye.slash", size: 15, opacity: 0.75, action: onClose)
                        .help("Скрыть до следующей блокировки")
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 6)
                .frame(height: 46)
                .isleGlass(Capsule())
            }
            .padding(.horizontal, 36)
            .padding(.bottom, 30)

            if let input {
                PasswordIndicator(input: input)
                    .padding(.bottom, 33)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            }
        }
        .animation(.spring(response: 0.55, dampingFraction: 0.86), value: showLyrics)
    }
}

// MARK: - Background

private struct ArtMask: View {
    let size: CGSize
    var body: some View {
        RadialGradient(
            gradient: Gradient(stops: [
                .init(color: .white, location: 0),
                .init(color: .white, location: 0.5),
                .init(color: .white.opacity(0), location: 1),
            ]),
            center: .center,
            startRadius: 0,
            endRadius: max(size.width, size.height) * 0.6
        )
    }
}

private struct Vignette: View {
    var body: some View {
        LinearGradient(
            stops: [
                .init(color: .black.opacity(0.45), location: 0),
                .init(color: .black.opacity(0), location: 0.3),
                .init(color: .black.opacity(0), location: 0.42),
                .init(color: .black.opacity(0.42), location: 0.68),
                .init(color: .black.opacity(0.78), location: 1),
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }
}

private struct FillImage: View {
    let image: NSImage
    let size: CGSize
    var body: some View {
        Image(nsImage: image)
            .resizable()
            .interpolation(.high)
            .scaledToFill()
            .frame(width: size.width, height: size.height)
            .clipped()
    }
}

struct ArtBackdrop: View {
    let artwork: ProcessedArtwork?
    let size: CGSize

    var body: some View {
        ZStack {
            Color.black
            if let artwork {
                ZStack {
                    FillImage(image: artwork.blurred, size: size)
                    FillImage(image: artwork.image, size: size)
                        .mask(ArtMask(size: size))
                }
                .id(artwork.url)
                .transition(.opacity)
            } else {
                LinearGradient(colors: [Color(white: 0.18), Color(white: 0.04)], startPoint: .top, endPoint: .bottom)
            }
            Vignette()
        }
    }
}

/// The cover's subject, drawn above the clock with the same framing as the backdrop.
private struct SubjectLayer: View {
    let image: NSImage
    let size: CGSize

    var body: some View {
        ZStack {
            FillImage(image: image, size: size)
            Vignette()
        }
        .mask(FillImage(image: image, size: size))
        .mask(ArtMask(size: size))
        .allowsHitTesting(false)
    }
}

// MARK: - Clock

struct LockClock: View {
    let style: ClockStyle
    let size: CGSize

    var body: some View {
        TimelineView(.everyMinute) { ctx in
            let date = ctx.date
            Group {
                switch style {
                case .large:
                    VStack(spacing: -size.height * 0.012) {
                        Text(date, format: .dateTime.weekday(.wide).day().month(.wide))
                            .font(.system(size: size.height * 0.027, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.85))
                        Text(Self.time(date))
                            .font(.system(size: size.height * 0.2, weight: .bold))
                            .tracking(-size.height * 0.004)
                            .foregroundStyle(.white.opacity(0.93))
                    }
                case .inline:
                    HStack(alignment: .firstTextBaseline, spacing: size.height * 0.016) {
                        Text(Self.time(date))
                            .font(.system(size: size.height * 0.05, weight: .bold))
                            .foregroundStyle(.white)
                        Text(date, format: .dateTime.weekday(.abbreviated).day().month(.abbreviated))
                            .font(.system(size: size.height * 0.05, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.72))
                    }
                }
            }
            .shadow(color: .black.opacity(0.22), radius: 14, y: 2)
            .frame(maxWidth: .infinity)
            .padding(.top, size.height * (style == .large ? 0.055 : 0.1))
            .frame(maxHeight: .infinity, alignment: .top)
        }
        .allowsHitTesting(false)
    }

    static func time(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = .current
        f.setLocalizedDateFormatFromTemplate("jmm")
        let uses12h = f.dateFormat.contains("a")
        f.dateFormat = uses12h ? "h:mm" : "HH:mm"
        return f.string(from: date)
    }
}

// MARK: - Player

struct LockPlayer: View {
    @ObservedObject var spotify: SpotifyController

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 3) {
                Text(spotify.track?.name ?? "Spotify")
                    .font(.system(size: 22, weight: .semibold))
                    .lineLimit(1)
                Text(spotify.track?.artist ?? "")
                    .font(.system(size: 21, weight: .regular))
                    .foregroundStyle(.white.opacity(0.62))
                    .lineLimit(1)
            }
            .padding(.bottom, 22)

            TimelineView(.periodic(from: .now, by: 0.25)) { ctx in
                let pos = spotify.position(at: ctx.date)
                let dur = spotify.track?.duration ?? 0
                VStack(spacing: 4) {
                    ScrubBar(progress: dur > 0 ? pos / dur : 0, height: 7) { f in
                        spotify.seek(to: f * dur)
                    }
                    HStack {
                        Text(formatTime(pos))
                        Spacer()
                        Text("-" + formatTime(max(0, dur - pos)))
                    }
                    .font(.system(size: 13, weight: .semibold).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.55))
                }
            }

            HStack {
                IconButton(systemName: "shuffle", size: 18, opacity: spotify.shuffling ? 1 : 0.5) {
                    spotify.setShuffling(!spotify.shuffling)
                }
                Spacer()
                IconButton(systemName: "backward.fill", size: 30) { spotify.previousTrack() }
                Spacer()
                IconButton(systemName: spotify.isPlaying ? "pause.fill" : "play.fill", size: 42) {
                    spotify.togglePlayPause()
                }
                Spacer()
                IconButton(systemName: "forward.fill", size: 30) { spotify.nextTrack() }
                Spacer()
                IconButton(systemName: "repeat", size: 18, opacity: spotify.repeating ? 1 : 0.5) {
                    spotify.setRepeating(!spotify.repeating)
                }
            }
            .padding(.top, 14)

            HStack(spacing: 14) {
                Image(systemName: "speaker.fill").font(.system(size: 12, weight: .semibold))
                ScrubBar(progress: spotify.volume, height: 6, fillOpacity: 0.7, live: true) { f in
                    spotify.setVolume(f)
                }
                Image(systemName: "speaker.wave.3.fill").font(.system(size: 12, weight: .semibold))
            }
            .foregroundStyle(.white.opacity(0.6))
            .padding(.top, 18)
        }
        .foregroundStyle(.white)
        .shadow(color: .black.opacity(0.3), radius: 14, y: 3)
    }
}

// MARK: - Lyrics

struct LockLyrics: View {
    @ObservedObject var spotify: SpotifyController

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.2)) { ctx in
            LyricsStack(
                lyrics: spotify.lyrics,
                state: spotify.lyricsState,
                position: spotify.position(at: ctx.date),
                fontSize: 30,
                before: 2,
                after: 5,
                spacing: 18
            )
        }
        .shadow(color: .black.opacity(0.55), radius: 16, y: 2)
        .mask(
            LinearGradient(
                stops: [
                    .init(color: .clear, location: 0),
                    .init(color: .black, location: 0.1),
                    .init(color: .black, location: 0.82),
                    .init(color: .clear, location: 1),
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        )
    }
}
