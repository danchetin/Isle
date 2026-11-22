import AppKit
import SwiftUI

func formatTime(_ t: TimeInterval) -> String {
    guard t.isFinite, t >= 0 else { return "0:00" }
    let s = Int(t.rounded(.down))
    return String(format: "%d:%02d", s / 60, s % 60)
}

// MARK: - Snapshot mode (ImageRenderer can't draw Liquid Glass)

private struct SnapshotModeKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var isSnapshot: Bool {
        get { self[SnapshotModeKey.self] }
        set { self[SnapshotModeKey.self] = newValue }
    }
}

// MARK: - Glass

/// How frosted Isle's glass is: 0 = clear, 1 = fully tinted. Follows the macOS
/// Appearance → Liquid Glass slider (NSGlassTintAmount) and Reduce Transparency unless
/// the user picks their own value.
enum GlassSettings {
    static let followKey = "glassFollowSystem"
    static let customKey = "glassTint"

    static var systemTint: Double {
        let raw = UserDefaults.standard.object(forKey: "NSGlassTintAmount")
        if let n = raw as? NSNumber { return n.doubleValue }
        if let s = raw as? String, let d = Double(s) { return d }
        return 0.5
    }

    static var reduceTransparency: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
    }

    static func tint(follow: Bool, custom: Double) -> Double {
        if reduceTransparency { return 1 }
        return min(max(follow ? systemTint : custom, 0), 1)
    }
}

struct GlassModifier<S: Shape>: ViewModifier {
    let shape: S
    @Environment(\.isSnapshot) private var isSnapshot
    @AppStorage(GlassSettings.followKey) private var follow = true
    @AppStorage(GlassSettings.customKey) private var custom = 0.5

    func body(content: Content) -> some View {
        if isSnapshot {
            fallback(content)
        } else if #available(macOS 26.0, *) {
            content.glassEffect(glass, in: shape)
        } else {
            fallback(content)
        }
    }

    @available(macOS 26.0, *)
    private var glass: Glass {
        // Following the system: plain glass, macOS applies its own slider.
        guard !follow || GlassSettings.reduceTransparency else { return .regular.interactive() }
        let t = GlassSettings.tint(follow: follow, custom: custom)
        if t < 0.3 { return .clear.interactive() }
        return .regular.tint(Color.black.opacity((t - 0.3) * 0.45)).interactive()
    }

    private func fallback(_ content: Content) -> some View {
        let t = GlassSettings.tint(follow: follow, custom: custom)
        return content
            .background(shape.fill(Color.white.opacity(0.08 + 0.16 * t)))
            .overlay(shape.stroke(Color.white.opacity(0.22), lineWidth: 0.5))
    }
}

extension View {
    func isleGlass<S: Shape>(_ shape: S) -> some View {
        modifier(GlassModifier(shape: shape))
    }
}

// MARK: - Buttons

struct PressableStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.84 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.6), value: configuration.isPressed)
    }
}

struct IconButton: View {
    let systemName: String
    var size: CGFloat = 20
    var weight: Font.Weight = .semibold
    var opacity: Double = 1
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: size, weight: weight))
                .contentTransition(.symbolEffect(.replace))
                .opacity(opacity)
                .frame(minWidth: size + 14, minHeight: size + 14)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle())
    }
}

// MARK: - Scrub bar (progress / volume)

struct ScrubBar: View {
    var progress: Double
    var height: CGFloat = 6
    var trackOpacity: Double = 0.22
    var fillOpacity: Double = 0.92
    /// Call `onChange` while dragging (volume) instead of only on release (seek).
    var live = false
    let onChange: (Double) -> Void

    @State private var dragValue: Double?
    @State private var hovering = false

    var body: some View {
        GeometryReader { geo in
            let p = min(max(dragValue ?? progress, 0), 1)
            let h = (hovering || dragValue != nil) ? height * 1.5 : height
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(trackOpacity))
                Rectangle().fill(Color.white.opacity(fillOpacity))
                    .frame(width: geo.size.width * p)
            }
            .frame(height: h)
            .clipShape(Capsule())
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { v in
                        let f = min(max(0, v.location.x / max(geo.size.width, 1)), 1)
                        dragValue = f
                        if live { onChange(f) }
                    }
                    .onEnded { v in
                        let f = min(max(0, v.location.x / max(geo.size.width, 1)), 1)
                        onChange(f)
                        dragValue = nil
                    }
            )
            .onHover { hovering = $0 }
            .animation(.spring(response: 0.3, dampingFraction: 0.8), value: h)
        }
        .frame(height: height * 2.6)
    }
}

// MARK: - Waveform (decorative, follows play state)

struct Waveform: View {
    var color: Color
    var playing: Bool
    var bars = 5
    var barWidth: CGFloat = 3

    /// Per-bar frequencies (rad/s): incommensurate so the pattern never visibly repeats.
    private static let freqs: [(Double, Double, Double)] = [
        (5.1, 7.9, 3.3), (6.7, 4.3, 9.1), (4.6, 8.8, 5.7), (7.3, 5.2, 3.9), (5.8, 9.4, 4.4),
    ]

    var body: some View {
        TimelineView(.animation(paused: !playing)) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            GeometryReader { geo in
                HStack(alignment: .center, spacing: barWidth * 0.75) {
                    ForEach(0..<bars, id: \.self) { i in
                        Capsule()
                            .fill(LinearGradient(colors: [color, color.opacity(0.75)], startPoint: .top, endPoint: .bottom))
                            .frame(width: barWidth, height: max(barWidth, geo.size.height * level(i, t)))
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .animation(.easeInOut(duration: 0.35), value: playing)
    }

    /// Smooth 0…1 level: sum of three sines, middle bars taller, flat dots when paused.
    private func level(_ i: Int, _ t: Double) -> CGFloat {
        guard playing else { return 0 }
        let f = Self.freqs[i % Self.freqs.count]
        let p = Double(i) * 1.3
        let wave = (sin(t * f.0 + p) + 0.6 * sin(t * f.1 + p * 2.1) + 0.35 * sin(t * f.2 + p * 0.7)) / 1.95 // -1…1
        let center = Double(bars - 1) / 2
        let envelope = 1 - 0.35 * abs(Double(i) - center) / max(center, 1)
        return CGFloat((0.32 + 0.68 * (wave * 0.5 + 0.5)) * envelope)
    }
}

// MARK: - Artwork thumbnail

struct ArtThumb: View {
    let artwork: ProcessedArtwork?
    let size: CGFloat
    let radius: CGFloat

    var body: some View {
        Group {
            if let artwork {
                Image(nsImage: artwork.image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fill)
            } else {
                ZStack {
                    Color.white.opacity(0.1)
                    Image(systemName: "music.note")
                        .font(.system(size: size * 0.4, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.5))
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
    }
}

// MARK: - Lyrics

/// A window of lines around the current one; lines slide up as the song moves on.
struct LyricsStack: View {
    let lyrics: Lyrics?
    let state: LyricsState
    let position: TimeInterval
    var fontSize: CGFloat
    var before: Int
    var after: Int
    var center = false
    var spacing: CGFloat = 16

    var body: some View {
        Group {
            if let lyrics, lyrics.synced, !lyrics.lines.isEmpty {
                let current = lyrics.index(at: position) ?? -1
                let lo = max(0, current - before)
                let hi = min(lyrics.lines.count - 1, max(current, 0) + after)
                VStack(alignment: center ? .center : .leading, spacing: spacing) {
                    ForEach(lyrics.lines[lo...hi]) { line in
                        let isCurrent = line.id == current
                        Text(line.text)
                            .font(.system(size: fontSize, weight: .bold))
                            .multilineTextAlignment(center ? .center : .leading)
                            .foregroundStyle(Color.white.opacity(isCurrent ? 1 : (line.id < current ? 0.4 : 0.55)))
                            .scaleEffect(isCurrent ? 1 : 0.96, anchor: center ? .center : .leading)
                            .fixedSize(horizontal: false, vertical: true)
                            .transition(.asymmetric(
                                insertion: .move(edge: .bottom).combined(with: .opacity),
                                removal: .move(edge: .top).combined(with: .opacity)
                            ))
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: center ? .top : .topLeading)
                .animation(.spring(response: 0.55, dampingFraction: 0.86), value: current)
            } else if let lyrics, !lyrics.lines.isEmpty {
                Text(lyrics.lines.prefix(14).map(\.text).joined(separator: "\n"))
                    .font(.system(size: fontSize * 0.7, weight: .semibold))
                    .multilineTextAlignment(center ? .center : .leading)
                    .foregroundStyle(Color.white.opacity(0.8))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: center ? .top : .topLeading)
            } else {
                Text(state == .loading ? "Загружаю текст…" : "Текст не найден")
                    .font(.system(size: fontSize * 0.7, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.45))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: center ? .center : .leading)
            }
        }
    }
}

// MARK: - Hosting

/// Lets the first click on a non-key overlay hit the SwiftUI control under it.
final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Borderless overlay panel; can become key only when asked (preview needs Esc,
/// the lock-screen copy must never steal keyboard focus from the password field).
final class OverlayPanel: NSPanel {
    var allowsKey = false
    override var canBecomeKey: Bool { allowsKey }
    override var canBecomeMain: Bool { false }
}
