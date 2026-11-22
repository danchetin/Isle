import AudioToolbox
import CoreAudio
import Foundation

/// Small CoreAudio property helpers.
enum CA {
    static func address(_ selector: AudioObjectPropertySelector,
                        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    static func value<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, default def: T) -> T {
        var addr = address(selector)
        var value = def
        var size = UInt32(MemoryLayout<T>.size)
        let status = withUnsafeMutablePointer(to: &value) { AudioObjectGetPropertyData(object, &addr, 0, nil, &size, $0) }
        return status == noErr ? value : def
    }

    static func string(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var addr = address(selector)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = withUnsafeMutablePointer(to: &value) { AudioObjectGetPropertyData(object, &addr, 0, nil, &size, $0) }
        guard status == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }

    static func objects(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> [AudioObjectID] {
        var addr = address(selector)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(object, &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }

    static var defaultOutputDevice: AudioObjectID {
        value(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice, default: AudioObjectID(0))
    }
}

/// One app's audio rerouted through Isle at a chosen gain:
/// process tap (original muted) → private aggregate device (tap + current output) → IOProc × gain.
/// Destroyed with the object or the process, so audio always returns to normal.
final class ProcessTap {
    private var tapID = AudioObjectID(0)
    private var aggregateID = AudioObjectID(0)
    private var procID: AudioDeviceIOProcID?
    private let gain = UnsafeMutablePointer<Float>.allocate(capacity: 1)
    let outputDevice: AudioObjectID

    var volume: Float {
        get { gain.pointee }
        set { gain.pointee = max(0, min(newValue, 1)) }
    }

    init?(processes: [AudioObjectID], volume: Float) {
        gain.initialize(to: volume)
        outputDevice = CA.defaultOutputDevice
        guard outputDevice != 0, let outputUID = CA.string(outputDevice, kAudioDevicePropertyDeviceUID) else {
            gain.deallocate()
            return nil
        }

        let description = CATapDescription(stereoMixdownOfProcesses: processes)
        description.uuid = UUID()
        description.muteBehavior = .mutedWhenTapped
        description.isPrivate = true
        description.name = "Isle per-app volume"
        guard AudioHardwareCreateProcessTap(description, &tapID) == noErr, tapID != 0 else {
            gain.deallocate()
            return nil
        }

        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Isle Mix",
            kAudioAggregateDeviceUIDKey: "app.isle.mix.\(UUID().uuidString)",
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapDriftCompensationKey: true,
                kAudioSubTapUIDKey: description.uuid.uuidString,
            ]],
        ]
        guard AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &aggregateID) == noErr, aggregateID != 0 else {
            AudioHardwareDestroyProcessTap(tapID)
            gain.deallocate()
            return nil
        }

        let gain = self.gain
        let status = AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, nil) { _, inInput, _, outOutput, _ in
            ProcessTap.render(input: inInput, output: outOutput, gain: gain.pointee)
        }
        guard status == noErr, let procID, AudioDeviceStart(aggregateID, procID) == noErr else {
            teardown()
            return nil
        }
    }

    deinit { teardown() }

    private var tornDown = false

    private func teardown() {
        guard !tornDown else { return }
        tornDown = true
        if let procID {
            AudioDeviceStop(aggregateID, procID)
            AudioDeviceDestroyIOProcID(aggregateID, procID)
        }
        if aggregateID != 0 { AudioHardwareDestroyAggregateDevice(aggregateID) }
        if tapID != 0 { AudioHardwareDestroyProcessTap(tapID) }
        gain.deallocate()
    }

    /// Real-time thread: copy tapped samples to the output, scaled. Handles interleaved and
    /// non-interleaved layouts on either side; no allocations.
    private static func render(input: UnsafePointer<AudioBufferList>, output: UnsafeMutablePointer<AudioBufferList>, gain: Float) {
        let inList = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        let outList = UnsafeMutableAudioBufferListPointer(output)

        withUnsafeTemporaryAllocation(of: (UnsafeMutablePointer<Float>, Int, Int).self, capacity: 16) { chans in
            var inCount = 0
            var inFrames = Int.max
            for buf in inList {
                guard let data = buf.mData, buf.mNumberChannels > 0 else { continue }
                let ch = Int(buf.mNumberChannels)
                inFrames = min(inFrames, Int(buf.mDataByteSize) / 4 / ch)
                for c in 0..<ch where inCount < 16 {
                    chans[inCount] = (data.assumingMemoryBound(to: Float.self), c, ch)
                    inCount += 1
                }
            }
            var outChannel = 0
            for buf in outList {
                guard let data = buf.mData else { continue }
                let ch = max(1, Int(buf.mNumberChannels))
                let frames = Int(buf.mDataByteSize) / 4 / ch
                let dst = data.assumingMemoryBound(to: Float.self)
                for c in 0..<ch {
                    if inCount == 0 {
                        for f in 0..<frames { dst[f * ch + c] = 0 }
                    } else {
                        let (src, offset, stride) = chans[(outChannel + c) % inCount]
                        let n = min(frames, inFrames)
                        for f in 0..<n { dst[f * ch + c] = src[f * stride + offset] * gain }
                        if n < frames { for f in n..<frames { dst[f * ch + c] = 0 } }
                    }
                }
                outChannel += ch
            }
        }
    }
}
