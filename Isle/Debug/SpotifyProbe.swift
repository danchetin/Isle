import CoreGraphics
import Foundation

/// `Isle --probe`: asks Spotify for each field separately and prints the raw result,
/// so a field that breaks the combined state script is easy to spot.
enum SpotifyProbe {
    static func run() {
        print("input monitoring (listen) access: \(CGPreflightListenEventAccess())")
        print("keyDown counter: \(CGEventSource.counterForEventType(.combinedSessionState, eventType: .keyDown))")
        let fields = [
            "player state as text",
            "id of current track",
            "name of current track",
            "artist of current track",
            "album of current track",
            "(duration of current track) as text",
            "(player position) as text",
            "artwork url of current track",
            "shuffling as text",
            "repeating as text",
            "(sound volume) as text",
        ]
        for field in fields {
            let source = "tell application id \"com.spotify.client\" to return \(field)"
            var error: NSDictionary?
            let result = NSAppleScript(source: source)?.executeAndReturnError(&error)
            if let error {
                let code = error[NSAppleScript.errorNumber] ?? "?"
                let message = error[NSAppleScript.errorMessage] ?? ""
                print("✗ \(field): error \(code) \(message)")
            } else {
                print("✓ \(field): \(result?.stringValue ?? "<nil>")")
            }
        }
        var error: NSDictionary?
        let combined = NSAppleScript(source: SpotifyScripts.state)?.executeAndReturnError(&error)
        print("combined: \(combined?.stringValue?.replacingOccurrences(of: "\u{1E}", with: " | ") ?? "<nil>") \(error.map { "\($0)" } ?? "")")
    }
}
