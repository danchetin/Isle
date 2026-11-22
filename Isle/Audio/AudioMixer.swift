import AppKit
import CoreAudio
import SwiftUI

struct MixerApp: Identifiable, Equatable {
    let id: String            // bundle id of the app the audio belongs to
    let name: String
    let icon: NSImage
    var processes: [AudioObjectID]
    var playing: Bool
    var volume: Double        // 0…1

    static func == (a: MixerApp, b: MixerApp) -> Bool {
        a.id == b.id && a.processes == b.processes && a.playing == b.playing && a.volume == b.volume
    }
}

/// Per-app volume. Apps at 100% are left completely alone; below 100% Isle reroutes that
/// app's audio through a ProcessTap at the chosen gain.
@MainActor
final class AudioMixer: ObservableObject {
    static let shared = AudioMixer()

    @Published private(set) var apps: [MixerApp] = []
    @Published private(set) var failed: String?

    private var volumes: [String: Double]
    private var taps: [String: ProcessTap] = [:]
    private var timer: Timer?
    private var users = 0
    private static let key = "mixerVolumes"

    init() {
        volumes = (UserDefaults.standard.dictionary(forKey: Self.key) as? [String: Double]) ?? [:]
    }

    /// Re-apply saved volumes at launch (only apps that are below 100%).
    func start() {
        guard !volumes.isEmpty else { return }
        refresh()
        ensureTimer()
    }

    func activate() {
        users += 1
        refresh()
        ensureTimer()
    }

    func deactivate() {
        users = max(0, users - 1)
        if users == 0, taps.isEmpty {
            timer?.invalidate()
            timer = nil
        }
    }

    private func ensureTimer() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    func setVolume(_ app: MixerApp, _ value: Double) {
        let v = (value * 100).rounded() / 100
        volumes[app.id] = v >= 0.995 ? nil : v
        UserDefaults.standard.set(volumes, forKey: Self.key)
        if let i = apps.firstIndex(where: { $0.id == app.id }) { apps[i].volume = v }
        apply(app.id, processes: app.processes)
        ensureTimer()
    }

    func resetAll() {
        volumes = [:]
        UserDefaults.standard.set(volumes, forKey: Self.key)
        taps = [:]
        refresh()
    }

    // MARK: - Process list

    func refresh() {
        let output = CA.defaultOutputDevice
        // Output device changed (e.g. AirPods connected): rebuild every tap on the new device.
        if taps.values.contains(where: { $0.outputDevice != output }) { taps = [:] }

        var groups: [String: MixerApp] = [:]
        let running = NSWorkspace.shared.runningApplications
        for process in CA.objects(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyProcessObjectList) {
            let pid: pid_t = CA.value(process, kAudioProcessPropertyPID, default: 0)
            guard pid > 0, pid != getpid() else { continue }
            let playing: UInt32 = CA.value(process, kAudioProcessPropertyIsRunningOutput, default: 0)
            let processBundle = CA.string(process, kAudioProcessPropertyBundleID) ?? ""
            guard let owner = Self.owner(pid: pid, bundleID: processBundle, running: running) else { continue }
            var app = groups[owner.id] ?? MixerApp(id: owner.id, name: owner.name, icon: owner.icon, processes: [], playing: false,
                                                   volume: volumes[owner.id] ?? 1)
            app.processes.append(process)
            app.playing = app.playing || playing != 0
            groups[owner.id] = app
        }

        // Shown: apps making sound now, plus apps with a custom volume.
        let visible = groups.values
            .filter { $0.playing || volumes[$0.id] != nil }
            .sorted { ($0.playing ? 0 : 1, $0.name) < ($1.playing ? 0 : 1, $1.name) }
        if visible != apps { apps = Array(visible) }

        for app in groups.values { apply(app.id, processes: app.processes) }
        // Tapped apps that quit.
        for id in taps.keys where groups[id] == nil { taps[id] = nil }

        if users == 0, taps.isEmpty, volumes.isEmpty {
            timer?.invalidate()
            timer = nil
        }
    }

    private func apply(_ id: String, processes: [AudioObjectID]) {
        let volume = volumes[id] ?? 1
        if volume >= 0.995 {
            taps[id] = nil // back to untouched system audio
            return
        }
        if let tap = taps[id] {
            tap.volume = Float(volume)
            return
        }
        guard !processes.isEmpty else { return }
        if let tap = ProcessTap(processes: processes, volume: Float(volume)) {
            taps[id] = tap
            failed = nil
        } else {
            failed = "Нет доступа к звуку приложений: Настройки → Конфиденциальность → Запись звука"
        }
    }

    /// Helper processes (Chrome Helper, WebKit GPU…) are grouped under their app.
    private static func owner(pid: pid_t, bundleID: String, running: [NSRunningApplication]) -> (id: String, name: String, icon: NSImage)? {
        if let app = NSRunningApplication(processIdentifier: pid), app.activationPolicy == .regular,
           let id = app.bundleIdentifier {
            return (id, app.localizedName ?? id, app.icon ?? NSImage())
        }
        if let parent = running
            .filter({ $0.activationPolicy == .regular && $0.bundleIdentifier != nil })
            .filter({ bundleID.hasPrefix($0.bundleIdentifier! + ".") || bundleID == $0.bundleIdentifier! })
            .max(by: { $0.bundleIdentifier!.count < $1.bundleIdentifier!.count }),
           let id = parent.bundleIdentifier {
            return (id, parent.localizedName ?? id, parent.icon ?? NSImage())
        }
        if bundleID.contains("WebKit"), let safari = running.first(where: { $0.bundleIdentifier == "com.apple.Safari" }) {
            return ("com.apple.Safari", safari.localizedName ?? "Safari", safari.icon ?? NSImage())
        }
        return nil
    }
}

// MARK: - Widget

/// A row that is itself the slider: drag anywhere on it.
private struct MixerRow: View {
    let app: MixerApp
    let height: CGFloat
    let onChange: (Double) -> Void
    @State private var drag: Double?

    var body: some View {
        GeometryReader { geo in
            let v = drag ?? app.volume
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: height / 2, style: .continuous).fill(Color.white.opacity(0.08))
                RoundedRectangle(cornerRadius: height / 2, style: .continuous)
                    .fill(Color.white.opacity(0.22))
                    .frame(width: max(height, geo.size.width * v))
                HStack(spacing: 8) {
                    Image(nsImage: app.icon).resizable().frame(width: height * 0.62, height: height * 0.62)
                    Text(app.name)
                        .font(.system(size: height * 0.38, weight: .semibold))
                        .lineLimit(1)
                        .opacity(app.playing ? 1 : 0.5)
                    Spacer()
                    Text("\(Int((v * 100).rounded()))%")
                        .font(.system(size: height * 0.34, weight: .semibold).monospacedDigit())
                        .foregroundStyle(.white.opacity(0.75))
                }
                .padding(.horizontal, height * 0.3)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { g in
                        let f = min(max(0, g.location.x / max(geo.size.width, 1)), 1)
                        drag = f
                        onChange(f)
                    }
                    .onEnded { _ in drag = nil }
            )
        }
        .frame(height: height)
        .foregroundStyle(.white)
    }
}

struct MixerCard: View {
    @ObservedObject var mixer: AudioMixer
    var small = false
    @Environment(\.isSnapshot) private var isSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: small ? 6 : 8) {
            HStack {
                Image(systemName: "speaker.wave.2.fill")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(Color(red: 1, green: 0.6, blue: 0.25))
                Text("Громкость")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.6))
                Spacer()
                Button { mixer.resetAll() } label: {
                    Image(systemName: "arrow.counterclockwise")
                        .font(.system(size: 10, weight: .bold))
                        .frame(width: 22, height: 22)
                        .background(Circle().fill(Color.white.opacity(0.12)))
                }
                .buttonStyle(PressableStyle())
                .help("Все приложения на 100%")
            }
            if let failed = mixer.failed {
                Text(failed)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.orange)
                    .lineLimit(3)
            }
            if mixer.apps.isEmpty {
                Text("Сейчас звук ничего не играет")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.45))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(spacing: 6) {
                    ForEach(mixer.apps.prefix(small ? 3 : 4)) { app in
                        MixerRow(app: app, height: small ? 26 : 28) { mixer.setVolume(app, $0) }
                    }
                }
                Spacer(minLength: 0)
            }
        }
        .foregroundStyle(.white)
        .onAppear { if !isSnapshot { mixer.activate() } }
        .onDisappear { if !isSnapshot { mixer.deactivate() } }
    }
}
