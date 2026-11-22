import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// One file or folder that belongs to the app being removed.
struct CleanerItem: Identifiable, Equatable {
    let id: URL
    var url: URL { id }
    let kind: String
    /// Found by bundle id (confident) vs. only by app name (user should check).
    let byName: Bool
    var size: Int64 = 0
    var selected: Bool
}

enum CleanerScanner {
    /// (folder in ~/Library, label, match by app name too)
    private static let places: [(String, String, Bool)] = [
        ("Application Support", "Данные", true),
        ("Caches", "Кэш", true),
        ("Preferences", "Настройки", false),
        ("Preferences/ByHost", "Настройки", false),
        ("Containers", "Контейнер", false),
        ("Group Containers", "Общий контейнер", false),
        ("Saved Application State", "Состояние окон", false),
        ("Logs", "Логи", true),
        ("HTTPStorages", "Веб-данные", false),
        ("WebKit", "Веб-данные", false),
        ("Cookies", "Cookies", false),
        ("LaunchAgents", "Автозапуск", false),
        ("Application Scripts", "Скрипты", false),
    ]

    static func scan(app: URL) -> (bundleID: String?, items: [CleanerItem]) {
        let bundle = Bundle(url: app)
        let bundleID = bundle?.bundleIdentifier
        let name = (bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? app.deletingPathExtension().lastPathComponent
        let fm = FileManager.default
        let library = fm.homeDirectoryForCurrentUser.appendingPathComponent("Library")

        var items = [CleanerItem(id: app, kind: "Приложение", byName: false, selected: true)]
        for (folder, label, matchName) in places {
            let dir = library.appendingPathComponent(folder)
            guard let entries = try? fm.contentsOfDirectory(atPath: dir.path) else { continue }
            for entry in entries {
                let lower = entry.lowercased()
                var byID = false
                if let id = bundleID?.lowercased() {
                    byID = lower == id || lower.hasPrefix(id + ".") || lower.hasSuffix("." + id) || lower.contains(id)
                }
                let byName = !byID && matchName && name.count >= 4 && lower == name.lowercased()
                guard byID || byName else { continue }
                items.append(CleanerItem(id: dir.appendingPathComponent(entry), kind: label, byName: byName, selected: byID))
            }
        }
        for i in items.indices { items[i].size = allocatedSize(items[i].url) }
        return (bundleID, items)
    }

    static func allocatedSize(_ url: URL) -> Int64 {
        let keys: Set<URLResourceKey> = [.totalFileAllocatedSizeKey, .isDirectoryKey]
        guard let values = try? url.resourceValues(forKeys: keys) else { return 0 }
        guard values.isDirectory == true else { return Int64(values.totalFileAllocatedSize ?? 0) }
        var total: Int64 = 0
        let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: Array(keys), options: [], errorHandler: { _, _ in true })
        while let f = e?.nextObject() as? URL {
            total += Int64((try? f.resourceValues(forKeys: [.totalFileAllocatedSizeKey]))?.totalFileAllocatedSize ?? 0)
        }
        return total
    }

    /// Apple's own apps and Isle are never offered for removal.
    static func refusal(for app: URL) -> String? {
        let id = Bundle(url: app)?.bundleIdentifier ?? ""
        if app.path.hasPrefix("/System/") || id.hasPrefix("com.apple.") { return "Системные приложения Apple удалять не буду." }
        if id == Bundle.main.bundleIdentifier { return "Isle себя не удаляет 🙂" }
        return nil
    }
}

@MainActor
final class CleanerModel: ObservableObject {
    let app: URL
    @Published var items: [CleanerItem] = []
    @Published var scanning = true
    @Published var result: String?
    @Published var refusal: String?
    @Published var bundleID: String?

    init(app: URL) {
        self.app = app
        refusal = CleanerScanner.refusal(for: app)
        guard refusal == nil else {
            scanning = false
            return
        }
        Task {
            let found = await Task.detached(priority: .userInitiated) { CleanerScanner.scan(app: app) }.value
            bundleID = found.bundleID
            items = found.items
            scanning = false
        }
    }

    var name: String { app.deletingPathExtension().lastPathComponent }
    var icon: NSImage { NSWorkspace.shared.icon(forFile: app.path) }
    var selectedSize: Int64 { items.filter(\.selected).map(\.size).reduce(0, +) }

    var runningApp: NSRunningApplication? {
        bundleID.flatMap { NSRunningApplication.runningApplications(withBundleIdentifier: $0).first }
    }

    func quitApp() {
        runningApp?.terminate()
        objectWillChange.send()
    }

    func moveToTrash() {
        var moved = 0
        var failed: [String] = []
        for item in items where item.selected {
            do {
                try FileManager.default.trashItem(at: item.url, resultingItemURL: nil)
                moved += 1
            } catch {
                failed.append(item.url.lastPathComponent)
            }
        }
        items.removeAll { $0.selected && !failed.contains($0.url.lastPathComponent) }
        if failed.isEmpty {
            result = "В Корзине: \(moved). Можно вернуть из Корзины."
        } else {
            result = "В Корзине: \(moved). Не получилось: \(failed.joined(separator: ", ")) — нужны права администратора, удали их в Finder."
        }
        AgentsService.shared.notify(title: "\(name) удалён", subtitle: "\(moved) объектов в Корзине")
    }
}

private func formatBytes(_ b: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: b, countStyle: .file)
}

struct CleanerView: View {
    @ObservedObject var model: CleanerModel
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(nsImage: model.icon).resizable().frame(width: 48, height: 48)
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.name).font(.system(size: 17, weight: .bold))
                    Text(model.bundleID ?? model.app.path)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
            }

            if let refusal = model.refusal {
                Text(refusal).foregroundStyle(.secondary)
                Spacer()
            } else if model.scanning {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Ищу файлы приложения…").foregroundStyle(.secondary)
                }
                Spacer()
            } else {
                if model.runningApp != nil {
                    HStack {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
                        Text("Приложение запущено — закрой его перед удалением.")
                            .font(.system(size: 12, weight: .medium))
                        Spacer()
                        Button("Завершить") { model.quitApp() }
                    }
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Color.yellow.opacity(0.12)))
                }

                List {
                    ForEach($model.items) { $item in
                        HStack(spacing: 10) {
                            Toggle("", isOn: $item.selected).labelsHidden()
                            Image(nsImage: NSWorkspace.shared.icon(forFile: item.url.path))
                                .resizable()
                                .frame(width: 18, height: 18)
                            VStack(alignment: .leading, spacing: 1) {
                                HStack(spacing: 6) {
                                    Text(item.kind).font(.system(size: 12, weight: .semibold))
                                    if item.byName {
                                        Text("по имени — проверь")
                                            .font(.system(size: 10, weight: .semibold))
                                            .foregroundStyle(.orange)
                                    }
                                }
                                Text((item.url.path as NSString).abbreviatingWithTildeInPath)
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                            Spacer()
                            Text(formatBytes(item.size))
                                .font(.system(size: 11).monospacedDigit())
                                .foregroundStyle(.secondary)
                            Button {
                                NSWorkspace.shared.activateFileViewerSelecting([item.url])
                            } label: {
                                Image(systemName: "magnifyingglass")
                            }
                            .buttonStyle(.borderless)
                            .help("Показать в Finder")
                        }
                    }
                }
                .listStyle(.inset)

                if let result = model.result {
                    Text(result)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                }

                HStack {
                    Text("Файлы уйдут в Корзину — их можно вернуть.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Закрыть", action: close)
                    Button("В Корзину (\(formatBytes(model.selectedSize)))") { model.moveToTrash() }
                        .buttonStyle(.borderedProminent)
                        .tint(.red)
                        .disabled(model.selectedSize == 0 && !model.items.contains(where: \.selected) || model.runningApp != nil)
                }
            }
        }
        .padding(18)
        .frame(width: 560, height: 520)
    }
}

/// Owns the Cleaner windows.
@MainActor
enum CleanerWindows {
    private static var windows: [NSWindow] = []

    static func chooseApp() {
        let panel = NSOpenPanel()
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = false
        panel.prompt = "Выбрать"
        panel.message = "Какое приложение удалить вместе с его файлами?"
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        open(app: url)
    }

    static func open(app: URL) {
        let model = CleanerModel(app: app)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 520),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Удалить «\(model.name)»"
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: CleanerView(model: model) { [weak window] in window?.close() })
        window.center()
        window.level = .floating
        windows.append(window)
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { note in
            let closed = note.object as? NSWindow
            MainActor.assumeIsolated { windows.removeAll { $0 === closed } }
        }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }
}
