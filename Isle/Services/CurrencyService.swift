import SwiftUI

struct CurrencyQuote: Identifiable, Equatable {
    let id: String          // "usd"
    let flag: String
    let code: String        // "USD"
    let unit: String        // "֏" or "$"
    let value: Double       // today
    let history: [Double]   // oldest → newest, incl. today
    var change: Double? {   // vs previous day, fraction
        guard history.count >= 2, let prev = history.dropLast().last, prev > 0 else { return nil }
        return value / prev - 1
    }
}

/// Exchange rates against the Armenian dram from the free fawazahmed0 currency API
/// (jsDelivr, with a Cloudflare mirror). No key, no personal data sent.
@MainActor
final class CurrencyService: ObservableObject {
    static let shared = CurrencyService()

    @Published private(set) var quotes: [CurrencyQuote] = []
    @Published private(set) var updated: Date?
    @Published private(set) var failed = false
    /// Latest "units of X per 1 AMD" for every currency the API knows (converter).
    @Published private(set) var latestRates: [String: Double] = [:]

    private var users = 0
    private var timer: Timer?
    private var loading = false
    private static let days = 7

    func activate() {
        users += 1
        if let updated, Date().timeIntervalSince(updated) < 3 * 3600 { return }
        refresh()
        if timer == nil {
            timer = Timer.scheduledTimer(withTimeInterval: 3 * 3600, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            }
        }
    }

    func deactivate() {
        users = max(0, users - 1)
        if users == 0 {
            timer?.invalidate()
            timer = nil
        }
    }

    func refresh() {
        guard !loading else { return }
        loading = true
        Task {
            defer { loading = false }
            guard let latest = await Self.fetch(tag: "latest"),
                  let dateString = latest.date, let today = Self.dayFormatter.date(from: dateString) else {
                if quotes.isEmpty { failed = true }
                return
            }
            // Previous days, oldest first.
            var series: [[String: Double]] = []
            await withTaskGroup(of: (Int, [String: Double]?).self) { group in
                for back in 1..<Self.days {
                    guard let day = Calendar.current.date(byAdding: .day, value: -back, to: today) else { continue }
                    let tag = Self.dayFormatter.string(from: day)
                    group.addTask { (back, await Self.fetch(tag: tag)?.rates) }
                }
                var byBack: [Int: [String: Double]] = [:]
                for await (back, rates) in group { if let rates { byBack[back] = rates } }
                series = byBack.keys.sorted(by: >).compactMap { byBack[$0] }
            }
            series.append(latest.rates)
            latestRates = latest.rates.merging(["amd": 1]) { a, _ in a }
            quotes = Self.quotes(from: series)
            updated = Date()
            failed = false
        }
    }

    // MARK: - API

    private struct Payload {
        let date: String?
        let rates: [String: Double]
    }

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = TimeZone(identifier: "UTC")
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    private nonisolated static func fetch(tag: String) async -> Payload? {
        let urls = [
            "https://cdn.jsdelivr.net/npm/@fawazahmed0/currency-api@\(tag)/v1/currencies/amd.json",
            "https://\(tag).currency-api.pages.dev/v1/currencies/amd.json",
        ]
        for string in urls {
            guard let url = URL(string: string),
                  let (data, response) = try? await URLSession.shared.data(from: url),
                  (response as? HTTPURLResponse)?.statusCode == 200,
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let rates = obj["amd"] as? [String: Double] else { continue }
            return Payload(date: obj["date"] as? String, rates: rates)
        }
        return nil
    }

    /// API gives "1 AMD = x USD"; show "1 USD = y ֏", and BTC in dollars.
    private static func quotes(from series: [[String: Double]]) -> [CurrencyQuote] {
        func amdPer(_ code: String) -> [Double] { series.compactMap { $0[code].flatMap { $0 > 0 ? 1 / $0 : nil } } }
        var out: [CurrencyQuote] = []
        for (code, flag) in [("usd", "🇺🇸"), ("eur", "🇪🇺"), ("rub", "🇷🇺")] {
            let h = amdPer(code)
            if let last = h.last {
                out.append(CurrencyQuote(id: code, flag: flag, code: code.uppercased(), unit: "֏", value: last, history: h))
            }
        }
        let btc = series.compactMap { r -> Double? in
            guard let usd = r["usd"], let b = r["btc"], b > 0 else { return nil }
            return usd / b
        }
        if let last = btc.last {
            out.append(CurrencyQuote(id: "btc", flag: "₿", code: "BTC", unit: "$", value: last, history: btc))
        }
        return out
    }

    func debugInject(_ quotes: [CurrencyQuote]) {
        self.quotes = quotes
        updated = Date()
    }
}

// MARK: - Widget

private func formatQuote(_ q: CurrencyQuote) -> String {
    let f = NumberFormatter()
    f.numberStyle = .decimal
    f.maximumFractionDigits = q.value >= 1000 ? 0 : 2
    f.minimumFractionDigits = q.value >= 1000 ? 0 : 2
    let n = f.string(from: NSNumber(value: q.value)) ?? "\(q.value)"
    return q.unit == "$" ? "$\(n)" : "\(n) \(q.unit)"
}

private struct ChangeLabel: View {
    let change: Double?
    var body: some View {
        if let c = change {
            let up = c >= 0
            Text("\(up ? "▲" : "▼") \(String(format: "%.2f", abs(c) * 100))%")
                .font(.system(size: 10, weight: .bold).monospacedDigit())
                .foregroundStyle(up ? Color(red: 0.35, green: 0.85, blue: 0.5) : Color(red: 1, green: 0.42, blue: 0.42))
        }
    }
}

private func normalized(_ h: [Double]) -> [Double] {
    guard let lo = h.min(), let hi = h.max(), hi > lo else { return h.map { _ in 0.5 } }
    return h.map { ($0 - lo) / (hi - lo) }
}

struct CurrencyCard: View {
    @ObservedObject var rates: CurrencyService
    var small = false
    @Environment(\.isSnapshot) private var isSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: small ? 8 : 7) {
            HStack {
                Image(systemName: "dollarsign.arrow.circlepath")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(Color(red: 0.4, green: 0.85, blue: 0.55))
                Text("Курсы").font(.system(size: 13, weight: .semibold)).foregroundStyle(.white.opacity(0.6))
                Spacer()
                if !small, let updated = rates.updated {
                    Text(updated.formatted(date: .omitted, time: .shortened))
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.white.opacity(0.35))
                }
                Button { CurrencyConverterPanel.shared.toggle() } label: {
                    Image(systemName: "arrow.left.arrow.right")
                        .font(.system(size: 10, weight: .bold))
                        .frame(width: 22, height: 22)
                        .background(Circle().fill(Color.white.opacity(0.12)))
                }
                .buttonStyle(PressableStyle())
                .help("Конвертер (⌥⇧C)")
            }
            if rates.quotes.isEmpty {
                Group {
                    if rates.failed {
                        Text("Не удалось загрузить курсы")
                    } else {
                        ProgressView().controlSize(.small).tint(.white)
                    }
                }
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white.opacity(0.5))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if small {
                ForEach(rates.quotes.prefix(2)) { q in
                    VStack(alignment: .leading, spacing: 1) {
                        Text("\(q.flag) \(q.code)").font(.system(size: 11, weight: .semibold)).foregroundStyle(.white.opacity(0.6))
                        Text(formatQuote(q)).font(.system(size: 20, weight: .bold, design: .rounded).monospacedDigit())
                        ChangeLabel(change: q.change)
                    }
                }
                Spacer(minLength: 0)
            } else {
                ForEach(rates.quotes.prefix(4)) { q in
                    HStack(spacing: 8) {
                        Text(q.flag).font(.system(size: 14)).frame(width: 20)
                        Text(q.code).font(.system(size: 12, weight: .semibold)).foregroundStyle(.white.opacity(0.65)).frame(width: 34, alignment: .leading)
                        Sparkline(values: normalized(q.history), color: (q.change ?? 0) >= 0
                                  ? Color(red: 0.35, green: 0.85, blue: 0.5) : Color(red: 1, green: 0.42, blue: 0.42))
                            .frame(height: 18)
                        VStack(alignment: .trailing, spacing: 0) {
                            Text(formatQuote(q)).font(.system(size: 13, weight: .semibold).monospacedDigit())
                            ChangeLabel(change: q.change)
                        }
                        .frame(width: 100, alignment: .trailing)
                    }
                }
                Spacer(minLength: 0)
            }
        }
        .foregroundStyle(.white)
        .onAppear { if !isSnapshot { rates.activate() } }
        .onDisappear { if !isSnapshot { rates.deactivate() } }
    }
}
