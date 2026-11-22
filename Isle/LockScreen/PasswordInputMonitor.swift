import AppKit
import CoreGraphics
import SwiftUI

/// Mirrors "something is being typed into the password field" without seeing what.
///
/// The Isle overlay covers the system password field, so the user gets no feedback while
/// typing. Preferred source: the length of loginwindow's own password field via
/// Accessibility (exact, Delete included). Fallback: the system-wide keyDown *counter*
/// (+ Delete / Return / Esc key state when macOS exposes it). Never which character.
@MainActor
final class PasswordInputMonitor: ObservableObject {
    @Published private(set) var count = 0
    @Published private(set) var submitting = false
    @Published private(set) var shakes = 0

    private var lastCounter: UInt32 = 0
    private var timer: Timer?
    private var submitWork: DispatchWorkItem?

    private enum Key {
        static let delete: CGKeyCode = 51
        static let forwardDelete: CGKeyCode = 117
        static let returnKey: CGKeyCode = 36
        static let enter: CGKeyCode = 76
        static let escape: CGKeyCode = 53
    }

    private var active = false

    /// Delete / Return / Esc can only be told apart from other keys with
    /// Input Monitoring access; without it every keystroke counts as a character.
    static var canSeeSpecialKeys: Bool { CGPreflightListenEventAccess() }

    static func requestSpecialKeyAccess() { _ = CGRequestListenEventAccess() }

    /// `polling`: watch the system keyDown counter (lock screen, where Isle never gets
    /// key events). Without it, feed keys through `keyPressed(_:)` (preview window).
    func start(polling: Bool) {
        stop()
        reset()
        active = true
        guard polling else { return }
        LoginwindowPasswordField.reset()
        lastCounter = CGEventSource.counterForEventType(.combinedSessionState, eventType: .keyDown)
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
    }

    /// Exact path: Isle received the key event itself.
    func keyPressed(_ keyCode: UInt16) {
        guard active else { return }
        classify(CGKeyCode(keyCode))
    }

    func stop() {
        active = false
        timer?.invalidate()
        timer = nil
        submitWork?.cancel()
        submitWork = nil
    }

    func reset() {
        count = 0
        submitting = false
    }

    func debugSet(count: Int) { self.count = count }

    /// "ax" or "counter": which source drove the dots (for the lock log).
    private(set) var source = "counter"

    private func poll() {
        let counter = CGEventSource.counterForEventType(.combinedSessionState, eventType: .keyDown)

        // Exact: mirror the system field's length.
        if let n = LoginwindowPasswordField.characterCount() {
            source = "ax"
            lastCounter = counter
            guard n != count else { return }
            let cleared = count > 0 && n == 0
            withAnimation(.easeOut(duration: 0.1)) { count = n }
            if cleared { shakeIfStillLocked() }
            return
        }

        source = "counter"
        guard counter != lastCounter else { return }
        let presses = Int(counter &- lastCounter)
        lastCounter = counter
        let special = heldSpecialKey()
        for _ in 0..<min(presses, 8) { classify(special) }
    }

    /// Which of Delete / Return / Esc is held right now (needs Input Monitoring; else nil).
    private func heldSpecialKey() -> CGKeyCode? {
        for key in [Key.returnKey, Key.enter, Key.escape, Key.delete, Key.forwardDelete]
            where CGEventSource.keyState(.combinedSessionState, key: key) {
            return key
        }
        return nil
    }

    private func classify(_ key: CGKeyCode?) {
        switch key {
        case Key.returnKey, Key.enter:
            submit()
        case Key.escape:
            withAnimation(.easeOut(duration: 0.15)) { reset() }
        case Key.delete, Key.forwardDelete:
            withAnimation(.easeOut(duration: 0.1)) { count = max(0, count - 1) }
        default:
            guard !submitting else { return }
            withAnimation(.easeOut(duration: 0.1)) { count += 1 }
        }
    }

    /// Field emptied (Return with a wrong password, or Esc). Still locked a moment later → shake.
    private func shakeIfStillLocked() {
        submitWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.active, self.count == 0 else { return }
                withAnimation(.spring(response: 0.3, dampingFraction: 0.5)) { self.shakes += 1 }
            }
        }
        submitWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2, execute: work)
    }

    /// Return pressed. If we are still on screen two seconds later the password was wrong:
    /// shake and clear, like the system field.
    private func submit() {
        guard count > 0, !submitting else { return }
        submitting = true
        submitWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.active else { return }
                withAnimation(.spring(response: 0.3, dampingFraction: 0.5)) {
                    self.shakes += 1
                    self.submitting = false
                    self.count = 0
                }
            }
        }
        submitWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: work)
    }
}

/// Glass pill with one dot per keystroke; idle hint when nothing typed yet.
struct PasswordIndicator: View {
    @ObservedObject var input: PasswordInputMonitor

    var body: some View {
        ZStack {
            if input.count > 0 || input.submitting {
                HStack(spacing: 7) {
                    if input.submitting {
                        ProgressView()
                            .controlSize(.small)
                            .tint(.white)
                    } else {
                        ForEach(0..<min(input.count, 22), id: \.self) { _ in
                            Circle()
                                .fill(Color.white)
                                .frame(width: 8, height: 8)
                                .transition(.scale(scale: 0.3).combined(with: .opacity))
                        }
                    }
                }
                .padding(.horizontal, 18)
                .frame(minWidth: 190, minHeight: 40)
                .isleGlass(Capsule())
                .transition(.opacity.combined(with: .scale(scale: 0.9)))
            } else {
                Text("Touch ID or Enter Password")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white.opacity(0.6))
                    .frame(minHeight: 40)
                    .transition(.opacity)
            }
        }
        .modifier(ShakeEffect(animatableData: CGFloat(input.shakes)))
        .animation(.easeOut(duration: 0.15), value: input.count > 0 || input.submitting)
        .allowsHitTesting(false)
    }
}

struct ShakeEffect: GeometryEffect {
    var animatableData: CGFloat
    func effectValue(size: CGSize) -> ProjectionTransform {
        ProjectionTransform(CGAffineTransform(translationX: 10 * sin(animatableData * .pi * 6), y: 0))
    }
}
