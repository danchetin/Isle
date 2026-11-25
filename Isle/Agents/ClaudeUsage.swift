import Foundation
import Security
import SwiftUI

/// Claude Code token usage read from its local transcripts (~/.claude/projects/**/*.jsonl).
/// Only timestamps, ids and token counts are parsed — never message text. Files are read
/// once, then only the bytes appended since the last scan.
final class ClaudeUsageScanner: @unchecked Sendable {
    struct Entry {
        let date: Date
        let tokens: Int
    }

    private var offsets: [String: UInt64] = [:]
    private var entries: [String: Entry] = [:] // key: message id + request id (dedupes rewrites)
    private let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let horizon: TimeInterval = 7 * 24 * 3600
    private static let marker = Data("\"usage\"".utf8)

    func scan() -> [Entry] {
        let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects")
        let cutoff = Date().addingTimeInterval(-Self.horizon)
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey]
        if let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys) {
            for case let url as URL in walker where url.pathExtension == "jsonl" {
                guard let v = try? url.resourceValues(forKeys: Set(keys)),
                      let modified = v.contentModificationDate, modified > cutoff,
                      let size = v.fileSize else { continue }
                read(url, size: UInt64(size))
            }
        }
        entries = entries.filter { $0.value.date > cutoff }
        return entries.values.sorted { $0.date < $1.date }
    }

    private func read(_ url: URL, size: UInt64) {
        var offset = offsets[url.path] ?? 0
        if size < offset { offset = 0 } // rewritten / truncated
        guard size > offset, let handle = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? handle.close() }
        try? handle.seek(toOffset: offset)
        guard let data = try? handle.readToEnd(), let lastNewline = data.lastIndex(of: 0x0A) else { return }
        let complete = data[data.startIndex...lastNewline]
        offsets[url.path] = offset + UInt64(complete.count)
        for line in complete.split(separator: 0x0A) where line.range(of: Self.marker) != nil {
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  let message = obj["message"] as? [String: Any],
                  let usage = message["usage"] as? [String: Any],
                  let stamp = obj["timestamp"] as? String,
                  let date = iso.date(from: stamp) else { continue }
            func n(_ k: String) -> Int { (usage[k] as? NSNumber)?.intValue ?? 0 }
            let tokens = n("input_tokens") + n("output_tokens") + n("cache_creation_input_tokens") + n("cache_read_input_tokens")
            let key = "\(message["id"] as? String ?? stamp)|\(obj["requestId"] as? String ?? "")"
            entries[key] = Entry(date: date, tokens: tokens)
        }
    }
}

/// 5-hour usage windows (start = first message, floored to the hour), like Claude's limits.
@MainActor
final class ClaudeUsageService: ObservableObject {
    static let shared = ClaudeUsageService()

    struct Window: Equatable {
        let start: Date
        let end: Date
        let tokens: Int
    }

    @Published private(set) var current: Window?
    /// Largest finished window in the last week — the yardstick for the bar.
    @Published private(set) var peak = 0
    @Published private(set) var today = 0
    @Published private(set) var loaded = false
    /// Real plan percentages from Anthropic (nil until fetched / when unavailable).
    @Published private(set) var plan: PlanUsage?
    @Published private(set) var planNote: String?
    private var lastPlanFetch = Date.distantPast

    private let scanner = ClaudeUsageScanner()
    private var timer: Timer?
    private var users = 0
    private var scanning = false
    private static let windowLength: TimeInterval = 5 * 3600

    func activate() {
        users += 1
        refresh()
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    func deactivate() {
        users = max(0, users - 1)
        guard users == 0 else { return }
        timer?.invalidate()
        timer = nil
    }

    func refreshPlan(force: Bool = false) {
        guard force || Date().timeIntervalSince(lastPlanFetch) > 300 else { return }
        lastPlanFetch = Date()
        Task {
            switch await ClaudePlanUsageClient.fetch() {
            case .success(let usage):
                plan = usage
                planNote = nil
                IsleLog.write("claude plan: 5h=\(usage.fiveHour.map { Int($0.percent) } ?? -1)% week=\(usage.week.map { Int($0.percent) } ?? -1)%")
            case .failure(let f):
                planNote = switch f {
                case .noToken: String(localized: "Sign in to Claude Code to see plan limits")
                case .expired: String(localized: "Claude Code token expired — it refreshes the next time Claude runs")
                case .http(let code): String(localized: "Usage server unavailable (\(code))")
                case .format: String(localized: "Couldn't read the usage server's response")
                }
                IsleLog.write("claude plan: unavailable (\(f))")
            }
        }
    }

    func refresh() {
        refreshPlan()
        guard !scanning else { return }
        scanning = true
        let scanner = self.scanner
        Task {
            let entries = await Task.detached(priority: .utility) { scanner.scan() }.value
            apply(entries)
            scanning = false
            loaded = true
        }
    }

    private func apply(_ entries: [ClaudeUsageScanner.Entry]) {
        var windows: [Window] = []
        var start: Date?
        var last: Date?
        var tokens = 0
        for e in entries {
            if let s = start, e.date < s.addingTimeInterval(Self.windowLength),
               let l = last, e.date.timeIntervalSince(l) < Self.windowLength {
                tokens += e.tokens
            } else {
                if let s = start { windows.append(Window(start: s, end: s.addingTimeInterval(Self.windowLength), tokens: tokens)) }
                start = Calendar.current.dateInterval(of: .hour, for: e.date)?.start ?? e.date
                tokens = e.tokens
            }
            last = e.date
        }
        if let s = start { windows.append(Window(start: s, end: s.addingTimeInterval(Self.windowLength), tokens: tokens)) }

        let now = Date()
        let active = windows.last.flatMap { $0.end > now ? $0 : nil }
        if active != current { current = active }
        peak = windows.filter { $0 != active }.map(\.tokens).max() ?? (active?.tokens ?? 0)
        let dayStart = Calendar.current.startOfDay(for: now)
        today = entries.filter { $0.date >= dayStart }.map(\.tokens).reduce(0, +)
    }

    func debugInject(current: Window?, peak: Int, today: Int) {
        self.current = current
        self.peak = peak
        self.today = today
        loaded = true
    }
}

func formatTokens(_ n: Int) -> String {
    switch n {
    case 1_000_000...: return String(format: "%.1fM", Double(n) / 1_000_000)
    case 1_000...: return String(format: "%.0fK", Double(n) / 1_000)
    default: return "\(n)"
    }
}

/// "Окно 5ч" line with a bar and the time until reset, for the Agents widget.
struct ClaudeUsageBar: View {
    @ObservedObject var usage: ClaudeUsageService
    var compact = false
    @Environment(\.isSnapshot) private var isSnapshot

    var body: some View {
        TimelineView(.everyMinute) { ctx in
            VStack(alignment: .leading, spacing: 4) {
                if let plan = usage.plan {
                    if let h = plan.fiveHour { planRow(compact ? String(localized: "5h") : String(localized: "5h limit"), h, now: ctx.date) }
                    if let w = plan.week { planRow(compact ? String(localized: "Wk") : String(localized: "This week"), w, now: ctx.date) }
                } else if let w = usage.current {
                    let fraction = usage.peak > 0 ? Double(w.tokens) / Double(max(usage.peak, w.tokens)) : 0
                    HStack(spacing: 6) {
                        Image(systemName: "hourglass").font(.system(size: 10, weight: .bold))
                        Text(compact ? formatTokens(w.tokens) : String(localized: "5h window · \(formatTokens(w.tokens))"))
                        Spacer(minLength: 4)
                        Text("↻ \(Self.remaining(w.end, now: ctx.date))")
                            .foregroundStyle(.white.opacity(0.5))
                            .lineLimit(1)
                            .fixedSize()
                            .help("Time until the window resets")
                    }
                    .font(.system(size: 11, weight: .semibold).monospacedDigit())
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.white.opacity(0.12))
                            Capsule()
                                .fill(fraction > 0.85 ? Color(red: 1, green: 0.42, blue: 0.42) : AgentKind.claude.color)
                                .frame(width: max(4, geo.size.width * fraction))
                        }
                    }
                    .frame(height: 4)
                    .help("Usage in the current 5-hour window compared with the week's biggest window (\(formatTokens(usage.peak))). Today in total: \(formatTokens(usage.today)).")
                } else if usage.loaded {
                    HStack(spacing: 6) {
                        Image(systemName: "hourglass").font(.system(size: 10, weight: .bold))
                        Text(compact ? String(localized: "Window free") : String(localized: "5h window not started · today \(formatTokens(usage.today))"))
                    }
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.5))
                }
            }
        }
        .foregroundStyle(.white)
        .onAppear { if !isSnapshot { usage.activate() } }
        .onDisappear { if !isSnapshot { usage.deactivate() } }
    }

    private func planRow(_ title: String, _ limit: PlanUsage.Limit, now: Date) -> some View {
        let fraction = min(max(limit.percent / 100, 0), 1)
        return VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text("\(title) · \(Int(limit.percent.rounded()))%")
                Spacer(minLength: 4)
                if let reset = limit.resetsAt {
                    Text("↻ \(Self.remaining(reset, now: now))")
                        .foregroundStyle(.white.opacity(0.5))
                        .lineLimit(1)
                        .fixedSize()
                }
            }
            .font(.system(size: 11, weight: .semibold).monospacedDigit())
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.12))
                    Capsule()
                        .fill(fraction > 0.85 ? Color(red: 1, green: 0.42, blue: 0.42) : AgentKind.claude.color)
                        .frame(width: max(4, geo.size.width * fraction))
                }
            }
            .frame(height: 4)
        }
        .help("Claude plan limits, as in the Claude menu")
    }

    static func remaining(_ end: Date, now: Date) -> String {
        let mins = max(0, Int(end.timeIntervalSince(now) / 60))
        if mins >= 48 * 60 { return String(localized: "\(mins / 1440)d \((mins % 1440) / 60)h") }
        return mins >= 60 ? String(localized: "\(mins / 60)h \(mins % 60)m") : String(localized: "\(mins)m")
    }
}

// MARK: - Real plan usage (same numbers as Claude's own menu)

struct PlanUsage: Equatable {
    struct Limit: Equatable {
        let percent: Double   // 0…100
        let resetsAt: Date?
    }
    let fiveHour: Limit?
    let week: Limit?
    let fetched: Date
}

/// Asks Anthropic for the plan's utilisation with Claude Code's own OAuth token from the Keychain
/// item "Claude Code-credentials". The token is only sent to api.anthropic.com, kept in memory
/// until it expires, never written, logged or refreshed by Isle. Undocumented endpoint: any
/// failure falls back to the local estimate.
///
/// The item is read through /usr/bin/security, the tool Claude Code itself writes it with, so it is
/// already on the item's access list. Reading it directly made macOS ask for the keychain password
/// again after every token refresh: Claude Code rewrites the item and "Always Allow" for Isle is lost.
enum ClaudePlanUsageClient {
    enum Failure: Error { case noToken, expired, http(Int), format }

    /// Last token read; reused until shortly before it expires or the server rejects it.
    @MainActor private static var cached: Credentials?

    @MainActor
    static func fetch() async -> Result<PlanUsage, Failure> {
        if let c = cached, let expiry = c.expiresAt, expiry < Date().addingTimeInterval(60) { cached = nil }
        if cached == nil { cached = await Task.detached(priority: .utility) { readCredentials() }.value }
        guard let creds = cached else { return .failure(.noToken) }
        if let expiry = creds.expiresAt, expiry < Date() { cached = nil; return .failure(.expired) }
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
        request.setValue("Bearer \(creds.token)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 10
        guard let (data, response) = try? await URLSession.shared.data(for: request) else { return .failure(.http(0)) }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 401 { cached = nil }
        guard status == 200 else { return .failure(status == 401 ? .expired : .http(status)) }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return .failure(.format) }
        let usage = PlanUsage(fiveHour: limit(obj["five_hour"]), week: limit(obj["seven_day"]), fetched: Date())
        return usage.fiveHour == nil && usage.week == nil ? .failure(.format) : .success(usage)
    }

    private static func limit(_ any: Any?) -> PlanUsage.Limit? {
        guard let d = any as? [String: Any], let u = (d["utilization"] as? NSNumber)?.doubleValue else { return nil }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        let reset = (d["resets_at"] as? String).flatMap { iso.date(from: $0) ?? plain.date(from: $0) }
        return .init(percent: u <= 1 && u > 0 ? u * 100 : u, resetsAt: reset)
    }

    private struct Credentials: Sendable {
        let token: String
        let expiresAt: Date?
    }

    private nonisolated static func readCredentials() -> Credentials? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["find-generic-password", "-s", "Claude Code-credentials", "-w"]
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let raw = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0,
              var text = String(data: raw, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else { return nil }
        // `security -w` prints non-ASCII secrets as hex.
        if !text.hasPrefix("{"), text.count % 2 == 0, text.allSatisfy(\.isHexDigit) {
            var bytes = [UInt8]()
            var i = text.startIndex
            while i < text.endIndex {
                let j = text.index(i, offsetBy: 2)
                guard let b = UInt8(text[i..<j], radix: 16) else { return nil }
                bytes.append(b)
                i = j
            }
            text = String(decoding: bytes, as: UTF8.self)
        }
        guard let data = text.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = obj["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String, !token.isEmpty else { return nil }
        let expires = (oauth["expiresAt"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue / 1000) }
        return Credentials(token: token, expiresAt: expires)
    }
}
