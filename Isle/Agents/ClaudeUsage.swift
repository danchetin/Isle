import Foundation
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

    func refresh() {
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
                if let w = usage.current {
                    let fraction = usage.peak > 0 ? Double(w.tokens) / Double(max(usage.peak, w.tokens)) : 0
                    HStack(spacing: 6) {
                        Image(systemName: "hourglass").font(.system(size: 10, weight: .bold))
                        Text(compact ? formatTokens(w.tokens) : "Окно 5ч · \(formatTokens(w.tokens))")
                        Spacer(minLength: 4)
                        Text("↻ \(Self.remaining(w.end, now: ctx.date))")
                            .foregroundStyle(.white.opacity(0.5))
                            .lineLimit(1)
                            .fixedSize()
                            .help("Окно сбросится через это время")
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
                    .help("Расход в текущем 5-часовом окне относительно самого большого окна за неделю (\(formatTokens(usage.peak))). Сегодня всего: \(formatTokens(usage.today)).")
                } else if usage.loaded {
                    HStack(spacing: 6) {
                        Image(systemName: "hourglass").font(.system(size: 10, weight: .bold))
                        Text(compact ? "Окно свободно" : "Окно 5ч не начато · сегодня \(formatTokens(usage.today))")
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

    static func remaining(_ end: Date, now: Date) -> String {
        let mins = max(0, Int(end.timeIntervalSince(now) / 60))
        return mins >= 60 ? "\(mins / 60)ч \(mins % 60)м" : "\(mins)м"
    }
}
