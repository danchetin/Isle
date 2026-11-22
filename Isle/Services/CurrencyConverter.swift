import AppKit
import Carbon.HIToolbox
import SwiftUI

/// "5000", "1 usd", "100 eur rub", "20$ в драмах", "4 USD / AMD" → conversions.
enum CurrencyQueryParser {
    struct Query: Equatable {
        let amount: Double
        let from: String
        let to: [String]
    }

    private static let aliases: [String: String] = [
        "$": "usd", "usd": "usd", "доллар": "usd", "доллара": "usd", "долларов": "usd", "долларах": "usd", "бакс": "usd", "баксов": "usd",
        "€": "eur", "eur": "eur", "евро": "eur",
        "₽": "rub", "rub": "rub", "руб": "rub", "рубль": "rub", "рубля": "rub", "рублей": "rub", "рублях": "rub",
        "֏": "amd", "amd": "amd", "драм": "amd", "драма": "amd", "драмов": "amd", "драмах": "amd", "драмы": "amd",
        "₿": "btc", "btc": "btc", "биткоин": "btc", "биткоинов": "btc",
        "£": "gbp", "фунт": "gbp", "фунтов": "gbp",
        "₾": "gel", "лари": "gel",
        "¥": "cny", "юань": "cny", "юаней": "cny",
        "₸": "kzt", "тенге": "kzt",
    ]
    private static let separators: Set<String> = ["/", "в", "во", "to", "in", "=", "→", "->", "на"]

    static func parse(_ raw: String, known: Set<String>) -> Query? {
        var s = raw.lowercased()
        // "1 000" → "1000"; "20$" → "20 $"; "1,5" → "1.5"
        s = s.replacingOccurrences(of: #"(?<=\d)[\s ](?=\d{3}\b)"#, with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: #"(?<=\d),(?=\d{1,2}\b)"#, with: ".", options: .regularExpression)
        s = s.replacingOccurrences(of: #"([$€₽֏₿£₾¥₸/=])"#, with: " $1 ", options: .regularExpression)
        s = s.replacingOccurrences(of: #"(?<=\d)(?=[a-zа-я])"#, with: " ", options: .regularExpression)

        var amount: Double?
        var codes: [String] = []
        for token in s.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init) {
            if separators.contains(token) { continue }
            if amount == nil, let n = Double(token) { amount = n; continue }
            if let code = aliases[token] ?? (token.count == 3 && known.contains(token) ? token : nil) {
                if !codes.contains(code) { codes.append(code) }
            }
        }
        guard amount != nil || !codes.isEmpty else { return nil }
        let from = codes.first ?? "amd"
        var to = Array(codes.dropFirst())
        if to.isEmpty {
            to = from == "amd" ? ["usd", "eur", "rub"] : ["amd", from == "usd" ? "eur" : "usd"]
        }
        return Query(amount: amount ?? 1, from: from, to: to)
    }

    /// rates: units of a currency per 1 AMD.
    static func convert(_ q: Query, rates: [String: Double]) -> [(code: String, value: Double)] {
        guard let fromRate = rates[q.from], fromRate > 0 else { return [] }
        let amd = q.amount / fromRate
        return q.to.compactMap { code in rates[code].map { (code, amd * $0) } }
    }

    static func format(_ v: Double) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.locale = Locale(identifier: "ru_RU")
        if abs(v) >= 1 {
            f.maximumFractionDigits = 2
            f.minimumFractionDigits = abs(v) >= 1000 ? 0 : 2
        } else {
            f.maximumSignificantDigits = 4
            f.usesSignificantDigits = true
        }
        return f.string(from: NSNumber(value: v)) ?? "\(v)"
    }

    static func symbol(_ code: String) -> String {
        ["usd": "$", "eur": "€", "rub": "₽", "amd": "֏", "btc": "₿", "gbp": "£", "gel": "₾", "cny": "¥", "kzt": "₸"][code] ?? code.uppercased()
    }
}

@MainActor
final class CurrencyConverterModel: ObservableObject {
    @Published var text = ""

    var results: [(code: String, value: Double)] {
        let rates = CurrencyService.shared.latestRates
        guard let q = CurrencyQueryParser.parse(text, known: Set(rates.keys)) else { return [] }
        return CurrencyQueryParser.convert(q, rates: rates)
    }

    var query: CurrencyQueryParser.Query? {
        CurrencyQueryParser.parse(text, known: Set(CurrencyService.shared.latestRates.keys))
    }
}

/// ⌥⇧C: Spotlight-style converter at the mouse. Enter copies the first result.
@MainActor
final class CurrencyConverterPanel {
    static let shared = CurrencyConverterPanel()
    private var panel: OverlayPanel?
    private var keyMonitor: Any?
    private var clickMonitor: Any?
    private let model = CurrencyConverterModel()

    func toggle() {
        if panel != nil { close() } else { open() }
    }

    private func open() {
        if CurrencyService.shared.latestRates.isEmpty { CurrencyService.shared.refresh() }
        model.text = ""
        let size = NSSize(width: 460, height: 230)
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        var origin = NSPoint(x: mouse.x - size.width / 2, y: mouse.y - size.height - 12)
        if let f = screen?.visibleFrame {
            origin.x = min(max(origin.x, f.minX + 8), f.maxX - size.width - 8)
            origin.y = min(max(origin.y, f.minY + 8), f.maxY - size.height - 8)
        }
        let p = OverlayPanel(contentRect: NSRect(origin: origin, size: size), styleMask: [.borderless, .nonactivatingPanel],
                             backing: .buffered, defer: false)
        p.allowsKey = true
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.level = .popUpMenu
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.contentView = NSHostingView(rootView: CurrencyConverterView(model: model, rates: CurrencyService.shared) { [weak self] in
            self?.copyFirst()
        })
        p.makeKeyAndOrderFront(nil)
        panel = p

        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == UInt16(kVK_Escape) else { return event }
            MainActor.assumeIsolated { self?.close() }
            return nil
        }
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated { self?.close() }
        }
    }

    func close() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
        keyMonitor = nil
        clickMonitor = nil
        panel?.orderOut(nil)
        panel = nil
    }

    private func copyFirst() {
        guard let first = model.results.first else { return }
        copy(first.value, code: first.code)
    }

    func copy(_ value: Double, code: String) {
        let plain = CurrencyQueryParser.format(value).replacingOccurrences(of: "\u{00a0}", with: " ")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(plain, forType: .string)
        close()
        AgentsService.shared.notify(title: "\(plain) \(CurrencyQueryParser.symbol(code))", subtitle: "Скопировано")
    }
}

struct CurrencyConverterView: View {
    @ObservedObject var model: CurrencyConverterModel
    @ObservedObject var rates: CurrencyService
    let onSubmit: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        let results = model.results
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "dollarsign.arrow.circlepath")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(Color(red: 0.4, green: 0.85, blue: 0.55))
                TextField("5000  ·  1 usd  ·  100 eur rub  ·  20$ в драмах", text: $model.text)
                    .textFieldStyle(.plain)
                    .font(.system(size: 22, weight: .medium))
                    .focused($focused)
                    .onSubmit(onSubmit)
            }
            Divider().overlay(Color.white.opacity(0.1))
            if rates.latestRates.isEmpty {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Загружаю курсы…").foregroundStyle(.white.opacity(0.5))
                }
            } else if results.isEmpty {
                Text(model.text.isEmpty ? "Пиши сумму и валюты. Без валюты — драмы." : "Не понял запрос")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white.opacity(0.45))
            } else {
                VStack(spacing: 4) {
                    ForEach(Array(results.enumerated()), id: \.offset) { i, r in
                        HStack(alignment: .firstTextBaseline) {
                            Text("\(CurrencyQueryParser.format(r.value)) \(CurrencyQueryParser.symbol(r.code))")
                                .font(.system(size: i == 0 ? 24 : 17, weight: i == 0 ? .bold : .semibold, design: .rounded).monospacedDigit())
                            Spacer()
                            if let q = model.query {
                                Text("\(CurrencyQueryParser.format(q.amount)) \(q.from.uppercased()) → \(r.code.uppercased())")
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundStyle(.white.opacity(0.4))
                            }
                            if i == 0 {
                                Text("↩︎").font(.system(size: 12, weight: .bold)).foregroundStyle(.white.opacity(0.35))
                            }
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.white.opacity(i == 0 ? 0.1 : 0)))
                        .contentShape(Rectangle())
                        .onTapGesture { CurrencyConverterPanel.shared.copy(r.value, code: r.code) }
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .foregroundStyle(.white)
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(Color(white: 0.08).opacity(0.97)))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(Color.white.opacity(0.12)))
        .environment(\.colorScheme, .dark)
        .onAppear { focused = true }
    }
}
