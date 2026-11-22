import SwiftUI

enum AgentKind: String {
    case claude
    case codex

    var name: String {
        switch self {
        case .claude: "Claude"
        case .codex: "Codex"
        }
    }

    var symbol: String {
        switch self {
        case .claude: "sparkle"
        case .codex: "chevron.left.forwardslash.chevron.right"
        }
    }

    var color: Color {
        switch self {
        case .claude: Color(red: 0.87, green: 0.49, blue: 0.34)
        case .codex: Color(white: 0.9)
        }
    }
}

struct AgentStep: Identifiable, Equatable {
    let id: String
    let tool: String
    let title: String
    let symbol: String
    let file: String?
    let plus: Int
    let minus: Int
    var running = true
    var failed = false
}

enum AgentState: Equatable {
    case working, waiting, done
}

struct AgentSession: Identifiable, Equatable {
    let id: String
    let kind: AgentKind
    var project: String
    var state: AgentState = .working
    var steps: [AgentStep] = []
    var updated = Date()
    var message: String?

    var currentStep: AgentStep? { steps.last }
    /// Last step that touched a file (for the diff card).
    var lastFileStep: AgentStep? { steps.last { $0.file != nil && ($0.plus > 0 || $0.minus > 0) } }
}

struct AgentToast: Equatable {
    let kind: AgentKind
    let title: String
    let subtitle: String
    let state: AgentState
    let id = UUID()
}

/// Coding-agent activity fed by hook events over the Isle socket. Everything stays local;
/// prompts are never shown or stored — only tool names, file names and line counts.
@MainActor
final class AgentsService: ObservableObject {
    static let shared = AgentsService()

    @Published private(set) var sessions: [AgentSession] = []
    @Published private(set) var toast: AgentToast?
    private var toastWork: DispatchWorkItem?
    private var stepCounter = 0

    /// Session to show in the notch: someone waiting for you first, then whoever is working.
    var active: AgentSession? {
        let fresh = sessions.filter { Date().timeIntervalSince($0.updated) < 10 * 60 }
        return fresh.first { $0.state == .waiting } ?? fresh.first { $0.state == .working }
    }

    /// Most recent session of any state (shelf widget).
    var latest: AgentSession? { sessions.first }

    // MARK: - Events

    func handle(_ data: Data) {
        guard let envelope = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              envelope["type"] as? String == "hook" else { return }
        let source = envelope["source"] as? String ?? ""
        let payload = envelope["payload"] as? [String: Any] ?? [:]
        switch source {
        case "claude": handleClaude(payload)
        case "codex": handleCodex(payload)
        default: break
        }
    }

    private func handleClaude(_ p: [String: Any]) {
        let event = p["hook_event_name"] as? String ?? ""
        let sessionID = p["session_id"] as? String ?? "claude"
        let project = (p["cwd"] as? String).map { URL(fileURLWithPath: $0).lastPathComponent } ?? "Claude"

        if event == "SessionEnd" {
            sessions.removeAll { $0.id == sessionID }
            return
        }

        var s = sessions.first { $0.id == sessionID } ?? AgentSession(id: sessionID, kind: .claude, project: project)
        s.project = project
        s.updated = Date()

        switch event {
        case "UserPromptSubmit":
            s.state = .working
            s.steps = []
            s.message = nil
        case "PreToolUse":
            s.state = .working
            let tool = p["tool_name"] as? String ?? "Tool"
            let input = p["tool_input"] as? [String: Any] ?? [:]
            stepCounter += 1
            let id = p["tool_use_id"] as? String ?? "step-\(stepCounter)"
            let d = Self.describe(tool: tool, input: input)
            s.steps.append(AgentStep(id: id, tool: tool, title: d.title, symbol: d.symbol, file: d.file, plus: d.plus, minus: d.minus))
            if s.steps.count > 30 { s.steps.removeFirst(s.steps.count - 30) }
        case "PostToolUse":
            let tool = p["tool_name"] as? String ?? ""
            let id = p["tool_use_id"] as? String
            let index = id.flatMap { id in s.steps.lastIndex { $0.id == id } }
                ?? s.steps.lastIndex { $0.tool == tool && $0.running }
            if let index {
                s.steps[index].running = false
                if let r = p["tool_response"] as? [String: Any],
                   (r["is_error"] as? Bool) == true || (r["success"] as? Bool) == false {
                    s.steps[index].failed = true
                }
            }
            if s.state == .waiting { s.state = .working }
        case "Notification":
            s.state = .waiting
            let message = p["message"] as? String ?? ""
            s.message = message
            showToast(AgentToast(kind: .claude, title: "Claude ждёт тебя", subtitle: Self.shortReason(message, project: project), state: .waiting))
        case "Stop":
            s.state = .done
            for i in s.steps.indices { s.steps[i].running = false }
            let edits = s.steps.filter { $0.file != nil && ($0.plus > 0 || $0.minus > 0) }
            let summary = edits.isEmpty ? project : "\(project) · \(Set(edits.compactMap(\.file)).count) файл(ов)"
            showToast(AgentToast(kind: .claude, title: "Claude закончил", subtitle: summary, state: .done))
        case "SessionStart":
            s.state = .done
        default:
            break
        }

        sessions.removeAll { $0.id == sessionID }
        sessions.insert(s, at: 0)
        if sessions.count > 8 { sessions.removeLast(sessions.count - 8) }
    }

    /// Codex `notify`: only "agent-turn-complete" with the last message.
    private func handleCodex(_ p: [String: Any]) {
        guard p["type"] as? String == "agent-turn-complete" else { return }
        let id = "codex-" + ((p["thread-id"] as? String) ?? (p["turn-id"] as? String) ?? "session")
        let project = (p["cwd"] as? String).map { URL(fileURLWithPath: $0).lastPathComponent } ?? "Codex"
        var s = sessions.first { $0.id == id } ?? AgentSession(id: id, kind: .codex, project: project)
        s.state = .done
        s.updated = Date()
        sessions.removeAll { $0.id == id }
        sessions.insert(s, at: 0)
        showToast(AgentToast(kind: .codex, title: "Codex закончил", subtitle: project, state: .done))
    }

    private static func shortReason(_ message: String, project: String) -> String {
        let m = message.lowercased()
        if m.contains("permission") { return "\(project) · нужно разрешение" }
        if m.contains("waiting") || m.contains("input") { return "\(project) · ждёт ответа" }
        return project
    }

    // MARK: - Toast

    private func showToast(_ t: AgentToast) {
        withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) { toast = t }
        toastWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                withAnimation(.spring(response: 0.45, dampingFraction: 0.85)) { self?.toast = nil }
            }
        }
        toastWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 4.5, execute: work)
    }

    func dismissToast() {
        toastWork?.cancel()
        withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) { toast = nil }
    }

    // MARK: - Step text

    private static func lines(_ s: String?) -> Int {
        guard let s, !s.isEmpty else { return 0 }
        return s.split(separator: "\n", omittingEmptySubsequences: false).count
    }

    private static func base(_ path: String?) -> String? {
        path.map { URL(fileURLWithPath: $0).lastPathComponent }
    }

    static func describe(tool: String, input: [String: Any]) -> (title: String, symbol: String, file: String?, plus: Int, minus: Int) {
        let file = base(input["file_path"] as? String ?? input["notebook_path"] as? String)
        switch tool {
        case "Edit":
            return ("Edit \(file ?? "file")", "pencil", file,
                    lines(input["new_string"] as? String), lines(input["old_string"] as? String))
        case "MultiEdit":
            let edits = input["edits"] as? [[String: Any]] ?? []
            return ("Edit \(file ?? "file")", "pencil", file,
                    edits.map { lines($0["new_string"] as? String) }.reduce(0, +),
                    edits.map { lines($0["old_string"] as? String) }.reduce(0, +))
        case "Write":
            return ("Write \(file ?? "file")", "doc.badge.plus", file, lines(input["content"] as? String), 0)
        case "NotebookEdit":
            return ("Edit \(file ?? "notebook")", "pencil", file, lines(input["new_source"] as? String), 0)
        case "Read":
            return ("Read \(file ?? "file")", "doc.text", nil, 0, 0)
        case "Bash":
            let text = (input["description"] as? String) ?? (input["command"] as? String) ?? "command"
            return ("Run: \(String(text.prefix(48)))", "terminal", nil, 0, 0)
        case "Grep", "Glob":
            return ("Search \(String(((input["pattern"] as? String) ?? "").prefix(32)))", "magnifyingglass", nil, 0, 0)
        case "WebFetch":
            let host = (input["url"] as? String).flatMap { URL(string: $0)?.host } ?? "page"
            return ("Fetch \(host)", "globe", nil, 0, 0)
        case "WebSearch":
            return ("Search the web", "globe", nil, 0, 0)
        case "Task", "Agent":
            return ("Subagent: \(String(((input["description"] as? String) ?? "task").prefix(36)))", "person.2", nil, 0, 0)
        case "TodoWrite":
            return ("Update plan", "checklist", nil, 0, 0)
        default:
            if tool.hasPrefix("mcp__") {
                let name = tool.split(separator: "_").last.map(String.init) ?? tool
                return ("Tool: \(name)", "puzzlepiece.extension", nil, 0, 0)
            }
            return (tool, "wrench.and.screwdriver", nil, 0, 0)
        }
    }

    // MARK: - Debug

    func debugInject(_ sessions: [AgentSession]) {
        self.sessions = sessions
    }

    func debugToast(_ t: AgentToast?) {
        toast = t
    }
}
