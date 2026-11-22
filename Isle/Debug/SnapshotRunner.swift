import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// `Isle --snapshot <outDir> [--art <image>]`
/// Renders the lock screen and notch views to PNGs without locking the Mac.
/// Uses the live Spotify track when there is one, otherwise sample data (+ optional cover).
@MainActor
enum SnapshotRunner {
    static func run(arguments: [String]) {
        Prefs.register()
        let outDir = URL(fileURLWithPath: arguments.first ?? FileManager.default.currentDirectoryPath)
        try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        var artPath: String?
        if let i = arguments.firstIndex(of: "--art"), i + 1 < arguments.count { artPath = arguments[i + 1] }

        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)

        Task { @MainActor in
            let spotify = SpotifyController.shared
            spotify.start()

            // Wait for track, cover and lyrics (or give up and use sample data).
            let deadline = Date().addingTimeInterval(12)
            while Date() < deadline {
                if spotify.track != nil, spotify.artwork != nil,
                   spotify.lyricsState == .found || spotify.lyricsState == .missing { break }
                try? await Task.sleep(nanoseconds: 200_000_000)
            }

            if spotify.track == nil {
                print("no Spotify track; using sample data")
                injectSample(spotify, artPath: artPath)
            } else if ProcessInfo.processInfo.environment["ISLE_FORCE_PLAYING"] == "1", let t = spotify.track {
                spotify.debugInject(track: t, playing: true, position: spotify.position(), artwork: spotify.artwork, lyrics: spotify.lyrics)
            }
            print("track: \(spotify.track?.name ?? "-") — \(spotify.track?.artist ?? "-")")
            print("artwork: \(spotify.artwork != nil), subject cutout: \(spotify.artwork?.subject != nil)")
            print("lyrics: \(spotify.lyricsState), lines: \(spotify.lyrics?.lines.count ?? 0), synced: \(spotify.lyrics?.synced ?? false)")
            print("output: \(spotify.output.name) [\(spotify.output.symbol)]")

            let screen = NSScreen.screens.first?.frame.size ?? CGSize(width: 1470, height: 956)
            render(LockScreenView(spotify: spotify, onClose: {}), size: screen, name: "lock.png", dir: outDir)
            render(LockScreenView(spotify: spotify, onClose: {}, showLyrics: true), size: screen, name: "lock-lyrics.png", dir: outDir)
            let typing = PasswordInputMonitor()
            typing.debugSet(count: 7)
            render(LockScreenView(spotify: spotify, input: typing, onClose: {}), size: screen, name: "lock-typing.png", dir: outDir)

            injectShelfSamples()
            // Real system stats (no permissions needed): a few samples for the sparklines.
            SystemStatsService.shared.activate()
            BatteryService.shared.refresh(bluetooth: false)
            BatteryService.shared.debugInject(BatteryService.shared.devices + [
                BatteryDevice(id: "L", name: "Левый", symbol: "airpodpro.left", level: 1, charging: false),
                BatteryDevice(id: "R", name: "Правый", symbol: "airpodpro.right", level: 0.87, charging: false),
            ])
            try? await Task.sleep(nanoseconds: 9_000_000_000)
            let s = SystemStatsService.shared
            print("stats: cpu=\(Int(s.cpu * 100))% temp=\(s.temperature.map { String(Int($0)) } ?? "nil") mem=\(Int(s.memoryUsed / 1e9))GB gpu=\(s.gpu.map { String(Int($0 * 100)) } ?? "nil") samples=\(s.cpuHistory.count)")
            print("batteries: \(BatteryService.shared.devices.map { "\($0.name) \(Int($0.level * 100))%" })")
            let notchSize = notchGeometry()
            let shelves: [(String, Bool, Bool, [ShelfWidget])] = [
                ("notch-live.png", false, false, ShelfWidget.defaults),
                ("notch-shelf.png", true, false, ShelfWidget.defaults),
                ("notch-edit.png", true, true, ShelfWidget.defaults),
                ("notch-stats.png", true, false, [.systemStats, .batteries, .nowPlaying]),
                ("notch-small.png", true, false, [.nowPlaying, .calendar, .weather, .systemStats, .batteries]),
                ("notch-edit-small.png", true, true, [.nowPlaying, .calendar, .weather, .systemStats, .batteries]),
            ]
            for (name, expanded, editing, widgets) in shelves {
                let model = NotchModel()
                model.notchSize = notchSize
                model.widgets = widgets
                if name.contains("small") {
                    model.sizes = Dictionary(uniqueKeysWithValues: ShelfWidget.allCases.map { ($0, WidgetSize.small) })
                    model.sizes[.nowPlaying] = .medium
                }
                model.expanded = expanded
                if editing {
                    model.beginEditing()
                    if !name.contains("small") { model.draft = [.nowPlaying, .weather] }
                }
                let view = ZStack(alignment: .top) {
                    LinearGradient(colors: [Color(red: 0.32, green: 0.36, blue: 0.48), Color(red: 0.2, green: 0.22, blue: 0.3)], startPoint: .top, endPoint: .bottom)
                    NotchRootView(model: model, spotify: spotify)
                }
                render(view, size: CGSize(width: 1300, height: 400), name: name, dir: outDir)
            }
            // Square System card, four-ring style.
            let savedStyle = SmallStatsStyle.current
            SmallStatsStyle.current = .quad
            let quadModel = NotchModel()
            quadModel.notchSize = notchSize
            quadModel.widgets = [.systemStats, .weather, .batteries]
            quadModel.sizes = [.systemStats: .small, .weather: .small, .batteries: .small]
            quadModel.expanded = true
            render(ZStack(alignment: .top) {
                LinearGradient(colors: [Color(red: 0.32, green: 0.36, blue: 0.48), Color(red: 0.2, green: 0.22, blue: 0.3)], startPoint: .top, endPoint: .bottom)
                NotchRootView(model: quadModel, spotify: spotify)
            }, size: CGSize(width: 900, height: 300), name: "notch-quad.png", dir: outDir)
            SmallStatsStyle.current = savedStyle

            // Agents: collapsed live activity, toast, shelf cards.
            var session = AgentSession(id: "demo", kind: .claude, project: "Isle")
            session.steps = [
                AgentStep(id: "1", tool: "Read", title: "Read Notes.md", symbol: "doc.text", file: nil, plus: 0, minus: 0, running: false),
                AgentStep(id: "2", tool: "Grep", title: "Search NotchShape", symbol: "magnifyingglass", file: nil, plus: 0, minus: 0, running: false),
                AgentStep(id: "3", tool: "Edit", title: "Edit Hero.swift", symbol: "pencil", file: "Hero.swift", plus: 22, minus: 5, running: true),
            ]
            AgentsService.shared.debugInject([session])
            let agentModel = NotchModel()
            agentModel.notchSize = notchSize
            render(ZStack(alignment: .top) {
                LinearGradient(colors: [Color(red: 0.32, green: 0.36, blue: 0.48), Color(red: 0.2, green: 0.22, blue: 0.3)], startPoint: .top, endPoint: .bottom)
                NotchRootView(model: agentModel, spotify: spotify)
            }, size: CGSize(width: 700, height: 120), name: "notch-agent.png", dir: outDir)
            AgentsService.shared.debugToast(AgentToast(kind: .claude, title: "Claude закончил", subtitle: "Isle · 1 файл(ов)", state: .done))
            render(ZStack(alignment: .top) {
                LinearGradient(colors: [Color(red: 0.32, green: 0.36, blue: 0.48), Color(red: 0.2, green: 0.22, blue: 0.3)], startPoint: .top, endPoint: .bottom)
                NotchRootView(model: agentModel, spotify: spotify)
            }, size: CGSize(width: 700, height: 140), name: "notch-toast.png", dir: outDir)
            AgentsService.shared.debugToast(nil)
            let agentShelf = NotchModel()
            agentShelf.notchSize = notchSize
            agentShelf.widgets = [.agents, .agents]
            agentShelf.widgets = [.agents, .nowPlaying]
            agentShelf.sizes = [.nowPlaying: .small]
            agentShelf.expanded = true
            render(ZStack(alignment: .top) {
                LinearGradient(colors: [Color(red: 0.32, green: 0.36, blue: 0.48), Color(red: 0.2, green: 0.22, blue: 0.3)], startPoint: .top, endPoint: .bottom)
                NotchRootView(model: agentShelf, spotify: spotify)
            }, size: CGSize(width: 900, height: 300), name: "notch-agents-shelf.png", dir: outDir)
            AgentsService.shared.debugInject([])

            let dropModel = NotchModel()
            dropModel.notchSize = notchSize
            dropModel.dropMode = true
            dropModel.dropTargeted = true
            render(ZStack(alignment: .top) {
                LinearGradient(colors: [Color(red: 0.32, green: 0.36, blue: 0.48), Color(red: 0.2, green: 0.22, blue: 0.3)], startPoint: .top, endPoint: .bottom)
                NotchRootView(model: dropModel, spotify: spotify)
            }, size: CGSize(width: 700, height: 200), name: "notch-drop.png", dir: outDir)

            let hudModel = NotchModel()
            hudModel.notchSize = notchSize
            hudModel.hud = HUDInfo(kind: .volume, level: 0.62)
            render(ZStack(alignment: .top) {
                LinearGradient(colors: [Color(red: 0.32, green: 0.36, blue: 0.48), Color(red: 0.2, green: 0.22, blue: 0.3)], startPoint: .top, endPoint: .bottom)
                NotchRootView(model: hudModel, spotify: spotify)
            }, size: CGSize(width: 700, height: 120), name: "notch-hud.png", dir: outDir)
            exit(0)
        }
        app.run()
    }

    private static func notchGeometry() -> CGSize {
        guard let s = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }),
              let l = s.auxiliaryTopLeftArea, let r = s.auxiliaryTopRightArea else {
            return CGSize(width: 185, height: 32)
        }
        return CGSize(width: s.frame.width - l.width - r.width, height: s.safeAreaInsets.top)
    }

    /// Fixed calendar / weather data so shelf renders don't ask for permissions.
    private static func injectShelfSamples() {
        let cal = Calendar.current
        func today(_ h: Int, _ m: Int) -> Date { cal.date(bySettingHour: h, minute: m, second: 0, of: Date()) ?? Date() }
        CalendarService.shared.debugInject([
            CalEvent(id: "1", title: "Созвон по проекту", start: today(10, 30), end: today(23, 0), allDay: false, color: .systemRed),
            CalEvent(id: "2", title: "Собеседование", start: today(13, 0), end: today(23, 30), allDay: false, color: .systemYellow),
            CalEvent(id: "3", title: "Спортзал", start: today(19, 30), end: today(23, 50), allDay: false, color: .systemGreen),
        ])
        WeatherService.shared.debugInject(WeatherData(
            city: "Ереван", temp: 7, code: 1, isDay: true, high: 11, low: 2,
            hours: [
                WeatherHour(id: 0, label: "Сейчас", temp: 7, code: 1, isDay: true),
                WeatherHour(id: 1, label: "11:00", temp: 8, code: 0, isDay: true),
                WeatherHour(id: 2, label: "12:00", temp: 10, code: 2, isDay: true),
                WeatherHour(id: 3, label: "13:00", temp: 11, code: 3, isDay: true),
            ],
            fetched: Date()
        ))
    }

    private static func injectSample(_ spotify: SpotifyController, artPath: String?) {
        var art: ProcessedArtwork?
        if let artPath, let data = FileManager.default.contents(atPath: artPath) {
            let frame = NSScreen.screens.first?.frame.size ?? CGSize(width: 1470, height: 956)
            art = ArtworkProcessor.make(data: data, url: URL(fileURLWithPath: artPath), screenAspect: frame.width / frame.height)
        }
        let lrc = """
        [00:40.00] Under a sky of ultramarine
        [00:44.50] The water holds the moon
        [00:49.00] Drop by drop, it finds its way to you
        [00:54.00] Every light along the shore
        [00:58.00] Falls asleep too soon
        [01:02.00] ♪
        """
        spotify.debugInject(
            track: SpotifyTrack(id: "sample", name: "Moonlit Water", artist: "Clear Sky", album: "Sample", duration: 209, artworkURL: nil),
            playing: true,
            position: 46,
            artwork: art,
            lyrics: Lyrics(lines: LyricsService.parseLRC(lrc), synced: true)
        )
    }

    private static func render<V: View>(_ view: V, size: CGSize, name: String, dir: URL) {
        let content = view
            .frame(width: size.width, height: size.height)
            .environment(\.isSnapshot, true)
        let renderer = ImageRenderer(content: content)
        renderer.scale = 2
        guard let cg = renderer.cgImage else {
            print("render failed: \(name)")
            return
        }
        let url = dir.appendingPathComponent(name)
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(dest, cg, nil)
        CGImageDestinationFinalize(dest)
        print("wrote \(url.path)")
    }
}
