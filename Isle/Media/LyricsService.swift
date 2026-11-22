import Foundation

struct LyricLine: Identifiable, Equatable {
    let id: Int
    let time: TimeInterval
    let text: String
}

struct Lyrics: Equatable {
    let lines: [LyricLine]
    let synced: Bool

    /// Index of the line being sung at `t`, nil before the first line.
    func index(at t: TimeInterval) -> Int? {
        guard synced, let first = lines.first, t + 0.2 >= first.time else { return nil }
        var lo = 0
        var hi = lines.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if lines[mid].time <= t + 0.2 { lo = mid } else { hi = mid - 1 }
        }
        return lo
    }
}

/// Synced lyrics from LRCLIB (free, no key). Only the track title, artist,
/// album and duration are sent.
actor LyricsService {
    static let shared = LyricsService()

    private var cache: [String: Lyrics?] = [:]
    private let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 8
        config.httpAdditionalHeaders = ["User-Agent": "Isle/0.1 (macOS)"]
        return URLSession(configuration: config)
    }()

    private struct Record: Decodable {
        let syncedLyrics: String?
        let plainLyrics: String?
        let duration: Double?
    }

    func lyrics(for track: SpotifyTrack) async -> Lyrics? {
        if let hit = cache[track.id] { return hit }
        var result = await get(track)
        if result == nil { result = await search(track) }
        cache.updateValue(result, forKey: track.id)
        return result
    }

    private func get(_ t: SpotifyTrack) async -> Lyrics? {
        var c = URLComponents(string: "https://lrclib.net/api/get")!
        c.queryItems = [
            .init(name: "track_name", value: t.name),
            .init(name: "artist_name", value: t.artist),
            .init(name: "album_name", value: t.album),
            .init(name: "duration", value: String(Int(t.duration.rounded()))),
        ]
        guard let url = c.url,
              let (data, response) = try? await session.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let record = try? JSONDecoder().decode(Record.self, from: data) else { return nil }
        return Self.make(record)
    }

    private func search(_ t: SpotifyTrack) async -> Lyrics? {
        var c = URLComponents(string: "https://lrclib.net/api/search")!
        c.queryItems = [
            .init(name: "track_name", value: Self.clean(t.name)),
            .init(name: "artist_name", value: Self.primaryArtist(t.artist)),
        ]
        guard let url = c.url,
              let (data, response) = try? await session.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let records = try? JSONDecoder().decode([Record].self, from: data) else { return nil }

        let synced = records.filter { $0.syncedLyrics?.isEmpty == false }
        let closest = synced.min {
            abs(($0.duration ?? 0) - t.duration) < abs(($1.duration ?? 0) - t.duration)
        }
        if let closest, abs((closest.duration ?? t.duration) - t.duration) < 5, let l = Self.make(closest) {
            return l
        }
        if let plain = records.first(where: { $0.plainLyrics?.isEmpty == false }) {
            return Self.make(plain)
        }
        return nil
    }

    private static func make(_ r: Record) -> Lyrics? {
        if let s = r.syncedLyrics, !s.isEmpty {
            let lines = parseLRC(s)
            if !lines.isEmpty { return Lyrics(lines: lines, synced: true) }
        }
        if let p = r.plainLyrics, !p.isEmpty {
            let texts = p.components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            let lines = texts.enumerated().map { LyricLine(id: $0.offset, time: 0, text: $0.element) }
            return lines.isEmpty ? nil : Lyrics(lines: lines, synced: false)
        }
        return nil
    }

    static func parseLRC(_ s: String) -> [LyricLine] {
        guard let regex = try? NSRegularExpression(pattern: #"\[(\d{1,2}):(\d{1,2}(?:[.:]\d{1,3})?)\]"#) else { return [] }
        var stamped: [(TimeInterval, String)] = []
        for raw in s.components(separatedBy: .newlines) {
            let ns = raw as NSString
            let matches = regex.matches(in: raw, range: NSRange(location: 0, length: ns.length))
            guard let last = matches.last else { continue }
            let text = ns.substring(from: last.range.location + last.range.length)
                .trimmingCharacters(in: .whitespaces)
            for m in matches {
                let minutes = Double(ns.substring(with: m.range(at: 1))) ?? 0
                let seconds = Double(ns.substring(with: m.range(at: 2)).replacingOccurrences(of: ":", with: ".")) ?? 0
                stamped.append((minutes * 60 + seconds, text.isEmpty ? "♪" : text))
            }
        }
        stamped.sort { $0.0 < $1.0 }
        var lines: [LyricLine] = []
        for (time, text) in stamped {
            if text == "♪", lines.last?.text == "♪" { continue }
            lines.append(LyricLine(id: lines.count, time: time, text: text))
        }
        return lines
    }

    static func clean(_ name: String) -> String {
        var n = name
        if let r = n.range(of: " - ") { n = String(n[..<r.lowerBound]) }
        n = n.replacingOccurrences(
            of: #"\s*[\(\[](feat|ft|with)\.?[^\)\]]*[\)\]]"#,
            with: "",
            options: [.regularExpression, .caseInsensitive]
        )
        return n.trimmingCharacters(in: .whitespaces)
    }

    static func primaryArtist(_ artist: String) -> String {
        artist.components(separatedBy: ", ").first ?? artist
    }
}
