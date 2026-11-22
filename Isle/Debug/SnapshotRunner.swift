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
            // ISLE_SAMPLE=1: demo data only (README screenshots), never the live track.
            let sampleOnly = ProcessInfo.processInfo.environment["ISLE_SAMPLE"] == "1"
            if !sampleOnly { spotify.start() }

            // Wait for track, cover and lyrics (or give up and use sample data).
            let deadline = Date().addingTimeInterval(sampleOnly ? 0 : 12)
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
            // Demo mode: plain lock screen without the user's own widget row.
            let userWidgets = UserDefaults.standard.string(forKey: LockKey.widgets)
            if sampleOnly { injectShelfSamples(); UserDefaults.standard.set("", forKey: LockKey.widgets) }
            render(LockScreenView(spotify: spotify, onClose: {}), size: screen, name: "lock.png", dir: outDir)
            render(LockScreenView(spotify: spotify, onClose: {}, showLyrics: true), size: screen, name: "lock-lyrics.png", dir: outDir)
            if sampleOnly {
                if let userWidgets { UserDefaults.standard.set(userWidgets, forKey: LockKey.widgets) } else { UserDefaults.standard.removeObject(forKey: LockKey.widgets) }
            }
            // Customized lock screen: widgets row, compact player, editor open. Settings restored after.
            let defaults = UserDefaults.standard
            let saved = [LockKey.widgets, LockKey.player, LockKey.clockFont].map { defaults.string(forKey: $0) }
            injectShelfSamples()
            BatteryService.shared.refresh(bluetooth: false)
            defaults.set("weather,calendar,batteries,currency", forKey: LockKey.widgets)
            defaults.set(LockPlayerStyle.compact.rawValue, forKey: LockKey.player)
            defaults.set(LockClockFont.rounded.rawValue, forKey: LockKey.clockFont)
            render(LockScreenView(spotify: spotify, onClose: {}, editable: true), size: screen, name: "lock-custom.png", dir: outDir)
            render(LockScreenView(spotify: spotify, onClose: {}, editable: true, startEditing: true), size: screen, name: "lock-editor.png", dir: outDir)
            let savedColor = defaults.string(forKey: LockKey.clockColor)
            defaults.set(LockClockColor.glass.rawValue, forKey: LockKey.clockColor)
            defaults.set("", forKey: LockKey.widgets)
            defaults.set(LockPlayerStyle.full.rawValue, forKey: LockKey.player)
            render(LockScreenView(spotify: spotify, onClose: {}), size: screen, name: "lock-glass.png", dir: outDir)
            let savedFollow = defaults.object(forKey: GlassSettings.followKey)
            let savedTint = defaults.object(forKey: GlassSettings.customKey)
            defaults.set(false, forKey: GlassSettings.followKey)
            for t in [0.0, 1.0] {
                defaults.set(t, forKey: GlassSettings.customKey)
                render(LockClockOnly(spotify: spotify), size: screen, name: "lock-glass-\(Int(t)).png", dir: outDir)
            }
            if let savedFollow { defaults.set(savedFollow, forKey: GlassSettings.followKey) } else { defaults.removeObject(forKey: GlassSettings.followKey) }
            if let savedTint { defaults.set(savedTint, forKey: GlassSettings.customKey) } else { defaults.removeObject(forKey: GlassSettings.customKey) }
            if let savedColor { defaults.set(savedColor, forKey: LockKey.clockColor) } else { defaults.removeObject(forKey: LockKey.clockColor) }
            for (key, value) in zip([LockKey.widgets, LockKey.player, LockKey.clockFont], saved) {
                if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
            }

            let typing = PasswordInputMonitor()
            typing.debugSet(count: 7)
            render(LockScreenView(spotify: spotify, input: typing, onClose: {}), size: screen, name: "lock-typing.png", dir: outDir)

            injectShelfSamples()
            // Real system stats (no permissions needed): a few samples for the sparklines.
            SystemStatsService.shared.activate()
            BatteryService.shared.refresh(bluetooth: false)
            let realBatteries = sampleOnly
                ? [BatteryDevice(id: "mac", name: "MacBook", symbol: "laptopcomputer", level: 0.82, charging: false)]
                : BatteryService.shared.devices
            BatteryService.shared.debugInject(realBatteries + [
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
            ClaudeUsageService.shared.debugInject(
                current: .init(start: Date().addingTimeInterval(-5600), end: Date().addingTimeInterval(12400), tokens: 27_500_000),
                peak: 109_400_000, today: 136_900_000)
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

            // Pages: second page active, dots in the tab bar.
            let pagedModel = NotchModel()
            pagedModel.notchSize = notchSize
            pagedModel.pages = [[.nowPlaying, .calendar], [.systemStats, .weather, .batteries], [.agents]]
            pagedModel.sizes = [.systemStats: .small, .weather: .small, .batteries: .small]
            pagedModel.page = 1
            pagedModel.expanded = true
            render(ZStack(alignment: .top) {
                LinearGradient(colors: [Color(red: 0.32, green: 0.36, blue: 0.48), Color(red: 0.2, green: 0.22, blue: 0.3)], startPoint: .top, endPoint: .bottom)
                NotchRootView(model: pagedModel, spotify: spotify)
            }, size: CGSize(width: 900, height: 320), name: "notch-pages.png", dir: outDir)
            pagedModel.beginEditing()
            render(ZStack(alignment: .top) {
                LinearGradient(colors: [Color(red: 0.32, green: 0.36, blue: 0.48), Color(red: 0.2, green: 0.22, blue: 0.3)], startPoint: .top, endPoint: .bottom)
                NotchRootView(model: pagedModel, spotify: spotify)
            }, size: CGSize(width: 1100, height: 420), name: "notch-pages-edit.png", dir: outDir)

            // Clipboard: picker + shelf card with sample items (the real clipboard is untouched).
            ClipboardService.shared.debugInject([
                ClipItem(kind: .text, text: "git push -u origin main", image: nil, png: nil, date: Date(), sourceApp: "Терминал"),
                ClipItem(kind: .link, text: "https://github.com/danchetin/isle", image: nil, png: nil, date: Date().addingTimeInterval(-300), sourceApp: "Chrome"),
                ClipItem(kind: .text, text: "Привет! Скинь, пожалуйста, макет к вечеру\nи список правок", image: nil, png: nil, date: Date().addingTimeInterval(-900), sourceApp: "Telegram"),
                ClipItem(kind: .image, text: nil, image: NSImage(systemSymbolName: "photo", accessibilityDescription: nil), png: nil, date: Date().addingTimeInterval(-1800), sourceApp: "Isle"),
            ])
            let pickerModel = ClipboardPickerModel()
            pickerModel.selection = 1
            render(ClipboardPickerView(model: pickerModel, clips: ClipboardService.shared) { _ in },
                   size: CGSize(width: 380, height: 440), name: "clipboard-picker.png", dir: outDir)
            let clipShelf = NotchModel()
            clipShelf.notchSize = notchSize
            clipShelf.pages = [[.clipboard, .nowPlaying]]
            clipShelf.expanded = true
            render(ZStack(alignment: .top) {
                LinearGradient(colors: [Color(red: 0.32, green: 0.36, blue: 0.48), Color(red: 0.2, green: 0.22, blue: 0.3)], startPoint: .top, endPoint: .bottom)
                NotchRootView(model: clipShelf, spotify: spotify)
            }, size: CGSize(width: 900, height: 300), name: "notch-clipboard.png", dir: outDir)

            TrayService.shared.debugInject([
                URL(fileURLWithPath: "/Applications/Safari.app"),
                URL(fileURLWithPath: "/System/Library/CoreServices/Finder.app"),
                URL(fileURLWithPath: "/Library/User Pictures/Animals/Eagle.heic"),
                URL(fileURLWithPath: "/etc/hosts"),
            ])
            let trayShelf = NotchModel()
            trayShelf.notchSize = notchSize
            trayShelf.pages = [[.tray, .clipboard]]
            trayShelf.sizes = [.clipboard: .small]
            trayShelf.expanded = true
            render(ZStack(alignment: .top) {
                LinearGradient(colors: [Color(red: 0.32, green: 0.36, blue: 0.48), Color(red: 0.2, green: 0.22, blue: 0.3)], startPoint: .top, endPoint: .bottom)
                NotchRootView(model: trayShelf, spotify: spotify)
            }, size: CGSize(width: 800, height: 300), name: "notch-tray.png", dir: outDir)

            // Currency: real rates (public API, no personal data).
            CurrencyService.shared.refresh()
            for _ in 0..<40 where CurrencyService.shared.quotes.isEmpty { try? await Task.sleep(nanoseconds: 250_000_000) }
            print("currency: \(CurrencyService.shared.quotes.map { "\($0.code)=\(Int($0.value)) hist=\($0.history.count)" })")
            let rateShelf = NotchModel()
            rateShelf.notchSize = notchSize
            rateShelf.pages = [[.currency, .currency]]
            rateShelf.pages = [[.currency]]
            rateShelf.expanded = true
            render(ZStack(alignment: .top) {
                LinearGradient(colors: [Color(red: 0.32, green: 0.36, blue: 0.48), Color(red: 0.2, green: 0.22, blue: 0.3)], startPoint: .top, endPoint: .bottom)
                NotchRootView(model: rateShelf, spotify: spotify)
            }, size: CGSize(width: 700, height: 300), name: "notch-currency.png", dir: outDir)

            let dropModel = NotchModel()
            dropModel.notchSize = notchSize
            dropModel.dropMode = true
            dropModel.dropKind = .image
            dropModel.dropTargeted = true
            render(ZStack(alignment: .top) {
                LinearGradient(colors: [Color(red: 0.32, green: 0.36, blue: 0.48), Color(red: 0.2, green: 0.22, blue: 0.3)], startPoint: .top, endPoint: .bottom)
                NotchRootView(model: dropModel, spotify: spotify)
            }, size: CGSize(width: 900, height: 200), name: "notch-drop.png", dir: outDir)

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

/// Backdrop + glass clock only (comparing glass tint levels).
private struct LockClockOnly: View {
    @ObservedObject var spotify: SpotifyController
    var body: some View {
        GeometryReader { geo in
            ZStack {
                ArtBackdrop(artwork: spotify.artwork, size: geo.size)
                if let art = spotify.artwork {
                    GlassClock(style: .large, size: geo.size, font: .regular, artwork: art)
                }
            }
        }
    }
}
