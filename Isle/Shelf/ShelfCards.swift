import SwiftUI

private extension SpotifyController {
    var accentColor: Color { Color(nsColor: artwork?.accent ?? .systemPink) }
}

// MARK: - Now Playing

struct NowPlayingCard: View {
    @ObservedObject var spotify: SpotifyController
    /// Remembered across shelf openings.
    @AppStorage("shelfShowLyrics") private var showLyrics = false

    var body: some View {
        Group {
            if let track = spotify.track {
                player(track)
            } else {
                idle
            }
        }
        .foregroundStyle(.white)
        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: showLyrics)
    }

    private func player(_ track: SpotifyTrack) -> some View {
        VStack(spacing: 10) {
            HStack(spacing: 12) {
                ArtThumb(artwork: spotify.artwork, size: 50, radius: 11)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(track.name)
                            .font(.system(size: 15, weight: .semibold))
                            .lineLimit(1)
                        if spotify.lyrics?.synced == true {
                            Button { showLyrics.toggle() } label: {
                                Text("L")
                                    .font(.system(size: 10, weight: .heavy))
                                    .foregroundStyle(showLyrics ? .white : .black)
                                    .frame(width: 16, height: 16)
                                    .background(
                                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                                            .fill(showLyrics ? Color.white.opacity(0.25) : .white)
                                    )
                            }
                            .buttonStyle(PressableStyle())
                        }
                    }
                    Text(track.artist)
                        .font(.system(size: 13))
                        .foregroundStyle(.white.opacity(0.55))
                        .lineLimit(1)
                }
                Spacer(minLength: 6)
                Waveform(color: spotify.accentColor, playing: spotify.isPlaying)
                    .frame(width: 24, height: 16)
            }

            if showLyrics {
                TimelineView(.periodic(from: .now, by: 0.2)) { ctx in
                    LyricsStack(
                        lyrics: spotify.lyrics,
                        state: spotify.lyricsState,
                        position: spotify.position(at: ctx.date),
                        fontSize: 15,
                        before: 1,
                        after: 1,
                        center: true,
                        spacing: 6
                    )
                }
                .frame(maxHeight: .infinity)
                .clipped()
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            } else {
                VStack(spacing: 6) {
                    TimelineView(.periodic(from: .now, by: 0.5)) { ctx in
                        let pos = spotify.position(at: ctx.date)
                        let dur = track.duration
                        HStack(spacing: 8) {
                            Text(formatTime(pos)).frame(width: 32, alignment: .leading)
                            ScrubBar(progress: dur > 0 ? pos / dur : 0, height: 5, fillOpacity: 0.85) { f in
                                spotify.seek(to: f * dur)
                            }
                            Text("-" + formatTime(max(0, dur - pos))).frame(width: 38, alignment: .trailing)
                        }
                        .font(.system(size: 11, weight: .semibold).monospacedDigit())
                        .foregroundStyle(.white.opacity(0.55))
                    }
                    HStack {
                        IconButton(systemName: "quote.bubble", size: 14, opacity: 0.55) { showLyrics.toggle() }
                        Spacer()
                        IconButton(systemName: "backward.fill", size: 20) { spotify.previousTrack() }
                        Spacer()
                        IconButton(systemName: spotify.isPlaying ? "pause.fill" : "play.fill", size: 27) {
                            spotify.togglePlayPause()
                        }
                        Spacer()
                        IconButton(systemName: "forward.fill", size: 20) { spotify.nextTrack() }
                        Spacer()
                        Image(systemName: spotify.output.symbol)
                            .font(.system(size: 14, weight: .semibold))
                            .opacity(0.55)
                            .frame(width: 28, height: 28)
                            .help(spotify.output.name)
                    }
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .frame(maxHeight: .infinity, alignment: .center)
    }

    private var idle: some View {
        VStack(spacing: 10) {
            Image(systemName: "music.note")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(.white.opacity(0.35))
            if spotify.permissionDenied {
                Text("Разреши Isle управлять Spotify")
                    .font(.system(size: 13, weight: .semibold))
                Text("Настройки → Конфиденциальность → Автоматизация")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.5))
            } else {
                Text(spotify.isRunning ? "Ничего не играет" : "Spotify не запущен")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.7))
                if !spotify.isRunning {
                    Button { spotify.openSpotify() } label: {
                        Text("Открыть Spotify")
                            .font(.system(size: 12, weight: .semibold))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 6)
                            .isleGlass(Capsule())
                    }
                    .buttonStyle(PressableStyle())
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Calendar

struct CalendarCard: View {
    @ObservedObject var calendar: CalendarService
    @Environment(\.isSnapshot) private var isSnapshot

    var body: some View {
        TimelineView(.everyMinute) { ctx in
            VStack(alignment: .leading, spacing: 8) {
                header(ctx.date)
                content
                Spacer(minLength: 0)
            }
        }
        .foregroundStyle(.white)
        .padding(.top, 2)
        .onAppear { if !isSnapshot { calendar.activate() } }
    }

    private func header(_ date: Date) -> some View {
        let cal = Calendar.current
        let weekday = date.formatted(.dateTime.weekday(.abbreviated)).uppercased().replacingOccurrences(of: ".", with: "")
        let day = cal.component(.day, from: date)
        let week = cal.component(.weekOfYear, from: date)
        return HStack(spacing: 6) {
            Text(weekday).foregroundStyle(Color(red: 1, green: 0.27, blue: 0.23))
            Text("\(day)")
            Text("W\(week)").foregroundStyle(Color(red: 1, green: 0.27, blue: 0.23))
            Spacer()
            smallButton("plus") { calendar.openCalendarApp() }
            smallButton("arrow.up.left.and.arrow.down.right") { calendar.openCalendarApp() }
        }
        .font(.system(size: 14, weight: .bold))
    }

    private func smallButton(_ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .bold))
                .frame(width: 22, height: 22)
                .background(Circle().fill(Color.white.opacity(0.14)))
        }
        .buttonStyle(PressableStyle())
    }

    @ViewBuilder
    private var content: some View {
        switch calendar.status {
        case .fullAccess:
            if calendar.events.isEmpty {
                message("На сегодня всё", symbol: "checkmark.circle")
            } else {
                VStack(spacing: 6) {
                    ForEach(calendar.events.prefix(3)) { event in
                        row(event)
                    }
                }
            }
        case .notDetermined:
            VStack(alignment: .leading, spacing: 8) {
                message("Нужен доступ к календарю", symbol: "calendar.badge.exclamationmark")
                Button { calendar.requestAccess() } label: {
                    Text("Разрешить")
                        .font(.system(size: 12, weight: .semibold))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 6)
                        .isleGlass(Capsule())
                }
                .buttonStyle(PressableStyle())
            }
        default:
            message("Нет доступа: Настройки → Конфиденциальность → Календари", symbol: "lock")
        }
    }

    private func message(_ text: String, symbol: String) -> some View {
        Label(text, systemImage: symbol)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.white.opacity(0.6))
            .padding(.top, 6)
    }

    private func row(_ e: CalEvent) -> some View {
        HStack(spacing: 10) {
            Circle()
                .strokeBorder(Color(nsColor: e.color), lineWidth: 2.5)
                .frame(width: 15, height: 15)
            Text(e.title)
                .font(.system(size: 14, weight: .semibold))
                .lineLimit(1)
            Spacer(minLength: 6)
            Text(e.allDay ? "весь день" : e.start.formatted(date: .omitted, time: .shortened))
                .font(.system(size: 13, weight: .semibold).monospacedDigit())
                .foregroundStyle(.white.opacity(e.start <= Date() && !e.allDay ? 1 : 0.85))
        }
        .padding(.horizontal, 10)
        .frame(height: 32)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.white.opacity(0.09)))
        .contentShape(Rectangle())
        .onTapGesture { calendar.openCalendarApp() }
    }
}

// MARK: - Weather

struct WeatherCard: View {
    @ObservedObject var weather: WeatherService
    @Environment(\.isSnapshot) private var isSnapshot

    var body: some View {
        let d = weather.data
        ZStack {
            LinearGradient(
                colors: WeatherInfo.gradient(d?.code ?? 0, day: d?.isDay ?? true),
                startPoint: .top,
                endPoint: .bottom
            )
            Group {
                if let d {
                    ready(d)
                } else {
                    placeholder
                }
            }
            .padding(14)
        }
        .foregroundStyle(.white)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .onAppear { if !isSnapshot { weather.activate() } }
    }

    private func ready(_ d: WeatherData) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 4) {
                        Text(d.city).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                        Image(systemName: "location.fill").font(.system(size: 9, weight: .bold))
                    }
                    Text("\(d.temp)°")
                        .font(.system(size: 44, weight: .regular))
                        .padding(.top, -2)
                }
                Spacer(minLength: 6)
                VStack(alignment: .trailing, spacing: 3) {
                    Image(systemName: WeatherInfo.symbol(d.code, day: d.isDay))
                        .symbolRenderingMode(.multicolor)
                        .font(.system(size: 20))
                    Text(WeatherInfo.text(d.code))
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1)
                    Text("↑\(d.high)° ↓\(d.low)°")
                        .font(.system(size: 12, weight: .semibold))
                }
            }
            Spacer(minLength: 4)
            HStack(spacing: 0) {
                ForEach(d.hours) { h in
                    VStack(spacing: 4) {
                        Text(h.label)
                            .font(.system(size: 10, weight: .semibold))
                            .opacity(0.85)
                            .lineLimit(1)
                        Image(systemName: WeatherInfo.symbol(h.code, day: h.isDay))
                            .symbolRenderingMode(.multicolor)
                            .font(.system(size: 14))
                            .frame(height: 16)
                        Text("\(h.temp)°")
                            .font(.system(size: 12, weight: .semibold))
                    }
                    .frame(maxWidth: .infinity)
                }
            }
        }
    }

    @ViewBuilder
    private var placeholder: some View {
        VStack(spacing: 10) {
            switch weather.state {
            case .loading, .idle:
                ProgressView().controlSize(.small).tint(.white)
            case .needsPermission:
                Text("Нужна геопозиция для погоды").font(.system(size: 13, weight: .semibold))
                glassButton("Разрешить") { weather.requestPermission() }
            case .denied:
                Text("Нет доступа к геопозиции").font(.system(size: 13, weight: .semibold))
                glassButton("Открыть настройки") { weather.openLocationSettings() }
            case .failed:
                Text("Не удалось загрузить погоду").font(.system(size: 13, weight: .semibold))
                glassButton("Ещё раз") { weather.retry() }
            case .ready:
                EmptyView()
            }
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func glassButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .isleGlass(Capsule())
        }
        .buttonStyle(PressableStyle())
    }
}
