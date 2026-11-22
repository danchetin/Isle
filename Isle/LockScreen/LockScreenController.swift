import AppKit
import Combine
import SwiftUI

/// Shows the Now Playing lock screen while the Mac is locked and Spotify has a track.
@MainActor
final class LockScreenController {
    private let spotify: SpotifyController
    /// What is on screen right now (lock or preview).
    private var panel: OverlayPanel?
    /// Built ahead of time and parked in the SkyLight space, so locking only has to order it in.
    private var lockPanel: OverlayPanel?
    private var isPreview = false
    private var isLocked = false
    private var dismissedThisLock = false
    private var observers: [NSObjectProtocol] = []
    private var cancellables = Set<AnyCancellable>()
    private var keyMonitor: Any?
    private let passwordInput = PasswordInputMonitor()
    private var sessionTimer: Timer?

    private func pollSession() {
        let info = CGSessionCopyCurrentDictionary() as? [String: Any]
        let locked = (info?["CGSSessionScreenIsLocked"] as? Bool) ?? ((info?["CGSSessionScreenIsLocked"] as? Int) == 1)
        if locked, !isLocked { didLock() }
        if !locked, isLocked { didUnlock() }
    }

    init(spotify: SpotifyController) {
        self.spotify = spotify
    }

    func start() {
        let dnc = DistributedNotificationCenter.default()
        observers.append(dnc.addObserver(forName: .init("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.didLock() }
        })
        observers.append(dnc.addObserver(forName: .init("com.apple.screenIsUnlocked"), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.didUnlock() }
        })
        // The system clears the password field when the display sleeps; mirror that.
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.passwordInput.reset() }
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.prepareLockPanel() }
        })
        prepareLockPanel()

        // Second lock signal: the session dictionary may flip before the notification lands.
        sessionTimer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.pollSession() }
        }

        // Music started or stopped while locked.
        spotify.$track
            .map { $0 != nil }
            .removeDuplicates()
            .sink { [weak self] hasTrack in
                guard let self, self.isLocked else { return }
                if hasTrack { self.showOnLockScreen() } else { self.hide() }
            }
            .store(in: &cancellables)
    }

    // MARK: - Lock / unlock

    private func didLock() {
        guard !isLocked else { return }
        isLocked = true
        dismissedThisLock = false
        closePreview()
        spotify.refresh()
        showOnLockScreen()
    }

    private func didUnlock() {
        guard isLocked else { return }
        isLocked = false
        hide()
    }

    private func prepareLockPanel() {
        guard SkyLight.shared.isAvailable, let screen = NSScreen.screens.first else { return }
        if let existing = lockPanel {
            if existing.frame == screen.frame { return }
            if panel === existing { return } // don't rebuild while it's showing
            existing.orderOut(nil)
        }
        let p = makePanel(screen: screen, keyable: false) { [weak self] in
            self?.dismissedThisLock = true
            self?.hide()
        }
        p.level = NSWindow.Level(rawValue: Int(Int32.max - 2))
        SkyLight.shared.moveAboveLockScreen(p)
        // Keep it on screen but invisible and click-through, so SwiftUI has already drawn
        // it when the Mac locks: locking then only flips alpha.
        park(p)
        p.orderFrontRegardless()
        lockPanel = p
    }

    private func park(_ p: OverlayPanel) {
        p.alphaValue = 0
        p.ignoresMouseEvents = true
    }

    private func showOnLockScreen() {
        guard isLocked, !dismissedThisLock, panel == nil,
              Prefs.lockScreenEnabled, spotify.track != nil else { return }
        prepareLockPanel()
        guard let p = lockPanel else { return }
        present(p, pollKeys: true, animated: false)

        // What the password mirror could see; only observable while locked.
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.isLocked else { return }
                IsleLog.write("lock: source=\(self.passwordInput.source) \(LoginwindowPasswordField.diagnostics())")
            }
        }
    }

    // MARK: - Preview (same view, normal window, Esc to close)

    func togglePreview() {
        if isPreview { closePreview() } else { openPreview() }
    }

    func openEditor() {
        if isPreview { closePreview() }
        openPreview(editing: true)
    }

    private func openPreview(editing: Bool = false) {
        guard panel == nil, let screen = NSScreen.screens.first else { return }
        let p = makePanel(screen: screen, keyable: true, editing: editing) { [weak self] in
            self?.closePreview()
        }
        p.level = .screenSaver
        isPreview = true
        NSApp.activate(ignoringOtherApps: true)
        present(p, pollKeys: false, animated: true)
        p.makeKey()
        // Typing drives the password dots directly; Esc closes the preview.
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let code = event.keyCode
            MainActor.assumeIsolated {
                if code == 53 { self?.closePreview() } else { self?.passwordInput.keyPressed(code) }
            }
            return nil
        }
    }

    private func closePreview() {
        guard isPreview else { return }
        isPreview = false
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        hide()
    }

    // MARK: - Window

    private func makePanel(screen: NSScreen, keyable: Bool, editing: Bool = false, onClose: @escaping () -> Void) -> OverlayPanel {
        let p = OverlayPanel(
            contentRect: screen.frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        p.allowsKey = keyable
        p.isOpaque = true
        p.backgroundColor = .black
        p.hasShadow = false
        p.isMovable = false
        p.hidesOnDeactivate = false
        p.isReleasedWhenClosed = false
        p.canBecomeVisibleWithoutLogin = true
        p.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]

        let host = FirstMouseHostingView(rootView: LockScreenView(spotify: spotify, input: passwordInput, onClose: onClose,
                                                                  editable: keyable, startEditing: editing))
        host.sizingOptions = []
        p.contentView = host
        p.setFrame(screen.frame, display: false)
        return p
    }

    private func present(_ p: OverlayPanel, pollKeys: Bool, animated: Bool) {
        panel = p
        passwordInput.start(polling: pollKeys)
        p.ignoresMouseEvents = false
        guard animated else {
            p.alphaValue = 1
            p.orderFrontRegardless()
            return
        }
        p.alphaValue = 0
        p.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.25
            p.animator().alphaValue = 1
        }
    }

    private func hide() {
        guard let p = panel else { return }
        panel = nil
        passwordInput.stop()
        passwordInput.reset()
        if p === lockPanel {
            park(p) // stays drawn for the next lock; the system animates the unlock itself
            return
        }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.2
            p.animator().alphaValue = 0
        }, completionHandler: {
            p.orderOut(nil)
        })
    }
}
