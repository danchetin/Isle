import SwiftUI

/// Square (cardHeight × cardHeight) versions of the shelf widgets.

private let red = Color(red: 1, green: 0.27, blue: 0.23)

// MARK: - Now Playing

struct SmallNowPlayingCard: View {
    @ObservedObject var spotify: SpotifyController

    var body: some View {
        Group {
            if let track = spotify.track {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .top) {
                        ArtThumb(artwork: spotify.artwork, size: 58, radius: 12)
                        Spacer()
                        Waveform(color: Color(nsColor: spotify.artwork?.accent ?? .systemPink), playing: spotify.isPlaying)
                            .frame(width: 20, height: 14)
                    }
                    VStack(alignment: .leading, spacing: 1) {
                        Text(track.name)
                            .font(.system(size: 13, weight: .semibold))
                            .lineLimit(1)
                        Text(track.artist)
                            .font(.system(size: 11))
                            .foregroundStyle(.white.opacity(0.55))
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    HStack {
                        IconButton(systemName: "backward.fill", size: 14) { spotify.previousTrack() }
                        Spacer()
                        IconButton(systemName: spotify.isPlaying ? "pause.fill" : "play.fill", size: 20) {
                            spotify.togglePlayPause()
                        }
                        Spacer()
                        IconButton(systemName: "forward.fill", size: 14) { spotify.nextTrack() }
                    }
                }
                .padding(.vertical, 4)
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "music.note")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.35))
                    Text(spotify.isRunning ? String(localized: "Nothing playing") : String(localized: "Spotify isn't running"))
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.6))
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
                .onTapGesture { if !spotify.isRunning { spotify.openSpotify() } }
            }
        }
        .foregroundStyle(.white)
    }
}

// MARK: - Calendar

struct SmallCalendarCard: View {
    @ObservedObject var calendar: CalendarService
    @Environment(\.isSnapshot) private var isSnapshot

    var body: some View {
        TimelineView(.everyMinute) { ctx in
            VStack(alignment: .leading, spacing: 0) {
                Text(ctx.date.formatted(.dateTime.weekday(.wide)).uppercased())
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(red)
                    .lineLimit(1)
                Text("\(Calendar.current.component(.day, from: ctx.date))")
                    .font(.system(size: 44, weight: .semibold))
                    .padding(.top, -4)
                Spacer(minLength: 4)
                next
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(Color.white.opacity(0.07)))
        .foregroundStyle(.white)
        .contentShape(Rectangle())
        .onTapGesture { calendar.openCalendarApp() }
        .onAppear { if !isSnapshot { calendar.activate() } }
    }

    @ViewBuilder
    private var next: some View {
        if !calendar.hasAccess {
            Text("No calendar access")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white.opacity(0.55))
        } else if let e = calendar.events.first {
            HStack(alignment: .top, spacing: 7) {
                Capsule()
                    .fill(Color(nsColor: e.color))
                    .frame(width: 3)
                VStack(alignment: .leading, spacing: 2) {
                    Text(e.title)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(2)
                    Text(e.allDay ? String(localized: "all day") : e.start.formatted(date: .omitted, time: .shortened))
                        .font(.system(size: 11, weight: .semibold).monospacedDigit())
                        .foregroundStyle(.white.opacity(0.6))
                }
            }
            .fixedSize(horizontal: false, vertical: true)
        } else {
            Text("No events today")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white.opacity(0.55))
        }
    }
}

// MARK: - Weather

struct SmallWeatherCard: View {
    @ObservedObject var weather: WeatherService
    @Environment(\.isSnapshot) private var isSnapshot

    var body: some View {
        let d = weather.data
        ZStack {
            LinearGradient(colors: WeatherInfo.gradient(d?.code ?? 0, day: d?.isDay ?? true), startPoint: .top, endPoint: .bottom)
            if let d {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 4) {
                        Text(d.city).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                        Image(systemName: "location.fill").font(.system(size: 8, weight: .bold))
                    }
                    Text("\(d.temp)°")
                        .font(.system(size: 42, weight: .regular))
                        .padding(.top, -3)
                    Spacer(minLength: 2)
                    Image(systemName: WeatherInfo.symbol(d.code, day: d.isDay))
                        .symbolRenderingMode(.multicolor)
                        .font(.system(size: 17))
                    Text(WeatherInfo.text(d.code))
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1)
                        .padding(.top, 3)
                    Text("↑\(d.high)° ↓\(d.low)°")
                        .font(.system(size: 12, weight: .semibold))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(14)
            } else {
                WeatherCard(weather: weather) // same states/buttons as the wide card
            }
        }
        .foregroundStyle(.white)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .onAppear { if !isSnapshot { weather.activate() } }
    }
}

// MARK: - System Stats

struct SmallStatsCard: View {
    @ObservedObject var stats: SystemStatsService
    @AppStorage("smallStatsPage") private var page = 0
    @AppStorage(SmallStatsStyle.key) private var style = SmallStatsStyle.single.rawValue
    @Environment(\.isSnapshot) private var isSnapshot

    var body: some View {
        Group {
            if style == SmallStatsStyle.quad.rawValue { quad } else { single }
        }
        .foregroundStyle(.white)
        .onAppear { if !isSnapshot { stats.activate() } }
        .onDisappear { if !isSnapshot { stats.deactivate() } }
    }

    /// Four rings: CPU, GPU, RAM, Disk.
    private var quad: some View {
        let ringColor = Color(red: 0.25, green: 0.52, blue: 1)
        let diskUsed = 1 - stats.diskFree / max(stats.diskTotal, 1)
        let items: [(String, Double?)] = [
            ("CPU", stats.cpu),
            ("GPU", stats.gpu),
            ("RAM", stats.memoryUsed / max(stats.memoryTotal, 1)),
            ("Disk", diskUsed),
        ]
        return LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 12) {
            ForEach(items, id: \.0) { title, value in
                ZStack {
                    Circle().stroke(Color.white.opacity(0.14), lineWidth: 6)
                    Circle()
                        .trim(from: 0, to: CGFloat(min(max(value ?? 0, 0.001), 1)))
                        .stroke(ringColor, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .animation(.spring(response: 0.5, dampingFraction: 0.85), value: value ?? 0)
                    VStack(spacing: 0) {
                        Text(title)
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.75))
                        Text(value.map { "\(Int(($0 * 100).rounded()))%" } ?? "—")
                            .font(.system(size: 13, weight: .semibold).monospacedDigit())
                            .contentTransition(.numericText())
                    }
                }
                .frame(width: 60, height: 60)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// One big ring; tap pages CPU → RAM → GPU.
    private var single: some View {
        let m = metric(page % 3)
        return VStack(spacing: 10) {
            ZStack {
                Circle().stroke(m.color.opacity(0.2), lineWidth: 10)
                Circle()
                    .trim(from: 0, to: CGFloat(min(max(m.fraction, 0.001), 1)))
                    .stroke(m.color, style: StrokeStyle(lineWidth: 10, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.spring(response: 0.5, dampingFraction: 0.85), value: m.fraction)
                VStack(spacing: 0) {
                    Text(m.value)
                        .font(.system(size: 22, weight: .bold, design: .rounded))
                        .contentTransition(.numericText())
                    Text(m.title)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.6))
                }
            }
            .frame(width: 96, height: 96)
            Text(m.caption)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(0.6))
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) { page = (page + 1) % 3 }
        }
    }

    private func metric(_ page: Int) -> (title: String, value: String, caption: String, fraction: Double, color: Color) {
        switch page {
        case 1:
            let used = stats.memoryUsed / 1_073_741_824
            let total = stats.memoryTotal / 1_073_741_824
            return ("RAM", "\(Int((stats.memoryUsed / max(stats.memoryTotal, 1) * 100).rounded()))%",
                    String(format: String(localized: "%.1f of %.0f GB"), used, total), stats.memoryUsed / max(stats.memoryTotal, 1),
                    Color(red: 0.3, green: 0.85, blue: 0.5))
        case 2:
            return ("GPU", stats.gpu.map { "\(Int(($0 * 100).rounded()))%" } ?? "—", String(localized: "graphics"), stats.gpu ?? 0,
                    Color(red: 0.3, green: 0.8, blue: 0.95))
        default:
            let temp = stats.temperature.map { "\(Int($0.rounded()))°C" } ?? "—"
            return ("CPU", "\(Int((stats.cpu * 100).rounded()))%", temp, stats.cpu,
                    Color(red: 0.55, green: 0.56, blue: 1))
        }
    }
}

/// Look of the square System card, switched from the shelf editor.
enum SmallStatsStyle: String {
    case single
    case quad

    static let key = "smallStatsStyle"

    static var current: SmallStatsStyle {
        get { SmallStatsStyle(rawValue: UserDefaults.standard.string(forKey: key) ?? "") ?? .single }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: key) }
    }
}

// MARK: - Batteries

struct SmallBatteriesCard: View {
    @ObservedObject var batteries: BatteryService
    @Environment(\.isSnapshot) private var isSnapshot

    var body: some View {
        let devices = Array(batteries.devices.prefix(4))
        Group {
            if devices.isEmpty {
                Text("No devices")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.5))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                    ForEach(devices) { d in
                        VStack(spacing: 4) {
                            RingGauge(fraction: d.level, color: color(d), symbol: d.symbol, size: 50, lineWidth: 4.5)
                            Text("\(Int((d.level * 100).rounded()))%")
                                .font(.system(size: 11, weight: .semibold).monospacedDigit())
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .foregroundStyle(.white)
        .onAppear { if !isSnapshot { batteries.activate() } }
        .onDisappear { if !isSnapshot { batteries.deactivate() } }
    }

    private func color(_ d: BatteryDevice) -> Color {
        if d.level < 0.2, !d.charging { return Color(red: 1, green: 0.3, blue: 0.3) }
        return Color(red: 0.3, green: 0.85, blue: 0.45)
    }
}
