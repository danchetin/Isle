import CoreLocation
import SwiftUI

struct WeatherHour: Identifiable {
    let id: Int
    let label: String
    let temp: Int
    let code: Int
    let isDay: Bool
}

struct WeatherData {
    let city: String
    let temp: Int
    let code: Int
    let isDay: Bool
    let high: Int
    let low: Int
    let hours: [WeatherHour]
    let fetched: Date
}

enum WeatherState: Equatable {
    case idle, needsPermission, denied, loading, failed, ready
}

/// Current weather + next hours from Open-Meteo (free, no key) for the Mac's location.
/// Only coordinates rounded to ~1 km are sent.
@MainActor
final class WeatherService: NSObject, ObservableObject, CLLocationManagerDelegate {
    static let shared = WeatherService()

    @Published private(set) var state: WeatherState = .idle
    @Published private(set) var data: WeatherData?

    private let manager = CLLocationManager()
    private var asked = false
    private var injected = false
    private static let refreshInterval: TimeInterval = 20 * 60

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyKilometer
    }

    /// Called when the weather card appears; fetches only when stale.
    func activate() {
        guard !injected else { return }
        if let data, Date().timeIntervalSince(data.fetched) < Self.refreshInterval { return }
        switch manager.authorizationStatus {
        case .notDetermined:
            state = .needsPermission
            if !asked { requestPermission() }
        case .denied, .restricted:
            state = .denied
        default:
            if data == nil { state = .loading }
            manager.requestLocation()
        }
    }

    func requestPermission() {
        asked = true
        manager.requestWhenInUseAuthorization()
    }

    func retry() {
        state = .loading
        manager.requestLocation()
    }

    func openLocationSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocationServices") {
            NSWorkspace.shared.open(url)
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in
            guard self.asked || self.state == .needsPermission || self.state == .denied else { return }
            self.activate()
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        Task { @MainActor in await self.load(location) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in
            if self.data == nil { self.state = .failed }
        }
    }

    // MARK: - Open-Meteo

    private struct Response: Decodable {
        struct Current: Decodable {
            let temperature_2m: Double
            let weather_code: Int
            let is_day: Int
        }
        struct Hourly: Decodable {
            let time: [String]
            let temperature_2m: [Double]
            let weather_code: [Int]
            let is_day: [Int]
        }
        struct Daily: Decodable {
            let temperature_2m_max: [Double]
            let temperature_2m_min: [Double]
        }
        let utc_offset_seconds: Int
        let current: Current
        let hourly: Hourly
        let daily: Daily
    }

    private func load(_ location: CLLocation) async {
        let lat = (location.coordinate.latitude * 100).rounded() / 100
        let lon = (location.coordinate.longitude * 100).rounded() / 100
        var c = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
        c.queryItems = [
            .init(name: "latitude", value: String(lat)),
            .init(name: "longitude", value: String(lon)),
            .init(name: "current", value: "temperature_2m,weather_code,is_day"),
            .init(name: "hourly", value: "temperature_2m,weather_code,is_day"),
            .init(name: "daily", value: "temperature_2m_max,temperature_2m_min"),
            .init(name: "timezone", value: "auto"),
            .init(name: "forecast_days", value: "2"),
        ]
        if Locale.current.measurementSystem == .us {
            c.queryItems?.append(.init(name: "temperature_unit", value: "fahrenheit"))
        }

        async let cityName = Self.city(for: location)
        guard let url = c.url,
              let (body, response) = try? await URLSession.shared.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let r = try? JSONDecoder().decode(Response.self, from: body) else {
            if data == nil { state = .failed }
            return
        }
        let city = await cityName

        let parser = DateFormatter()
        parser.dateFormat = "yyyy-MM-dd'T'HH:mm"
        parser.timeZone = TimeZone(secondsFromGMT: r.utc_offset_seconds)
        let labeler = DateFormatter()
        labeler.setLocalizedDateFormatFromTemplate("j")
        labeler.dateFormat = labeler.dateFormat.contains("a") ? "h a" : "HH:mm"

        var hours = [WeatherHour(id: 0, label: "Сейчас", temp: Int(r.current.temperature_2m.rounded()),
                                 code: r.current.weather_code, isDay: r.current.is_day == 1)]
        let now = Date()
        for (i, t) in r.hourly.time.enumerated() where hours.count < 4 {
            guard let date = parser.date(from: t), date > now, i < r.hourly.temperature_2m.count else { continue }
            hours.append(WeatherHour(
                id: hours.count,
                label: labeler.string(from: date),
                temp: Int(r.hourly.temperature_2m[i].rounded()),
                code: r.hourly.weather_code[i],
                isDay: (r.hourly.is_day[safe: i] ?? 1) == 1
            ))
        }

        data = WeatherData(
            city: city,
            temp: Int(r.current.temperature_2m.rounded()),
            code: r.current.weather_code,
            isDay: r.current.is_day == 1,
            high: Int((r.daily.temperature_2m_max.first ?? r.current.temperature_2m).rounded()),
            low: Int((r.daily.temperature_2m_min.first ?? r.current.temperature_2m).rounded()),
            hours: hours,
            fetched: Date()
        )
        state = .ready
    }

    private static func city(for location: CLLocation) async -> String {
        let placemarks = try? await CLGeocoder().reverseGeocodeLocation(location)
        return placemarks?.first?.locality ?? placemarks?.first?.name ?? "—"
    }

    func debugInject(_ data: WeatherData) {
        injected = true
        self.data = data
        state = .ready
    }
}

extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}

/// WMO weather codes → text, SF Symbol, card gradient.
enum WeatherInfo {
    static func text(_ code: Int) -> String {
        switch code {
        case 0: "Ясно"
        case 1: "Преим. ясно"
        case 2: "Перем. облачность"
        case 3: "Пасмурно"
        case 45, 48: "Туман"
        case 51...57: "Морось"
        case 61, 63, 66: "Дождь"
        case 65, 67: "Сильный дождь"
        case 71...77: "Снег"
        case 80...82: "Ливень"
        case 85, 86: "Снегопад"
        case 95...99: "Гроза"
        default: "—"
        }
    }

    static func symbol(_ code: Int, day: Bool) -> String {
        switch code {
        case 0: day ? "sun.max.fill" : "moon.stars.fill"
        case 1, 2: day ? "cloud.sun.fill" : "cloud.moon.fill"
        case 3: "cloud.fill"
        case 45, 48: "cloud.fog.fill"
        case 51...57: "cloud.drizzle.fill"
        case 61, 63, 66: "cloud.rain.fill"
        case 65, 67: "cloud.heavyrain.fill"
        case 71...77, 85, 86: "cloud.snow.fill"
        case 80...82: day ? "cloud.sun.rain.fill" : "cloud.moon.rain.fill"
        case 95...99: "cloud.bolt.rain.fill"
        default: "cloud.fill"
        }
    }

    static func gradient(_ code: Int, day: Bool) -> [Color] {
        func c(_ hex: UInt32) -> Color {
            Color(red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
        }
        if !day { return [c(0x101C3D), c(0x2C3B6A)] }
        switch code {
        case 0, 1, 2: return [c(0x3E86D8), c(0x74B3F0)]
        case 3, 45, 48: return [c(0x58677C), c(0x8B9AAF)]
        case 51...67, 80...82: return [c(0x3B4B62), c(0x627590)]
        case 71...77, 85, 86: return [c(0x7A8DA7), c(0xB3C3D7)]
        case 95...99: return [c(0x2B2D44), c(0x4B4F6E)]
        default: return [c(0x3E86D8), c(0x74B3F0)]
        }
    }
}
