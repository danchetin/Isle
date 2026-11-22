import SwiftUI

// MARK: - Options

enum LockKey {
    static let clockFont = "lockClockFont"
    static let clockColor = "lockClockColor"
    static let player = "lockPlayer"
    static let background = "lockBackground"
    static let widgets = "lockWidgets"
    static let lyrics = "lockShowLyrics"
}

enum LockClockFont: String, CaseIterable {
    case regular, rounded, thin
    var title: String { ["regular": "Обычный", "rounded": "Округлый", "thin": "Тонкий"][rawValue]! }
    var design: Font.Design { self == .rounded ? .rounded : .default }
    var weight: Font.Weight { self == .thin ? .ultraLight : .bold }
}

enum LockClockColor: String, CaseIterable {
    case white, accent
    var title: String { self == .white ? "Белый" : "Из обложки" }
}

enum LockPlayerStyle: String, CaseIterable {
    case full, compact, hidden
    var title: String { ["full": "Полный", "compact": "Карточка", "hidden": "Скрыт"][rawValue]! }
}

enum LockBackground: String, CaseIterable {
    case artwork, blurred
    var title: String { self == .artwork ? "Обложка" : "Размытая" }
}

enum LockWidget: String, CaseIterable, Identifiable {
    case weather, calendar, batteries, system, agents, currency
    var id: String { rawValue }
    var title: String {
        ["weather": "Погода", "calendar": "Календарь", "batteries": "Батареи",
         "system": "Система", "agents": "Агенты", "currency": "Курсы"][rawValue]!
    }
    var symbol: String {
        ["weather": "cloud.sun.fill", "calendar": "calendar", "batteries": "battery.75percent",
         "system": "cpu", "agents": "sparkle", "currency": "dollarsign.arrow.circlepath"][rawValue]!
    }
    static let maxCount = 4

    static func decode(_ raw: String) -> [LockWidget] {
        raw.split(separator: ",").compactMap { LockWidget(rawValue: String($0)) }
    }

    static func encode(_ list: [LockWidget]) -> String {
        list.map(\.rawValue).joined(separator: ",")
    }
}

// MARK: - Widgets row under the clock

/// iOS-style lock screen widgets: small glass tiles with monochrome content.
struct LockWidgetsRow: View {
    let widgets: [LockWidget]
    @ObservedObject private var weather = WeatherService.shared
    @ObservedObject private var calendar = CalendarService.shared
    @ObservedObject private var batteries = BatteryService.shared
    @ObservedObject private var stats = SystemStatsService.shared
    @ObservedObject private var agents = AgentsService.shared
    @ObservedObject private var rates = CurrencyService.shared
    @Environment(\.isSnapshot) private var isSnapshot

    var body: some View {
        HStack(spacing: 12) {
            ForEach(widgets) { w in
                tile(w)
                    .frame(width: 168, height: 62)
                    .isleGlass(RoundedRectangle(cornerRadius: 20, style: .continuous))
            }
        }
        .foregroundStyle(.white)
        .onAppear {
            guard !isSnapshot else { return }
            if widgets.contains(.weather) { weather.activate() }
            if widgets.contains(.calendar) { calendar.activate() }
            if widgets.contains(.batteries) { batteries.activate() }
            if widgets.contains(.system) { stats.activate() }
            if widgets.contains(.currency) { rates.activate() }
        }
        .onDisappear {
            guard !isSnapshot else { return }
            if widgets.contains(.batteries) { batteries.deactivate() }
            if widgets.contains(.system) { stats.deactivate() }
            if widgets.contains(.currency) { rates.deactivate() }
        }
    }

    @ViewBuilder
    private func tile(_ w: LockWidget) -> some View {
        switch w {
        case .weather:
            if let d = weather.data {
                row(symbol: WeatherInfo.symbol(d.code, day: d.isDay), big: "\(d.temp)°", small: "\(d.city) · ↑\(d.high)° ↓\(d.low)°")
            } else {
                row(symbol: "cloud.sun.fill", big: "—", small: "Погода")
            }
        case .calendar:
            if let e = calendar.events.first {
                row(symbol: "calendar", big: e.allDay ? "Весь день" : e.start.formatted(date: .omitted, time: .shortened), small: e.title)
            } else {
                row(symbol: "calendar", big: "Свободно", small: "Сегодня без событий")
            }
        case .batteries:
            HStack(spacing: 10) {
                ForEach(batteries.devices.prefix(3)) { d in
                    RingGauge(fraction: d.level, color: .white, symbol: d.symbol, size: 38, lineWidth: 3.5)
                }
            }
        case .system:
            row(symbol: "cpu", big: "\(Int((stats.cpu * 100).rounded()))%",
                small: stats.temperature.map { "CPU · \(Int($0.rounded()))°C" } ?? "CPU")
        case .agents:
            if let s = agents.active ?? agents.latest {
                row(symbol: s.kind.symbol, big: s.state == .done ? "Готово" : (s.state == .waiting ? "Ждёт тебя" : "Работает"),
                    small: s.currentStep?.title ?? s.project)
            } else {
                row(symbol: "sparkle", big: "Агенты", small: "Сейчас не работают")
            }
        case .currency:
            if let usd = rates.quotes.first {
                row(symbol: "dollarsign.circle", big: CurrencyQueryParser.format(usd.value) + " ֏",
                    small: usd.change.map { String(format: "USD %@%.2f%%", $0 >= 0 ? "▲" : "▼", abs($0) * 100) } ?? "USD")
            } else {
                row(symbol: "dollarsign.circle", big: "—", small: "Курсы")
            }
        }
    }

    private func row(symbol: String, big: String, small: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 20, weight: .semibold))
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 0) {
                Text(big).font(.system(size: 17, weight: .bold, design: .rounded)).lineLimit(1)
                Text(small).font(.system(size: 11, weight: .medium)).opacity(0.7).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
    }
}

// MARK: - Compact player card

struct LockCompactPlayer: View {
    @ObservedObject var spotify: SpotifyController

    var body: some View {
        NowPlayingCard(spotify: spotify)
            .frame(width: 330, height: 128)
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            .isleGlass(RoundedRectangle(cornerRadius: 28, style: .continuous))
    }
}

// MARK: - Editor panel

private struct Segmented<T: Hashable>: View {
    let options: [T]
    let title: (T) -> String
    @Binding var selection: T

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.self) { o in
                Button { withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { selection = o } } label: {
                    Text(title(o))
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white.opacity(selection == o ? 1 : 0.6))
                        .frame(maxWidth: .infinity)
                        .frame(height: 28)
                        .background(Capsule().fill(Color.white.opacity(selection == o ? 0.22 : 0)))
                        .contentShape(Capsule())
                }
                .buttonStyle(PressableStyle())
            }
        }
        .padding(3)
        .background(Capsule().fill(Color.white.opacity(0.08)))
    }
}

private struct ToggleRow: View {
    let title: String
    @Binding var on: Bool

    var body: some View {
        Button { withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { on.toggle() } } label: {
            HStack {
                Text(title).font(.system(size: 13, weight: .semibold))
                Spacer()
                Capsule()
                    .fill(on ? Color.green : Color.white.opacity(0.2))
                    .frame(width: 40, height: 24)
                    .overlay(alignment: on ? .trailing : .leading) {
                        Circle().fill(.white).frame(width: 20, height: 20).padding(2)
                    }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Right-side glass panel shown while customizing; every change applies live.
struct LockEditorPanel: View {
    let onDone: () -> Void

    @AppStorage(PrefKey.clockStyle) private var clockStyle = ClockStyle.large.rawValue
    @AppStorage(LockKey.clockFont) private var clockFont = LockClockFont.regular.rawValue
    @AppStorage(LockKey.clockColor) private var clockColor = LockClockColor.white.rawValue
    @AppStorage(PrefKey.clockDepth) private var clockDepth = true
    @AppStorage(LockKey.player) private var player = LockPlayerStyle.full.rawValue
    @AppStorage(LockKey.background) private var background = LockBackground.artwork.rawValue
    @AppStorage(LockKey.widgets) private var widgetsRaw = ""
    @AppStorage(LockKey.lyrics) private var lyrics = false

    var body: some View {
        let widgets = LockWidget.decode(widgetsRaw)
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Экран блокировки").font(.system(size: 16, weight: .bold))
                Spacer()
                Button(action: onDone) {
                    Text("Готово")
                        .font(.system(size: 13, weight: .semibold))
                        .padding(.horizontal, 14)
                        .frame(height: 30)
                        .background(Capsule().fill(Color.accentColor))
                }
                .buttonStyle(PressableStyle())
            }

            section("Часы")
            Segmented(options: ClockStyle.allCasesForEditor, title: { $0 == .large ? "Большие" : "Компактные" },
                      selection: Binding(get: { ClockStyle(rawValue: clockStyle) ?? .large }, set: { clockStyle = $0.rawValue }))
            Segmented(options: LockClockFont.allCases, title: \.title,
                      selection: Binding(get: { LockClockFont(rawValue: clockFont) ?? .regular }, set: { clockFont = $0.rawValue }))
            Segmented(options: LockClockColor.allCases, title: \.title,
                      selection: Binding(get: { LockClockColor(rawValue: clockColor) ?? .white }, set: { clockColor = $0.rawValue }))
            ToggleRow(title: "Clock Depth (объект поверх часов)", on: $clockDepth)

            section("Виджеты под часами · \(widgets.count)/\(LockWidget.maxCount)")
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8), GridItem(.flexible())], spacing: 8) {
                ForEach(LockWidget.allCases) { w in
                    let index = widgets.firstIndex(of: w)
                    let full = index == nil && widgets.count >= LockWidget.maxCount
                    Button {
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                            var list = widgets
                            if let index { list.remove(at: index) } else if !full { list.append(w) }
                            widgetsRaw = LockWidget.encode(list)
                        }
                    } label: {
                        VStack(spacing: 4) {
                            Image(systemName: w.symbol).font(.system(size: 16, weight: .semibold))
                            Text(w.title).font(.system(size: 10, weight: .semibold))
                        }
                        .frame(maxWidth: .infinity)
                        .frame(height: 52)
                        .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(index != nil ? Color.accentColor.opacity(0.35) : Color.white.opacity(0.08)))
                        .overlay(alignment: .topTrailing) {
                            if let index {
                                Text("\(index + 1)")
                                    .font(.system(size: 9, weight: .heavy))
                                    .frame(width: 16, height: 16)
                                    .background(Circle().fill(Color.accentColor))
                                    .padding(4)
                            }
                        }
                        .opacity(full ? 0.35 : 1)
                    }
                    .buttonStyle(PressableStyle())
                }
            }

            section("Плеер")
            Segmented(options: LockPlayerStyle.allCases, title: \.title,
                      selection: Binding(get: { LockPlayerStyle(rawValue: player) ?? .full }, set: { player = $0.rawValue }))
            ToggleRow(title: "Тексты песен по умолчанию", on: $lyrics)

            section("Фон")
            Segmented(options: LockBackground.allCases, title: \.title,
                      selection: Binding(get: { LockBackground(rawValue: background) ?? .artwork }, set: { background = $0.rawValue }))
            Spacer(minLength: 0)
        }
        .foregroundStyle(.white)
        .padding(18)
        .frame(width: 340)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(RoundedRectangle(cornerRadius: 26, style: .continuous).fill(Color.black.opacity(0.55)))
        .isleGlass(RoundedRectangle(cornerRadius: 26, style: .continuous))
    }

    private func section(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(.white.opacity(0.5))
            .padding(.top, 4)
    }
}

extension ClockStyle {
    static let allCasesForEditor: [ClockStyle] = [.large, .inline]
}
