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
        if let i = args.firstIndex(of: "--remove-bg"), i + 2 < args.count {
            let input = URL(fileURLWithPath: args[i + 1])
            guard let cg = BackgroundRemover.loadImage(at: input), let png = BackgroundRemover.cutoutPNG(cg) else {
                print("no subject / unreadable")
                exit(1)
            }
            try? png.write(to: URL(fileURLWithPath: args[i + 2]))
            print("wrote \(png.count) bytes")
            exit(0)
        }
        if let i = args.firstIndex(of: "--clean-scan"), i + 1 < args.count {
            // Dry run: list what the Cleaner would offer, delete nothing.
            let app = URL(fileURLWithPath: args[i + 1])
            if let refusal = CleanerScanner.refusal(for: app) { print("refused: \(refusal)"); exit(0) }
            let found = CleanerScanner.scan(app: app)
            print("bundle: \(found.bundleID ?? "-")")
            for item in found.items {
                print("\(item.selected ? "[x]" : "[ ]") \(item.kind) \(item.byName ? "(by name) " : "")\(ByteCountFormatter.string(fromByteCount: item.size, countStyle: .file))  \((item.url.path as NSString).abbreviatingWithTildeInPath)")
            }
            exit(0)
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
