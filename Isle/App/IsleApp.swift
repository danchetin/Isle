import AppKit

@main
enum IsleMain {
    @MainActor private static var delegate: AppDelegate?

    static func main() {
        let args = CommandLine.arguments
        // Hook forwarder first: must stay fast and never touch AppKit.
        if let i = args.firstIndex(of: "--hook") {
            HookClient.run(arguments: Array(args[(i + 1)...]))
        }
        if args.contains("--mcp") {
            McpServer.run()
        }
        if args.contains("--install-hooks") {
            do {
                MainActor.assumeIsolated { HookInstaller.writeShim() }
                try HookInstaller.installClaude()
                print("installed: \(HookInstaller.claudeInstalled)")
            } catch {
                print("failed: \(error)")
            }
            return
        }
        if args.contains("--uitest") {
            MainActor.assumeIsolated { UITestRunner.run() }
            return
        }
        if args.contains("--probe") {
            SpotifyProbe.run()
            return
        }
        if let i = args.firstIndex(of: "--snapshot") {
            MainActor.assumeIsolated {
                SnapshotRunner.run(arguments: Array(args[(i + 1)...]))
            }
            return
        }
        MainActor.assumeIsolated {
            let app = NSApplication.shared
            let delegate = AppDelegate()
            Self.delegate = delegate
            app.delegate = delegate
            app.setActivationPolicy(.accessory)
            app.run()
        }
    }
}
