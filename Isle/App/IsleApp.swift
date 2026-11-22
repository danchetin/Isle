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
        if let i = args.firstIndex(of: "--convert"), i + 1 < args.count {
            // Parser + conversion check against live rates.
            let sema = DispatchSemaphore(value: 0)
            var rates: [String: Double] = [:]
            URLSession.shared.dataTask(with: URL(string: "https://cdn.jsdelivr.net/npm/@fawazahmed0/currency-api@latest/v1/currencies/amd.json")!) { data, _, _ in
                if let data, let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let r = obj["amd"] as? [String: Double] {
                    rates = r.merging(["amd": 1]) { a, _ in a }
                }
                sema.signal()
            }.resume()
            sema.wait()
            for q in args[(i + 1)...] {
                guard let parsed = CurrencyQueryParser.parse(q, known: Set(rates.keys)) else { print("\(q) → (не понял)"); continue }
                let out = CurrencyQueryParser.convert(parsed, rates: rates).map { "\(CurrencyQueryParser.format($0.value)) \($0.code.uppercased())" }
                print("\(q) → \(parsed.amount) \(parsed.from) → \(out.joined(separator: ", "))")
            }
            exit(0)
        }
        if args.contains("--claude-usage") {
            let start = Date()
            let entries = ClaudeUsageScanner().scan()
            print("entries: \(entries.count) in \(String(format: "%.2f", Date().timeIntervalSince(start)))s")
            MainActor.assumeIsolated {
                let svc = ClaudeUsageService.shared
                svc.refresh()
            }
            let deadline = Date().addingTimeInterval(20)
            while Date() < deadline {
                RunLoop.main.run(until: Date().addingTimeInterval(0.2))
                let done = MainActor.assumeIsolated { ClaudeUsageService.shared.loaded }
                if done { break }
            }
            MainActor.assumeIsolated {
                let svc = ClaudeUsageService.shared
                if let w = svc.current {
                    print("window: \(w.start) – \(w.end), tokens \(formatTokens(w.tokens)), resets \(ClaudeUsageBar.remaining(w.end, now: Date()))")
                } else { print("window: none active") }
                print("peak week: \(formatTokens(svc.peak)), today: \(formatTokens(svc.today))")
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
