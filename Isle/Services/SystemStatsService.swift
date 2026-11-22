import Darwin
import Foundation
import IOKit
import IOKit.ps

/// CPU, temperature, memory, GPU, disk and network, sampled every 2 s while a stats card
/// is on screen. Keeps a short rolling history for the sparklines.
@MainActor
final class SystemStatsService: ObservableObject {
    static let shared = SystemStatsService()
    static let historyLength = 45

    @Published private(set) var cpu: Double = 0              // 0…1
    @Published private(set) var temperature: Double?         // °C
    @Published private(set) var memoryUsed: Double = 0       // bytes
    @Published private(set) var memoryTotal = Double(ProcessInfo.processInfo.physicalMemory)
    @Published private(set) var gpu: Double?                 // 0…1
    @Published private(set) var diskFree: Double = 0         // bytes
    @Published private(set) var diskTotal: Double = 1
    @Published private(set) var netDown: Double = 0          // bytes/s
    @Published private(set) var netUp: Double = 0
    @Published private(set) var thermal = ProcessInfo.processInfo.thermalState

    @Published private(set) var cpuHistory: [Double] = []
    @Published private(set) var tempHistory: [Double] = []
    @Published private(set) var memoryHistory: [Double] = []
    @Published private(set) var gpuHistory: [Double] = []
    @Published private(set) var netHistory: [Double] = []

    private var timer: Timer?
    private var users = 0
    private var lastTicks: [UInt32]?
    private var lastNet: (down: UInt64, up: UInt64, at: Date)?
    private let sensors = TemperatureSensors()

    /// Cards call activate on appear and deactivate on disappear.
    func activate() {
        users += 1
        guard timer == nil else { return }
        sample()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sample() }
        }
    }

    func deactivate() {
        users = max(0, users - 1)
        guard users == 0 else { return }
        timer?.invalidate()
        timer = nil
    }

    private func push(_ v: Double, to history: inout [Double]) {
        history.append(v)
        if history.count > Self.historyLength { history.removeFirst(history.count - Self.historyLength) }
    }

    private func sample() {
        if let c = cpuUsage() {
            cpu = c
            push(c, to: &cpuHistory)
        }
        if let t = sensors.cpuTemperature() {
            temperature = t
            push(t, to: &tempHistory)
        }
        thermal = ProcessInfo.processInfo.thermalState
        if let m = memoryUsage() {
            memoryUsed = m
            push(m / max(memoryTotal, 1), to: &memoryHistory)
        }
        if let g = gpuUsage() {
            gpu = g
            push(g, to: &gpuHistory)
        }
        if let values = try? URL(fileURLWithPath: "/").resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey]) {
            diskFree = Double(values.volumeAvailableCapacityForImportantUsage ?? 0)
            diskTotal = Double(values.volumeTotalCapacity ?? 1)
        }
        sampleNetwork()
    }

    // MARK: CPU

    private func cpuUsage() -> Double? {
        var count: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        guard host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &count, &info, &infoCount) == KERN_SUCCESS,
              let info else { return nil }
        defer {
            vm_deallocate(mach_task_self_, vm_address_t(bitPattern: info), vm_size_t(Int(infoCount) * MemoryLayout<integer_t>.stride))
        }
        let ticks = (0..<Int(infoCount)).map { UInt32(bitPattern: info[$0]) }
        defer { lastTicks = ticks }
        guard let last = lastTicks, last.count == ticks.count else { return nil }

        var busy: UInt64 = 0
        var total: UInt64 = 0
        let stride = Int(CPU_STATE_MAX)
        for cpu in 0..<Int(count) {
            let base = cpu * stride
            for state in 0..<stride {
                let d = UInt64(ticks[base + state] &- last[base + state])
                total += d
                if state != Int(CPU_STATE_IDLE) { busy += d }
            }
        }
        return total > 0 ? Double(busy) / Double(total) : nil
    }

    // MARK: Memory (≈ Activity Monitor "Memory Used")

    private func memoryUsage() -> Double? {
        var stats = vm_statistics64()
        var size = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &stats) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(size)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &size)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        let page = Double(vm_kernel_page_size)
        let app = Double(stats.internal_page_count) - Double(stats.purgeable_count)
        return (app + Double(stats.wire_count) + Double(stats.compressor_page_count)) * page
    }

    // MARK: GPU

    private func gpuUsage() -> Double? {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &iterator) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }
        var best: Double?
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            guard let props = IORegistryEntryCreateCFProperty(service, "PerformanceStatistics" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? [String: Any],
                let util = props["Device Utilization %"] as? Int else { continue }
            best = max(best ?? 0, Double(util) / 100)
        }
        return best
    }

    // MARK: Network

    private func sampleNetwork() {
        var down: UInt64 = 0
        var up: UInt64 = 0
        var addrs: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&addrs) == 0, let first = addrs else { return }
        defer { freeifaddrs(addrs) }
        var ptr: UnsafeMutablePointer<ifaddrs>? = first
        while let ifa = ptr {
            defer { ptr = ifa.pointee.ifa_next }
            guard let addr = ifa.pointee.ifa_addr, addr.pointee.sa_family == UInt8(AF_LINK),
                  let data = ifa.pointee.ifa_data else { continue }
            let name = String(cString: ifa.pointee.ifa_name)
            guard !name.hasPrefix("lo"), !name.hasPrefix("utun"), !name.hasPrefix("awdl"), !name.hasPrefix("llw") else { continue }
            let d = data.assumingMemoryBound(to: if_data.self).pointee
            down += UInt64(d.ifi_ibytes)
            up += UInt64(d.ifi_obytes)
        }
        let now = Date()
        if let last = lastNet, down >= last.down, up >= last.up {
            let dt = max(now.timeIntervalSince(last.at), 0.5)
            netDown = Double(down - last.down) / dt
            netUp = Double(up - last.up) / dt
            push(netDown, to: &netHistory)
        }
        lastNet = (down, up, now)
    }
}

/// Apple Silicon die temperatures through IOHIDEventSystem (private, looked up at runtime).
final class TemperatureSensors {
    private typealias CreateFn = @convention(c) (CFAllocator?) -> OpaquePointer?
    private typealias SetMatchingFn = @convention(c) (OpaquePointer, CFDictionary) -> Int32
    private typealias CopyServicesFn = @convention(c) (OpaquePointer) -> Unmanaged<CFArray>?
    private typealias CopyPropertyFn = @convention(c) (OpaquePointer, CFString) -> Unmanaged<CFTypeRef>?
    private typealias CopyEventFn = @convention(c) (OpaquePointer, Int64, Int32, Int64) -> OpaquePointer?
    private typealias GetFloatFn = @convention(c) (OpaquePointer, Int32) -> Double

    private let copyEvent: CopyEventFn?
    private let getFloat: GetFloatFn?
    /// Retained service refs whose product name looks like a CPU die sensor.
    private var dieSensors: [OpaquePointer] = []
    private var otherSensors: [OpaquePointer] = []
    private var servicesArray: CFArray?

    private static let temperatureEvent: Int64 = 15 // kIOHIDEventTypeTemperature

    init() {
        guard let h = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW),
              let pCreate = dlsym(h, "IOHIDEventSystemClientCreate"),
              let pMatch = dlsym(h, "IOHIDEventSystemClientSetMatching"),
              let pServices = dlsym(h, "IOHIDEventSystemClientCopyServices"),
              let pProp = dlsym(h, "IOHIDServiceClientCopyProperty"),
              let pEvent = dlsym(h, "IOHIDServiceClientCopyEvent"),
              let pFloat = dlsym(h, "IOHIDEventGetFloatValue") else {
            copyEvent = nil
            getFloat = nil
            return
        }
        let create = unsafeBitCast(pCreate, to: CreateFn.self)
        let setMatching = unsafeBitCast(pMatch, to: SetMatchingFn.self)
        let copyServices = unsafeBitCast(pServices, to: CopyServicesFn.self)
        let copyProperty = unsafeBitCast(pProp, to: CopyPropertyFn.self)
        copyEvent = unsafeBitCast(pEvent, to: CopyEventFn.self)
        getFloat = unsafeBitCast(pFloat, to: GetFloatFn.self)

        guard let client = create(kCFAllocatorDefault) else { return }
        _ = setMatching(client, ["PrimaryUsagePage": 0xFF00, "PrimaryUsage": 5] as CFDictionary)
        guard let services = copyServices(client)?.takeRetainedValue() else { return }
        servicesArray = services // keeps the service refs alive
        for i in 0..<CFArrayGetCount(services) {
            guard let raw = CFArrayGetValueAtIndex(services, i) else { continue }
            let service = OpaquePointer(raw)
            let name = (copyProperty(service, "Product" as CFString)?.takeRetainedValue() as? String) ?? ""
            if name.contains("tdie") || name.contains("CPU") {
                dieSensors.append(service)
            } else {
                otherSensors.append(service)
            }
        }
    }

    private func read(_ service: OpaquePointer) -> Double? {
        guard let copyEvent, let getFloat, let event = copyEvent(service, Self.temperatureEvent, 0, 0) else { return nil }
        defer { Unmanaged<AnyObject>.fromOpaque(UnsafeRawPointer(event)).release() }
        let v = getFloat(event, Int32(Self.temperatureEvent << 16))
        return (10...130).contains(v) ? v : nil
    }

    /// Average of the CPU die sensors, else the hottest plausible sensor.
    func cpuTemperature() -> Double? {
        let die = dieSensors.compactMap(read)
        if !die.isEmpty { return die.reduce(0, +) / Double(die.count) }
        return otherSensors.compactMap(read).max()
    }
}

// MARK: - Batteries

struct BatteryDevice: Identifiable, Equatable {
    let id: String
    let name: String
    let symbol: String
    let level: Double   // 0…1
    let charging: Bool
}

/// Mac battery (IOPowerSources) + connected Bluetooth devices that report a level.
@MainActor
final class BatteryService: ObservableObject {
    static let shared = BatteryService()

    @Published private(set) var devices: [BatteryDevice] = []
    private var timer: Timer?
    private var users = 0
    private var injected = false

    func activate() {
        users += 1
        guard timer == nil, !injected else { return }
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    func deactivate() {
        users = max(0, users - 1)
        guard users == 0 else { return }
        timer?.invalidate()
        timer = nil
    }

    /// `bluetooth: false` for tools launched from a shell: TCC then blames the parent app,
    /// which has no Bluetooth usage description, and kills the process.
    func refresh(bluetooth: Bool = true) {
        var found: [BatteryDevice] = []
        if let mac = macBattery() { found.append(mac) }
        if bluetooth { found.append(contentsOf: BluetoothBatteries.connected()) }
        if found != devices { devices = found }
    }

    private func macBattery() -> BatteryDevice? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        for source in list {
            guard let d = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  (d[kIOPSTypeKey] as? String) == kIOPSInternalBatteryType,
                  let cur = d[kIOPSCurrentCapacityKey] as? Int,
                  let max = d[kIOPSMaxCapacityKey] as? Int, max > 0 else { continue }
            let charging = (d[kIOPSIsChargingKey] as? Bool) ?? false
            return BatteryDevice(id: "mac", name: "Mac", symbol: "laptopcomputer", level: Double(cur) / Double(max), charging: charging)
        }
        return nil
    }

    func debugInject(_ devices: [BatteryDevice]) {
        injected = true
        self.devices = devices
    }
}
