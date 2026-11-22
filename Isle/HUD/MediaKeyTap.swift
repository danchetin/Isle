import AppKit
import CoreGraphics

enum MediaKey: Int {
    case volumeUp = 0
    case volumeDown = 1
    case brightnessUp = 2
    case brightnessDown = 3
    case mute = 7
}

/// Intercepts the volume / brightness keys (NX_SYSDEFINED events) so Isle can draw its own
/// HUD instead of the system one. Needs Accessibility. The handler returns true to swallow
/// the key; false lets macOS handle it as usual.
@MainActor
final class MediaKeyTap {
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    /// Should Isle take this key (down and up)? false → macOS handles it.
    private let owns: (MediaKey) -> Bool
    /// Key-down action for owned keys; `fine` = Option+Shift quarter step.
    private let action: (MediaKey, Bool) -> Void

    init(owns: @escaping (MediaKey) -> Bool, action: @escaping (MediaKey, Bool) -> Void) {
        self.owns = owns
        self.action = action
    }

    var isRunning: Bool { tap != nil }

    @discardableResult
    func start() -> Bool {
        guard tap == nil else { return true }
        let mask = CGEventMask(1 << 14) // NX_SYSDEFINED
        let me = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, refcon in
                guard let refcon else { return Unmanaged.passUnretained(event) }
                let tap = Unmanaged<MediaKeyTap>.fromOpaque(refcon).takeUnretainedValue()
                return MainActor.assumeIsolated { tap.handle(type: type, event: event) }
            },
            userInfo: me
        ) else { return false }
        self.tap = tap
        source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    func stop() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        tap = nil
        source = nil
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        guard type.rawValue == 14,
              let ns = NSEvent(cgEvent: event),
              ns.subtype.rawValue == 8 else { return Unmanaged.passUnretained(event) }

        let data1 = ns.data1
        let code = (data1 & 0xFFFF_0000) >> 16
        let flags = data1 & 0x0000_FFFF
        let isDown = ((flags & 0xFF00) >> 8) == 0xA
        guard let key = MediaKey(rawValue: code), owns(key) else { return Unmanaged.passUnretained(event) }

        if isDown {
            // Option+Shift = quarter steps, like macOS.
            let fine = ns.modifierFlags.contains(.option) && ns.modifierFlags.contains(.shift)
            action(key, fine)
        }
        return nil // swallow down and up, so the system HUD never appears
    }
}
