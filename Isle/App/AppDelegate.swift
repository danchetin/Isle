import AppKit
import Carbon.HIToolbox

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let spotify = SpotifyController.shared
    private var statusItem: NSStatusItem!
    private var lock: LockScreenController!
    private var notch: NotchController!
    private var hud: HUDController!
    private var socketServer: IsleSocketServer?
    private var clipboardHotKey: GlobalHotKey?
    private var converterHotKey: GlobalHotKey?

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

        // Local socket: coding-agent hook events (and later MCP requests).
        HookInstaller.writeShim()
        let server = IsleSocketServer { request, reply in
            let type = (try? JSONSerialization.jsonObject(with: request) as? [String: Any])?["type"] as? String
            switch type {
            case "status":
                let agents = AgentsService.shared
                let status: [String: Any] = [
                    "sessions": agents.sessions.count,
                    "active": agents.active?.currentStep?.title ?? "",
                    "state": agents.active.map { "\($0.state)" } ?? "none",
                ]
                reply(try? JSONSerialization.data(withJSONObject: status))
            case "mcp_tools":
                reply(try? JSONSerialization.data(withJSONObject: McpHandler.enabledTools()))
            case "mcp_call":
                let obj = (try? JSONSerialization.jsonObject(with: request) as? [String: Any]) ?? [:]
                McpHandler.call(obj["tool"] as? String ?? "", args: obj["args"] as? [String: Any] ?? [:]) { result in
                    reply(try? JSONSerialization.data(withJSONObject: result))
                }
            default:
                AgentsService.shared.handle(request)
                reply(nil)
            }
        }
        server.start()
        socketServer = server

        // Clipboard history + ⌥⇧V picker.
        ClipboardService.shared.start()
        clipboardHotKey = GlobalHotKey(keyCode: UInt32(kVK_ANSI_V), modifiers: UInt32(optionKey | shiftKey), id: 1) {
            MainActor.assumeIsolated { ClipboardPicker.shared.toggle() }
        }

        converterHotKey = GlobalHotKey(keyCode: UInt32(kVK_ANSI_C), modifiers: UInt32(optionKey | shiftKey), id: 2) {
            MainActor.assumeIsolated { CurrencyConverterPanel.shared.toggle() }
        }

        // Per-app volumes saved last time (only apps below 100% are touched).
        AudioMixer.shared.start()
        if CommandLine.arguments.contains("--mixer-selftest") { runMixerSelfTest() }
        if CommandLine.arguments.contains("--plan-selftest") { ClaudeUsageService.shared.refreshPlan(force: true) }
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
        menu.addItem(item("Настроить lock screen…", #selector(editLock)))
        menu.addItem(item("Удалить приложение…", #selector(openCleaner)))
        let clip = item("История буфера", #selector(openClipboard), key: "v")
        clip.keyEquivalentModifierMask = [.option, .shift]
        menu.addItem(clip)
        let conv = item("Конвертер валют", #selector(openConverter), key: "c")
        conv.keyEquivalentModifierMask = [.option, .shift]
        menu.addItem(conv)
        menu.addItem(.separator())
        menu.addItem(toggle("Lock screen при блокировке", Prefs.lockScreenEnabled, #selector(toggleLock)))
        menu.addItem(toggle("Clock Depth (объект поверх часов)", Prefs.clockDepth, #selector(toggleDepth)))
        menu.addItem(toggle("Большие часы", Prefs.clockStyle == .large, #selector(toggleClockStyle)))
        menu.addItem(toggle("Плеер в вырезе", Prefs.notchEnabled, #selector(toggleNotch)))
        menu.addItem(toggle("HUD громкости и яркости", Prefs.hudEnabled, #selector(toggleHUD)))
        menu.addItem(toggle("Агенты: Claude Code подключён", HookInstaller.claudeInstalled, #selector(toggleClaudeHooks)))
        let mcpItem = NSMenuItem(title: "MCP-инструменты", action: nil, keyEquivalent: "")
        let mcpMenu = NSMenu()
        for tool in McpTool.allCases {
            let i = NSMenuItem(title: tool.title, action: #selector(toggleMcpTool(_:)), keyEquivalent: "")
            i.target = self
            i.representedObject = tool.rawValue
            i.state = tool.isEnabled ? .on : .off
            mcpMenu.addItem(i)
        }
        mcpMenu.addItem(.separator())
        mcpMenu.addItem(item("Скопировать команду подключения для Claude Code", #selector(copyClaudeMcpCommand)))
        mcpMenu.addItem(item("Скопировать конфиг для Codex", #selector(copyCodexMcpConfig)))
        mcpItem.submenu = mcpMenu
        menu.addItem(mcpItem)

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
    @objc private func editLock() { lock.openEditor() }
    @objc private func openCleaner() { CleanerWindows.chooseApp() }
    @objc private func openClipboard() { ClipboardPicker.shared.toggle() }
    @objc private func openConverter() { CurrencyConverterPanel.shared.toggle() }
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

    @objc private func toggleMcpTool(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let tool = McpTool(rawValue: raw) else { return }
        tool.isEnabled.toggle()
    }

    @objc private func copyClaudeMcpCommand() {
        copy("claude mcp add --scope user isle -- \"\(HookInstaller.mcpShimURL.path)\"")
    }

    @objc private func copyCodexMcpConfig() {
        copy("[mcp_servers.isle]\ncommand = \"\(HookInstaller.mcpShimURL.path)\"\n")
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    @objc private func toggleClaudeHooks() {
        do {
            if HookInstaller.claudeInstalled { try HookInstaller.uninstallClaude() } else { try HookInstaller.installClaude() }
        } catch {
            IsleLog.write("hooks: \(error.localizedDescription)")
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

    /// `open Isle.app --args --mixer-selftest`: tap the first app that is playing at 50%
    /// for 4 s, log the result, restore. Runs inside the app so TCC attributes it to Isle.
    private func runMixerSelfTest() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            MainActor.assumeIsolated {
                let mixer = AudioMixer.shared
                mixer.activate()
                guard let app = mixer.apps.first(where: \.playing) else {
                    IsleLog.write("mixer selftest: nothing playing; apps=\(mixer.apps.map(\.name))")
                    return
                }
                mixer.setVolume(app, 0.5)
                IsleLog.write("mixer selftest: \(app.name) at 50%, processes=\(app.processes.count), failed=\(mixer.failed ?? "no")")
                DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
                    MainActor.assumeIsolated {
                        mixer.setVolume(app, 1)
                        mixer.deactivate()
                        IsleLog.write("mixer selftest: restored \(app.name) to 100%")
                    }
                }
            }
        }
    }
}
