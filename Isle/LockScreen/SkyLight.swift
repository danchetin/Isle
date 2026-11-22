import AppKit

/// Puts windows into a private SkyLight space that sits above the macOS lock screen.
/// Technique from Lakr233/SkyLightWindow (MIT): https://github.com/Lakr233/SkyLightWindow
/// Private API: a macOS update can break it, so every call checks `isAvailable`.
@MainActor
final class SkyLight {
    static let shared = SkyLight()

    private typealias MainConnectionID = @convention(c) () -> Int32
    private typealias SpaceCreate = @convention(c) (Int32, Int32, Int32) -> Int32
    private typealias SpaceSetAbsoluteLevel = @convention(c) (Int32, Int32, Int32) -> Int32
    private typealias ShowSpaces = @convention(c) (Int32, CFArray) -> Int32
    private typealias AddWindowsAndRemoveFromSpaces = @convention(c) (Int32, Int32, CFArray, Int32) -> Int32

    /// kSLSSpaceAbsoluteLevelNotificationCenterAtScreenLock: just above the lock screen (300).
    private static let lockScreenOverlayLevel: Int32 = 400

    let isAvailable: Bool
    private let connection: Int32
    private let space: Int32
    private let addWindows: AddWindowsAndRemoveFromSpaces?

    private init() {
        guard let handle = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/Versions/A/SkyLight", RTLD_NOW),
              let pConnection = dlsym(handle, "SLSMainConnectionID"),
              let pCreate = dlsym(handle, "SLSSpaceCreate"),
              let pLevel = dlsym(handle, "SLSSpaceSetAbsoluteLevel"),
              let pShow = dlsym(handle, "SLSShowSpaces"),
              let pAdd = dlsym(handle, "SLSSpaceAddWindowsAndRemoveFromSpaces")
        else {
            isAvailable = false
            connection = 0
            space = 0
            addWindows = nil
            return
        }
        let mainConnection = unsafeBitCast(pConnection, to: MainConnectionID.self)
        let create = unsafeBitCast(pCreate, to: SpaceCreate.self)
        let setLevel = unsafeBitCast(pLevel, to: SpaceSetAbsoluteLevel.self)
        let show = unsafeBitCast(pShow, to: ShowSpaces.self)

        connection = mainConnection()
        space = create(connection, 1, 0)
        _ = setLevel(connection, space, Self.lockScreenOverlayLevel)
        _ = show(connection, [space] as CFArray)
        addWindows = unsafeBitCast(pAdd, to: AddWindowsAndRemoveFromSpaces.self)
        isAvailable = space != 0
    }

    func moveAboveLockScreen(_ window: NSWindow) {
        guard isAvailable, let addWindows else { return }
        _ = addWindows(connection, space, [window.windowNumber] as CFArray, 7)
    }
}
