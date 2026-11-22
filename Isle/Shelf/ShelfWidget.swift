import CoreGraphics
import Foundation

/// Widgets the notch shelf can show, in user-chosen order.
enum ShelfWidget: String, CaseIterable, Identifiable {
    case nowPlaying
    case calendar
    case weather
    case systemStats
    case batteries
    case agents

    var id: String { rawValue }

    var title: String {
        switch self {
        case .nowPlaying: "Плеер"
        case .calendar: "Календарь"
        case .weather: "Погода"
        case .systemStats: "Система"
        case .batteries: "Батареи"
        case .agents: "Агенты"
        }
    }

    var symbol: String {
        switch self {
        case .nowPlaying: "music.note"
        case .calendar: "calendar"
        case .weather: "cloud.sun.fill"
        case .systemStats: "cpu"
        case .batteries: "battery.75percent"
        case .agents: "sparkle"
        }
    }

    var width: CGFloat {
        switch self {
        case .nowPlaying: 320
        case .calendar: 300
        case .weather: 290
        case .systemStats: 340
        case .batteries: 300
        case .agents: 360
        }
    }

    private static let key = "shelfWidgets"
    static let defaults: [ShelfWidget] = [.nowPlaying, .calendar, .weather]

    static func load() -> [ShelfWidget] {
        guard let raw = UserDefaults.standard.string(forKey: key) else { return defaults }
        if raw.isEmpty { return [] }
        return raw.split(separator: ",").compactMap { ShelfWidget(rawValue: String($0)) }
    }

    static func save(_ widgets: [ShelfWidget]) {
        UserDefaults.standard.set(widgets.map(\.rawValue).joined(separator: ","), forKey: key)
    }
}

/// Square (same width as height) or wide card.
enum WidgetSize: String, Equatable {
    case small
    case medium

    private static let key = "shelfWidgetSizes"

    static func load() -> [ShelfWidget: WidgetSize] {
        let raw = UserDefaults.standard.string(forKey: key) ?? ""
        var out: [ShelfWidget: WidgetSize] = [:]
        for pair in raw.split(separator: ",") {
            let parts = pair.split(separator: ":")
            guard parts.count == 2, let w = ShelfWidget(rawValue: String(parts[0])),
                  let size = WidgetSize(rawValue: String(parts[1])) else { continue }
            out[w] = size
        }
        return out
    }

    static func save(_ sizes: [ShelfWidget: WidgetSize]) {
        let raw = sizes.map { "\($0.key.rawValue):\($0.value.rawValue)" }.joined(separator: ",")
        UserDefaults.standard.set(raw, forKey: key)
    }
}
