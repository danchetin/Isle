import Foundation

enum PrefKey {
    static let lockScreenEnabled = "lockScreenEnabled"
    static let clockDepth = "clockDepth"
    static let clockStyle = "clockStyle"
    static let notchEnabled = "notchEnabled"
    static let hudEnabled = "hudEnabled"
}

enum ClockStyle: String {
    case large
    case inline
}

enum Prefs {
    private static var d: UserDefaults { .standard }

    static func register() {
        d.register(defaults: [
            PrefKey.lockScreenEnabled: true,
            PrefKey.clockDepth: true,
            PrefKey.clockStyle: ClockStyle.large.rawValue,
            PrefKey.notchEnabled: true,
            PrefKey.hudEnabled: true,
        ])
    }

    static var lockScreenEnabled: Bool {
        get { d.bool(forKey: PrefKey.lockScreenEnabled) }
        set { d.set(newValue, forKey: PrefKey.lockScreenEnabled) }
    }

    static var clockDepth: Bool {
        get { d.bool(forKey: PrefKey.clockDepth) }
        set { d.set(newValue, forKey: PrefKey.clockDepth) }
    }

    static var clockStyle: ClockStyle {
        get { ClockStyle(rawValue: d.string(forKey: PrefKey.clockStyle) ?? "") ?? .large }
        set { d.set(newValue.rawValue, forKey: PrefKey.clockStyle) }
    }

    static var hudEnabled: Bool {
        get { d.bool(forKey: PrefKey.hudEnabled) }
        set { d.set(newValue, forKey: PrefKey.hudEnabled) }
    }

    static var notchEnabled: Bool {
        get { d.bool(forKey: PrefKey.notchEnabled) }
        set { d.set(newValue, forKey: PrefKey.notchEnabled) }
    }
}
