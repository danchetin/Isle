import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let spotify = SpotifyController.shared
    private var statusItem: NSStatusItem!
    private var lock: LockScreenController!
    private var notch: NotchController!
    private var hud: HUDController!

    func applicationDidFinishLaunching(_ notification: Notification) {
        Prefs.register()
        IsleLog.write("startup: accessibility=\(AXIsProcessTrusted())")
        // Password dots and the HUD both need Accessibility: ask once, via the system prompt.
        if !AXIsProcessTrusted(), !UserDefaults.standard.bool(forKey: "askedAccessibility") {
            UserDefaults.standard.set(true, forKey: "askedAccessibility")
            LoginwindowPasswordField.requestTrust()
        }
        spotify.start()
        lock = LockScreenController(spotify: spotify)
        lock.start()
        notch = NotchController(spotify: spotify)
        notch.start()
        hud = HUDController(model: notch.model)
        hud.start()
        setupStatusItem()
    }

    // MARK: - Menu bar

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "capsule.fill", accessibilityDescription: "Isle")
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let title: String
        if let t = spotify.track {
            title = "\(spotify.isPlaying ? "▶︎" : "❙❙")  \(t.name) — \(t.artist)"
        } else {
            title = spotify.isRunning ? "Spotify: ничего не играет" : "Spotify не запущен"
        }
        let header = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(.separator())

        menu.addItem(item("Превью lock screen", #selector(previewLock), key: "l"))
        menu.addItem(.separator())
        menu.addItem(toggle("Lock screen при блокировке", Prefs.lockScreenEnabled, #selector(toggleLock)))
        menu.addItem(toggle("Clock Depth (объект поверх часов)", Prefs.clockDepth, #selector(toggleDepth)))
        menu.addItem(toggle("Большие часы", Prefs.clockStyle == .large, #selector(toggleClockStyle)))
        menu.addItem(toggle("Плеер в вырезе", Prefs.notchEnabled, #selector(toggleNotch)))
        menu.addItem(toggle("HUD громкости и яркости", Prefs.hudEnabled, #selector(toggleHUD)))

        if !LoginwindowPasswordField.trusted {
            menu.addItem(.separator())
            menu.addItem(item("Разрешить Универсальный доступ (пароль, HUD)…", #selector(requestAccessibility)))
        }

        if spotify.permissionDenied {
            menu.addItem(.separator())
            menu.addItem(item("Разрешить доступ к Spotify…", #selector(openAutomationSettings)))
        }

        menu.addItem(.separator())
        menu.addItem(item("Выйти из Isle", #selector(quit), key: "q"))
    }

    private func item(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
        i.target = self
        return i
    }

    private func toggle(_ title: String, _ on: Bool, _ action: Selector) -> NSMenuItem {
        let i = item(title, action)
        i.state = on ? .on : .off
        return i
    }

    @objc private func previewLock() { lock.togglePreview() }
    @objc private func toggleLock() { Prefs.lockScreenEnabled.toggle() }
    @objc private func toggleDepth() { Prefs.clockDepth.toggle() }
    @objc private func toggleClockStyle() { Prefs.clockStyle = Prefs.clockStyle == .large ? .inline : .large }

    @objc private func toggleNotch() {
        Prefs.notchEnabled.toggle()
        notch.setEnabled(Prefs.notchEnabled)
    }

    @objc private func openAutomationSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func toggleHUD() {
        Prefs.hudEnabled.toggle()
        if Prefs.hudEnabled { hud.start() } else { hud.stop() }
    }

    @objc private func requestAccessibility() {
        LoginwindowPasswordField.requestTrust()
    }

    @objc private func quit() { NSApp.terminate(nil) }
}
