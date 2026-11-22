import Foundation

/// Connects Claude Code to Isle by adding hook commands to ~/.claude/settings.json.
/// Hooks call a tiny shim script (stable path) that execs the current Isle binary
/// with `--hook claude`. Other hooks in the file are left alone; a backup is written first.
enum HookInstaller {
    static var shimURL: URL { IsleSocket.directory.appendingPathComponent("isle-hook") }
    static var mcpShimURL: URL { IsleSocket.directory.appendingPathComponent("isle-mcp") }

    private static var claudeSettingsURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/settings.json")
    }

    private static let toolEvents = ["PreToolUse", "PostToolUse"]
    private static let otherEvents = ["UserPromptSubmit", "Stop", "Notification", "SessionStart", "SessionEnd"]

    private static var command: String { "\"\(shimURL.path)\" claude" }

    /// (Re)write the shim so it always points at the running build. Called on launch.
    static func writeShim() {
        guard let exe = Bundle.main.executablePath else { return }
        try? FileManager.default.createDirectory(at: IsleSocket.directory, withIntermediateDirectories: true)
        for (url, flag) in [(shimURL, "--hook"), (mcpShimURL, "--mcp")] {
            let script = "#!/bin/sh\nexec \"\(exe)\" \(flag) \"$@\"\n"
            if (try? String(contentsOf: url, encoding: .utf8)) == script { continue }
            try? script.write(to: url, atomically: true, encoding: .utf8)
            chmod(url.path, 0o755)
        }
    }

    private static func loadSettings() -> [String: Any] {
        guard let data = try? Data(contentsOf: claudeSettingsURL),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return obj
    }

    private static func isOurs(_ entry: [String: Any]) -> Bool {
        let hooks = entry["hooks"] as? [[String: Any]] ?? []
        return hooks.contains { ($0["command"] as? String)?.contains("isle-hook") == true }
    }

    static var claudeInstalled: Bool {
        let hooks = loadSettings()["hooks"] as? [String: Any] ?? [:]
        return (toolEvents + otherEvents).allSatisfy { event in
            (hooks[event] as? [[String: Any]] ?? []).contains(where: isOurs)
        }
    }

    static func installClaude() throws {
        try update { hooks in
            for event in toolEvents + otherEvents {
                var entries = (hooks[event] as? [[String: Any]] ?? []).filter { !isOurs($0) }
                var entry: [String: Any] = ["hooks": [["type": "command", "command": command, "timeout": 5]]]
                if toolEvents.contains(event) { entry["matcher"] = "*" }
                entries.append(entry)
                hooks[event] = entries
            }
        }
    }

    static func uninstallClaude() throws {
        try update { hooks in
            for event in toolEvents + otherEvents {
                let kept = (hooks[event] as? [[String: Any]] ?? []).filter { !isOurs($0) }
                hooks[event] = kept.isEmpty ? nil : kept
            }
        }
    }

    private static func update(_ change: (inout [String: Any]) -> Void) throws {
        writeShim()
        var settings = loadSettings()
        if FileManager.default.fileExists(atPath: claudeSettingsURL.path) {
            let backup = claudeSettingsURL.deletingLastPathComponent().appendingPathComponent("settings.json.isle-backup")
            try? FileManager.default.removeItem(at: backup)
            try FileManager.default.copyItem(at: claudeSettingsURL, to: backup)
        }
        var hooks = settings["hooks"] as? [String: Any] ?? [:]
        change(&hooks)
        settings["hooks"] = hooks.isEmpty ? nil : hooks
        let data = try JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try data.write(to: claudeSettingsURL, options: .atomic)
    }
}
