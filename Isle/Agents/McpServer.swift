import Foundation

/// Tools Isle offers over MCP. Every tool is off until enabled in Isle's menu;
/// only enabled tools are listed to the client.
enum McpTool: String, CaseIterable {
    case notchNotify = "notch_notify"
    case nowPlaying = "now_playing"
    case playbackControl = "playback_control"
    case systemStats = "system_stats"
    case setVolume = "set_volume"
    case weather = "weather"
    case calendarToday = "calendar_today"

    var title: String {
        switch self {
        case .notchNotify: String(localized: "Message in the notch")
        case .nowPlaying: String(localized: "Now playing")
        case .playbackControl: String(localized: "Spotify controls")
        case .systemStats: String(localized: "System stats")
        case .setVolume: String(localized: "Volume")
        case .weather: String(localized: "Weather")
        case .calendarToday: String(localized: "Calendar events")
        }
    }

    var description: String {
        switch self {
        case .notchNotify: "Show a short message in the MacBook notch (Isle). Use it to tell the user a long task finished or needs attention."
        case .nowPlaying: "Get the track currently playing in Spotify on this Mac."
        case .playbackControl: "Control Spotify playback on this Mac."
        case .systemStats: "Get CPU load, CPU temperature, memory, GPU and disk usage of this Mac."
        case .setVolume: "Set this Mac's output volume (0–100)."
        case .weather: "Get the current weather where this Mac is."
        case .calendarToday: "List the user's remaining calendar events for today (titles and times)."
        }
    }

    var inputSchema: [String: Any] {
        switch self {
        case .notchNotify:
            return ["type": "object",
                    "properties": ["title": ["type": "string", "description": "Short title, under 40 characters"],
                                   "subtitle": ["type": "string", "description": "Optional second line"]],
                    "required": ["title"]]
        case .playbackControl:
            return ["type": "object",
                    "properties": ["action": ["type": "string", "enum": ["play", "pause", "toggle", "next", "previous"]]],
                    "required": ["action"]]
        case .setVolume:
            return ["type": "object",
                    "properties": ["level": ["type": "integer", "minimum": 0, "maximum": 100]],
                    "required": ["level"]]
        default:
            return ["type": "object", "properties": [String: Any]()]
        }
    }

    private var key: String { "mcp.enabled.\(rawValue)" }

    var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: key) }
        nonmutating set { UserDefaults.standard.set(newValue, forKey: key) }
    }

    var definition: [String: Any] {
        ["name": rawValue, "description": description, "inputSchema": inputSchema]
    }
}

/// `Isle --mcp`: MCP server over stdio (newline-delimited JSON-RPC 2.0).
/// Each request is forwarded to the running Isle app through the local socket.
enum McpServer {
    static func run() -> Never {
        setvbuf(stdout, nil, _IOLBF, 0)
        while let line = readLine(strippingNewline: true) {
            guard let data = line.data(using: .utf8),
                  let msg = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let id = msg["id"] else { continue } // notifications need no answer
            let method = msg["method"] as? String ?? ""
            let params = msg["params"] as? [String: Any] ?? [:]
            switch method {
            case "initialize":
                let version = params["protocolVersion"] as? String ?? "2025-06-18"
                respond(id, result: [
                    "protocolVersion": version,
                    "capabilities": ["tools": ["listChanged": false]],
                    "serverInfo": ["name": "isle", "version": "0.1.0"],
                    "instructions": "Isle is the user's notch app on their Mac. Tools only work while Isle is running; the user enables each tool in Isle's menu.",
                ])
            case "ping":
                respond(id, result: [String: Any]())
            case "tools/list":
                let enabled = askIsle(["type": "mcp_tools"])?["enabled"] as? [String] ?? []
                let tools = McpTool.allCases.filter { enabled.contains($0.rawValue) }.map(\.definition)
                respond(id, result: ["tools": tools])
            case "tools/call":
                let name = params["name"] as? String ?? ""
                let args = params["arguments"] as? [String: Any] ?? [:]
                let reply = askIsle(["type": "mcp_call", "tool": name, "args": args])
                let text = reply?["text"] as? String ?? "Isle is not running."
                let isError = reply == nil || (reply?["error"] as? Bool ?? false)
                respond(id, result: ["content": [["type": "text", "text": text]], "isError": isError])
            default:
                respondError(id, code: -32601, message: "Method not found: \(method)")
            }
        }
        exit(0)
    }

    private static func askIsle(_ request: [String: Any]) -> [String: Any]? {
        guard let data = try? JSONSerialization.data(withJSONObject: request),
              let reply = IsleSocket.send(data, expectReply: true, timeout: 5),
              let obj = try? JSONSerialization.jsonObject(with: reply) as? [String: Any] else { return nil }
        return obj
    }

    private static func respond(_ id: Any, result: Any) {
        write(["jsonrpc": "2.0", "id": id, "result": result])
    }

    private static func respondError(_ id: Any, code: Int, message: String) {
        write(["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": message]])
    }

    private static func write(_ obj: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: obj, options: [.withoutEscapingSlashes]),
              let line = String(data: data, encoding: .utf8) else { return }
        print(line)
    }
}

/// Runs inside the app: executes an MCP tool call and replies with text.
@MainActor
enum McpHandler {
    static func enabledTools() -> [String: Any] {
        ["enabled": McpTool.allCases.filter(\.isEnabled).map(\.rawValue)]
    }

    static func call(_ name: String, args: [String: Any], reply: @escaping ([String: Any]) -> Void) {
        guard let tool = McpTool(rawValue: name) else {
            return reply(["text": "Unknown tool \(name).", "error": true])
        }
        guard tool.isEnabled else {
            return reply(["text": "The \(name) tool is turned off. The user can enable it in Isle's menu → MCP.", "error": true])
        }
        switch tool {
        case .notchNotify:
            let title = String((args["title"] as? String ?? "").prefix(60))
            guard !title.isEmpty else { return reply(["text": "title is required", "error": true]) }
            AgentsService.shared.notify(title: title, subtitle: String((args["subtitle"] as? String ?? "").prefix(80)))
            reply(["text": "Shown in the notch."])
        case .nowPlaying:
            let s = SpotifyController.shared
            guard let t = s.track else { return reply(["text": s.isRunning ? "Spotify is running, nothing is playing." : "Spotify is not running."]) }
            reply(["text": "\(s.isPlaying ? "Playing" : "Paused"): \(t.name) — \(t.artist) (\(t.album)), \(formatTime(s.position())) / \(formatTime(t.duration))"])
        case .playbackControl:
            let s = SpotifyController.shared
            switch args["action"] as? String {
            case "play": if !s.isPlaying { s.togglePlayPause() }
            case "pause": if s.isPlaying { s.togglePlayPause() }
            case "toggle": s.togglePlayPause()
            case "next": s.nextTrack()
            case "previous": s.previousTrack()
            default: return reply(["text": "action must be play, pause, toggle, next or previous", "error": true])
            }
            reply(["text": "Done."])
        case .systemStats:
            let stats = SystemStatsService.shared
            stats.activate() // CPU load needs two samples ~2 s apart
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) {
                MainActor.assumeIsolated {
                    let gb = 1_073_741_824.0
                    var parts = ["CPU \(Int((stats.cpu * 100).rounded()))%"]
                    if let t = stats.temperature { parts.append("CPU temperature \(Int(t.rounded()))°C") }
                    parts.append(String(format: "memory %.1f of %.0f GB", stats.memoryUsed / gb, stats.memoryTotal / gb))
                    if let g = stats.gpu { parts.append("GPU \(Int((g * 100).rounded()))%") }
                    parts.append(String(format: "disk %.0f GB free", stats.diskFree / 1e9))
                    stats.deactivate()
                    reply(["text": parts.joined(separator: ", ")])
                }
            }
        case .setVolume:
            guard let level = (args["level"] as? NSNumber)?.doubleValue else { return reply(["text": "level is required", "error": true]) }
            guard SystemVolume.isControllable else { return reply(["text": "This output device's volume can't be set.", "error": true]) }
            SystemVolume.volume = Float(min(max(level, 0), 100) / 100)
            reply(["text": "Volume set to \(Int(level))%."])
        case .weather:
            guard let d = WeatherService.shared.data else {
                WeatherService.shared.activate()
                return reply(["text": "Weather isn't loaded yet (Isle needs Location access). Try again shortly.", "error": true])
            }
            reply(["text": "\(d.city): \(d.temp)°, \(WeatherInfo.text(d.code)), high \(d.high)°, low \(d.low)°"])
        case .calendarToday:
            let cal = CalendarService.shared
            cal.activate()
            guard cal.hasAccess else { return reply(["text": "Isle has no Calendar access.", "error": true]) }
            if cal.events.isEmpty { return reply(["text": "No more events today."]) }
            let lines = cal.events.map { e in
                "\(e.allDay ? "all day" : e.start.formatted(date: .omitted, time: .shortened)) — \(e.title)"
            }
            reply(["text": lines.joined(separator: "\n")])
        }
    }
}
