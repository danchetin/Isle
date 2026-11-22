import AppKit
import ApplicationServices

/// Reads how many characters are in the system lock-screen password field
/// (loginwindow), through Accessibility. Only the *length* is read — never the value.
/// Needs Accessibility permission; returns nil when unavailable.
@MainActor
enum LoginwindowPasswordField {
    private static var cached: AXUIElement?
    private static var lastSearch = Date.distantPast

    static var trusted: Bool { AXIsProcessTrusted() }

    static func requestTrust() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    static func reset() { cached = nil }

    static func characterCount() -> Int? {
        guard trusted else { return nil }
        if let field = cached, let n = length(of: field) { return n }
        // The field appears a moment after locking; don't walk the tree every frame.
        guard Date().timeIntervalSince(lastSearch) > 0.5 else { return nil }
        lastSearch = Date()
        cached = findField()
        return cached.flatMap(length(of:))
    }

    private static func length(of field: AXUIElement) -> Int? {
        var value: CFTypeRef?
        if AXUIElementCopyAttributeValue(field, kAXNumberOfCharactersAttribute as CFString, &value) == .success,
           let n = value as? Int {
            return n
        }
        // Secure fields usually report bullets as their value; only its length is used.
        if AXUIElementCopyAttributeValue(field, kAXValueAttribute as CFString, &value) == .success,
           let s = value as? String {
            return s.count
        }
        return nil
    }

    private static func loginwindow() -> AXUIElement? {
        guard let pid = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.loginwindow").first?.processIdentifier
        else { return nil }
        return AXUIElementCreateApplication(pid)
    }

    private static func attribute(_ el: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(el, name as CFString, &value) == .success ? value : nil
    }

    private static func findField() -> AXUIElement? {
        guard let app = loginwindow() else { return nil }
        var queue: [AXUIElement] = [app]
        var visited = 0
        while !queue.isEmpty, visited < 600 {
            let el = queue.removeFirst()
            visited += 1
            let subrole = attribute(el, kAXSubroleAttribute) as? String
            if subrole == kAXSecureTextFieldSubrole as String { return el }
            if let children = attribute(el, kAXChildrenAttribute) as? [AXUIElement] {
                queue.append(contentsOf: children)
            }
            if let windows = attribute(el, kAXWindowsAttribute) as? [AXUIElement], el == app {
                queue.append(contentsOf: windows)
            }
        }
        return nil
    }

    /// One-line summary for ~/Library/Logs/Isle/lock.log (roles only, no values).
    static func diagnostics() -> String {
        var parts = ["trusted=\(trusted)"]
        guard trusted, let app = loginwindow() else { return parts.joined(separator: " ") }
        var roles: [String: Int] = [:]
        var queue: [AXUIElement] = [app]
        var visited = 0
        while !queue.isEmpty, visited < 600 {
            let el = queue.removeFirst()
            visited += 1
            let role = (attribute(el, kAXRoleAttribute) as? String) ?? "?"
            let subrole = (attribute(el, kAXSubroleAttribute) as? String).map { "/\($0)" } ?? ""
            roles[role + subrole, default: 0] += 1
            if let children = attribute(el, kAXChildrenAttribute) as? [AXUIElement] { queue.append(contentsOf: children) }
        }
        parts.append("nodes=\(visited)")
        parts.append("field=\(findField() != nil)")
        parts.append("roles=" + roles.sorted { $0.key < $1.key }.map { "\($0.key):\($0.value)" }.joined(separator: ","))
        return parts.joined(separator: " ")
    }
}

/// Tiny append-only log for things only observable while the Mac is locked.
enum IsleLog {
    static func write(_ line: String) {
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Isle")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("lock.log")
        let stamp = ISO8601DateFormatter().string(from: Date())
        let data = Data("\(stamp) \(line)\n".utf8)
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: url)
        }
    }
}
