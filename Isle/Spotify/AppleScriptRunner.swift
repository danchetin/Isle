import Foundation

struct ScriptResult {
    var output: String?
    var errorCode: Int?
}

/// Runs AppleScript on one serial background queue (NSAppleScript is not thread-safe).
final class AppleScriptRunner: @unchecked Sendable {
    private let queue = DispatchQueue(label: "app.isle.applescript", qos: .userInitiated)
    private var compiled: [String: NSAppleScript] = [:]

    func run(_ source: String, cache: Bool = false) async -> ScriptResult {
        await withCheckedContinuation { continuation in
            queue.async {
                let script: NSAppleScript?
                if cache, let existing = self.compiled[source] {
                    script = existing
                } else {
                    script = NSAppleScript(source: source)
                    if cache, let script {
                        var compileError: NSDictionary?
                        script.compileAndReturnError(&compileError)
                        self.compiled[source] = script
                    }
                }
                var error: NSDictionary?
                let descriptor = script?.executeAndReturnError(&error)
                if let error {
                    let code = (error[NSAppleScript.errorNumber] as? NSNumber)?.intValue ?? -1
                    continuation.resume(returning: ScriptResult(output: nil, errorCode: code))
                } else {
                    continuation.resume(returning: ScriptResult(output: descriptor?.stringValue ?? "", errorCode: nil))
                }
            }
        }
    }
}

enum SpotifyScripts {
    /// Returns fields separated by ASCII 30:
    /// state, id, name, artist, album, duration(ms), position(s), artwork url, shuffling, repeating, volume
    static let state = """
    if application id "com.spotify.client" is running then
        tell application id "com.spotify.client"
            set isleSep to character id 30
            set isleState to (player state as text)
            try
                set isleTrack to current track
                return isleState & isleSep & (id of isleTrack) & isleSep & (name of isleTrack) & isleSep & (artist of isleTrack) & isleSep & (album of isleTrack) & isleSep & ((duration of isleTrack) as text) & isleSep & ((player position) as text) & isleSep & (artwork url of isleTrack) & isleSep & (shuffling as text) & isleSep & (repeating as text) & isleSep & ((sound volume) as text)
            on error
                return isleState
            end try
        end tell
    end if
    return "notrunning"
    """

    static func command(_ body: String) -> String {
        """
        if application id "com.spotify.client" is running then
            tell application id "com.spotify.client" to \(body)
        end if
        """
    }
}
