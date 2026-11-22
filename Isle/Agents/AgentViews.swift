import SwiftUI

/// Three dots pulsing in sequence ("working…").
struct ProgressDots: View {
    var color: Color
    var size: CGFloat = 4

    var body: some View {
        TimelineView(.animation) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            HStack(spacing: size * 0.8) {
                ForEach(0..<3, id: \.self) { i in
                    let phase = (sin(t * 5 - Double(i) * 0.9) + 1) / 2
                    Circle()
                        .fill(color.opacity(0.35 + 0.65 * phase))
                        .frame(width: size, height: size)
                        .scaleEffect(0.75 + 0.35 * phase)
                }
            }
        }
    }
}

private struct StateGlyph: View {
    let state: AgentState
    let color: Color

    var body: some View {
        switch state {
        case .working:
            ProgressDots(color: color)
        case .waiting:
            Image(systemName: "exclamationmark.bubble.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.yellow)
                .symbolEffect(.pulse)
        case .done:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.green)
        }
    }
}

/// Collapsed island while an agent works: agent icon left of the camera, state right of it.
struct NotchAgentLiveView: View {
    let session: AgentSession
    let notchHeight: CGFloat

    var body: some View {
        HStack {
            Image(systemName: session.kind.symbol)
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(session.kind.color)
                .symbolEffect(.pulse, isActive: session.state == .working)
                .frame(width: notchHeight - 8)
            Spacer()
            StateGlyph(state: session.state, color: session.kind.color)
                .frame(width: notchHeight - 8)
        }
        .padding(.horizontal, 8)
        .frame(height: notchHeight)
    }
}

/// Island grown downward with a one-line message ("Claude закончил · project").
struct NotchToastView: View {
    let toast: AgentToast
    let notchHeight: CGFloat

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: toast.kind.symbol)
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(toast.kind.color)
                Spacer()
                StateGlyph(state: toast.state, color: toast.kind.color)
            }
            .padding(.horizontal, 12)
            .frame(height: notchHeight)
            VStack(spacing: 1) {
                Text(toast.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                Text(toast.subtitle)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.55))
                    .lineLimit(1)
            }
            .padding(.horizontal, 14)
            .frame(maxWidth: .infinity)
            Spacer(minLength: 0)
        }
    }
}

// MARK: - Shelf widget

private struct StepRow: View {
    let step: AgentStep
    let tint: Color

    var body: some View {
        HStack(spacing: 8) {
            Group {
                if step.failed {
                    Image(systemName: "xmark").foregroundStyle(Color.red)
                } else if step.running {
                    Image(systemName: "play.fill").foregroundStyle(tint)
                } else {
                    Image(systemName: "checkmark").foregroundStyle(tint)
                }
            }
            .font(.system(size: 11, weight: .bold))
            .frame(width: 14)
            Text(step.title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white.opacity(step.running ? 1 : 0.8))
                .lineLimit(1)
        }
    }
}

private struct DiffCard: View {
    let step: AgentStep?
    let state: AgentState
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let step, let file = step.file {
                HStack(spacing: 6) {
                    Image(systemName: "doc.fill").foregroundStyle(tint)
                    Text(file)
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        .foregroundStyle(tint)
                        .lineLimit(1)
                }
                HStack(spacing: 6) {
                    Text("+\(step.plus)").foregroundStyle(Color.green)
                    Text("−\(step.minus)").foregroundStyle(Color(red: 1, green: 0.4, blue: 0.4))
                }
                .font(.system(size: 13, weight: .bold, design: .monospaced))
            } else {
                Image(systemName: "doc")
                    .foregroundStyle(.white.opacity(0.35))
                Text("No edits")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.45))
            }
            Spacer(minLength: 0)
            Text(statusText)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(0.55))
            ProgressBar(state: state, tint: tint)
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.white.opacity(0.07)))
    }

    private var statusText: String {
        switch state {
        case .working: String(localized: "Working…")
        case .waiting: String(localized: "Waiting for you")
        case .done: String(localized: "Done")
        }
    }
}

private struct ProgressBar: View {
    let state: AgentState
    let tint: Color

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.12))
                if state == .working {
                    TimelineView(.animation) { ctx in
                        let t = ctx.date.timeIntervalSinceReferenceDate
                        let x = (sin(t * 2.2) + 1) / 2
                        Capsule()
                            .fill(tint)
                            .frame(width: geo.size.width * 0.4)
                            .offset(x: geo.size.width * 0.6 * x)
                    }
                } else {
                    Capsule().fill(state == .done ? Color.green : Color.yellow)
                }
            }
            .clipShape(Capsule())
        }
        .frame(height: 4)
    }
}

struct AgentsCard: View {
    @ObservedObject var agents: AgentsService

    var body: some View {
        Group {
            if let s = agents.active ?? agents.latest {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 6) {
                            Image(systemName: s.kind.symbol)
                                .font(.system(size: 14, weight: .bold))
                                .foregroundStyle(s.kind.color)
                            Text(s.kind.name)
                                .font(.system(size: 15, weight: .bold))
                            Text(s.project)
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.white.opacity(0.45))
                                .lineLimit(1)
                        }
                        VStack(alignment: .leading, spacing: 5) {
                            ForEach(s.steps.suffix(4)) { StepRow(step: $0, tint: s.kind.color) }
                        }
                        if s.steps.isEmpty {
                            Text(s.state == .done ? String(localized: "Waiting for the next task") : String(localized: "Thinking…"))
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(.white.opacity(0.5))
                        }
                        Spacer(minLength: 0)
                        ClaudeUsageBar(usage: ClaudeUsageService.shared)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    DiffCard(step: s.lastFileStep, state: s.state, tint: s.kind.color)
                        .frame(width: 130)
                }
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "sparkle")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(AgentKind.claude.color.opacity(0.6))
                    Text("No agents running")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.6))
                    Text(HookInstaller.claudeInstalled ? String(localized: "Claude Code connected") : String(localized: "Connect Claude Code from the Isle menu"))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white.opacity(0.4))
                    ClaudeUsageBar(usage: ClaudeUsageService.shared)
                        .padding(.horizontal, 24)
                        .padding(.top, 6)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .foregroundStyle(.white)
    }
}

struct SmallAgentsCard: View {
    @ObservedObject var agents: AgentsService

    var body: some View {
        Group {
            if let s = agents.active ?? agents.latest {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Image(systemName: s.kind.symbol)
                            .font(.system(size: 18, weight: .bold))
                            .foregroundStyle(s.kind.color)
                        Spacer()
                        StateGlyph(state: s.state, color: s.kind.color)
                    }
                    Text(s.project)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.5))
                        .lineLimit(1)
                    Text(s.currentStep?.title ?? (s.state == .done ? String(localized: "Done") : String(localized: "Thinking…")))
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(3)
                    Spacer(minLength: 0)
                    if let f = s.lastFileStep {
                        HStack(spacing: 6) {
                            Text("+\(f.plus)").foregroundStyle(Color.green)
                            Text("−\(f.minus)").foregroundStyle(Color(red: 1, green: 0.4, blue: 0.4))
                        }
                        .font(.system(size: 12, weight: .bold, design: .monospaced))
                    }
                    ClaudeUsageBar(usage: ClaudeUsageService.shared, compact: true)
                }
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(Color.white.opacity(0.07)))
            } else {
                VStack(spacing: 6) {
                    Image(systemName: "sparkle")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(AgentKind.claude.color.opacity(0.6))
                    Text("No agents")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.55))
                    ClaudeUsageBar(usage: ClaudeUsageService.shared, compact: true)
                        .padding(.horizontal, 14)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .foregroundStyle(.white)
    }
}
