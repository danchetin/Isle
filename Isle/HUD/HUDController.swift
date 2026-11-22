import AppKit
import SwiftUI

struct HUDInfo: Equatable {
    enum Kind: Equatable { case volume, brightness }
    var kind: Kind
    var level: Double
    var muted = false

    var symbol: String {
        switch kind {
        case .volume:
            if muted || level <= 0.001 { return "speaker.slash.fill" }
            if level < 0.34 { return "speaker.wave.1.fill" }
            if level < 0.67 { return "speaker.wave.2.fill" }
            return "speaker.wave.3.fill"
        case .brightness:
            return level < 0.5 ? "sun.min.fill" : "sun.max.fill"
        }
    }
}

/// Volume / brightness keys → change the value → show the notch HUD.
@MainActor
final class HUDController {
    private let model: NotchModel
    private var tap: MediaKeyTap?
    private var hideWork: DispatchWorkItem?
    private var trustTimer: Timer?

    private static let step: Float = 1.0 / 16
    private static let fineStep: Float = 1.0 / 64

    init(model: NotchModel) {
        self.model = model
    }

    func start() {
        guard Prefs.hudEnabled else { return }
        if AXIsProcessTrusted() {
            startTap()
        } else {
            IsleLog.write("hud: waiting for Accessibility")
            // Start as soon as Accessibility is granted.
            trustTimer?.invalidate()
            trustTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] timer in
                MainActor.assumeIsolated {
                    guard AXIsProcessTrusted() else { return }
                    timer.invalidate()
                    self?.startTap()
                }
            }
        }
    }

    func stop() {
        trustTimer?.invalidate()
        trustTimer = nil
        tap?.stop()
        tap = nil
    }

    private func startTap() {
        let tap = MediaKeyTap(
            owns: { key in
                switch key {
                case .volumeUp, .volumeDown, .mute: return SystemVolume.isControllable
                case .brightnessUp, .brightnessDown: return SystemBrightness.isAvailable
                }
            },
            action: { [weak self] key, fine in self?.handle(key, fine: fine) }
        )
        if tap.start() {
            self.tap = tap
            IsleLog.write("hud: media key tap running (volume=\(SystemVolume.isControllable), brightness=\(SystemBrightness.isAvailable))")
        } else {
            IsleLog.write("hud: could not create media key tap (accessibility=\(AXIsProcessTrusted()))")
        }
    }

    private func handle(_ key: MediaKey, fine: Bool) {
        let step = fine ? Self.fineStep : Self.step
        switch key {
        case .volumeUp, .volumeDown:
            let delta = key == .volumeUp ? step : -step
            let target = quantize(SystemVolume.volume + delta, step: step)
            if SystemVolume.muted, key == .volumeUp { SystemVolume.muted = false }
            SystemVolume.volume = target
            show(HUDInfo(kind: .volume, level: Double(target), muted: SystemVolume.muted))
        case .mute:
            SystemVolume.muted.toggle()
            show(HUDInfo(kind: .volume, level: Double(SystemVolume.volume), muted: SystemVolume.muted))
        case .brightnessUp, .brightnessDown:
            let delta = key == .brightnessUp ? step : -step
            let target = quantize(SystemBrightness.brightness + delta, step: step)
            SystemBrightness.brightness = target
            show(HUDInfo(kind: .brightness, level: Double(target)))
        }
    }

    /// Snap to the step grid so repeated presses land on even levels.
    private func quantize(_ v: Float, step: Float) -> Float {
        min(max((v / step).rounded() * step, 0), 1)
    }

    private func show(_ info: HUDInfo) {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.82)) { model.hud = info }
        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) { self?.model.hud = nil }
            }
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6, execute: work)
    }
}

/// Collapsed island while a HUD is up: icon left of the camera, level bar right of it.
struct NotchHUDView: View {
    let info: HUDInfo
    let notchHeight: CGFloat

    var body: some View {
        HStack {
            Image(systemName: info.symbol)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 28, alignment: .center)
            Spacer()
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.22))
                    Capsule()
                        .fill(Color.white)
                        .frame(width: max(6, geo.size.width * (info.muted ? 0 : info.level)))
                        .opacity(info.muted ? 0 : 1)
                }
            }
            .frame(width: NotchMetrics.hudSide - 30, height: 6)
            .animation(.spring(response: 0.25, dampingFraction: 0.85), value: info.level)
        }
        .padding(.horizontal, 10)
        .frame(height: notchHeight)
    }
}
