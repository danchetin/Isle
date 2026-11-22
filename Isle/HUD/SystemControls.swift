import AppKit
import AudioToolbox
import CoreAudio
import CoreGraphics

/// Default output device volume / mute through CoreAudio.
enum SystemVolume {
    private static func defaultDevice() -> AudioObjectID? {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var id = AudioObjectID(0)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &id)
        return status == noErr && id != 0 ? id : nil
    }

    private static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
    }

    /// Whether Isle can drive this device (HDMI / some USB devices can't be set).
    static var isControllable: Bool {
        guard let id = defaultDevice() else { return false }
        var addr = address(kAudioHardwareServiceDeviceProperty_VirtualMainVolume)
        var settable: DarwinBoolean = false
        return AudioObjectHasProperty(id, &addr)
            && AudioObjectIsPropertySettable(id, &addr, &settable) == noErr
            && settable.boolValue
    }

    static var volume: Float {
        get {
            guard let id = defaultDevice() else { return 0 }
            var addr = address(kAudioHardwareServiceDeviceProperty_VirtualMainVolume)
            var value: Float32 = 0
            var size = UInt32(MemoryLayout<Float32>.size)
            return AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &value) == noErr ? value : 0
        }
        set {
            guard let id = defaultDevice() else { return }
            var addr = address(kAudioHardwareServiceDeviceProperty_VirtualMainVolume)
            var value = Float32(min(max(newValue, 0), 1))
            AudioObjectSetPropertyData(id, &addr, 0, nil, UInt32(MemoryLayout<Float32>.size), &value)
        }
    }

    static var muted: Bool {
        get {
            guard let id = defaultDevice() else { return false }
            var addr = address(kAudioDevicePropertyMute)
            guard AudioObjectHasProperty(id, &addr) else { return false }
            var value: UInt32 = 0
            var size = UInt32(MemoryLayout<UInt32>.size)
            return AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &value) == noErr && value != 0
        }
        set {
            guard let id = defaultDevice() else { return }
            var addr = address(kAudioDevicePropertyMute)
            guard AudioObjectHasProperty(id, &addr) else { return }
            var value: UInt32 = newValue ? 1 : 0
            AudioObjectSetPropertyData(id, &addr, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value)
        }
    }
}

/// Built-in display brightness through the private DisplayServices framework.
enum SystemBrightness {
    private typealias GetFn = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
    private typealias SetFn = @convention(c) (CGDirectDisplayID, Float) -> Int32

    private static let symbols: (GetFn, SetFn)? = {
        guard let h = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_NOW),
              let g = dlsym(h, "DisplayServicesGetBrightness"),
              let s = dlsym(h, "DisplayServicesSetBrightness") else { return nil }
        return (unsafeBitCast(g, to: GetFn.self), unsafeBitCast(s, to: SetFn.self))
    }()

    private static var builtinDisplay: CGDirectDisplayID? {
        var count: UInt32 = 0
        CGGetActiveDisplayList(0, nil, &count)
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetActiveDisplayList(count, &ids, &count)
        return ids.first { CGDisplayIsBuiltin($0) != 0 }
    }

    static var isAvailable: Bool { symbols != nil && builtinDisplay != nil }

    static var brightness: Float {
        get {
            guard let (get, _) = symbols, let d = builtinDisplay else { return 0 }
            var v: Float = 0
            return get(d, &v) == 0 ? v : 0
        }
        set {
            guard let (_, set) = symbols, let d = builtinDisplay else { return }
            _ = set(d, min(max(newValue, 0), 1))
        }
    }
}
