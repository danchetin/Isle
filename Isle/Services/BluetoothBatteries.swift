import Foundation
import IOBluetooth

/// Battery levels of connected Bluetooth devices. AirPods report left / right / case through
/// undocumented IOBluetoothDevice properties; read defensively (missing → skipped).
enum BluetoothBatteries {
    static func connected() -> [BatteryDevice] {
        guard let paired = IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice] else { return [] }
        var out: [BatteryDevice] = []
        for device in paired where device.isConnected() {
            let name = device.name ?? "Bluetooth"
            let id = device.addressString ?? name
            let lower = name.lowercased()
            let isAirPods = lower.contains("airpods")
            let isPro = lower.contains("pro")
            let isMax = lower.contains("max")
            let budLeft = isMax ? "airpodsmax" : (isPro ? "airpodpro.left" : "airpod.left")
            let budRight = isMax ? "airpodsmax" : (isPro ? "airpodpro.right" : "airpod.right")
            let budSymbol = isMax ? "airpodsmax" : (isPro ? "airpodspro" : "airpods")

            func percent(_ key: String) -> Double? {
                guard device.responds(to: NSSelectorFromString(key)),
                      let v = device.value(forKey: key) as? Int, v > 0, v <= 100 else { return nil }
                return Double(v) / 100
            }

            if let l = percent("batteryPercentLeft") {
                out.append(BatteryDevice(id: id + "-L", name: "Левый", symbol: budLeft, level: l, charging: false))
            }
            if let r = percent("batteryPercentRight") {
                out.append(BatteryDevice(id: id + "-R", name: "Правый", symbol: budRight, level: r, charging: false))
            }
            if let c = percent("batteryPercentCase") {
                out.append(BatteryDevice(id: id + "-C", name: "Кейс", symbol: isPro ? "airpodspro.chargingcase.wireless.fill" : "airpods.chargingcase.fill", level: c, charging: false))
            }
            if let s = percent("batteryPercentSingle") ?? percent("batteryPercent") {
                let symbol: String
                if isAirPods { symbol = budSymbol }
                else if lower.contains("keyboard") { symbol = "keyboard" }
                else if lower.contains("mouse") { symbol = "magicmouse" }
                else if lower.contains("trackpad") { symbol = "rectangle.and.hand.point.up.left" }
                else { symbol = "headphones" }
                out.append(BatteryDevice(id: id, name: name, symbol: symbol, level: s, charging: false))
            }
        }
        return out
    }
}
