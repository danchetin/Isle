import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct TrayItem: Identifiable, Equatable {
    let id: URL
    var url: URL { id }
    var name: String { url.lastPathComponent }
}

/// File tray: a temporary shelf of *references* to files (nothing is copied or moved).
/// Survives restarts; files that disappear drop out.
@MainActor
final class TrayService: ObservableObject {
    static let shared = TrayService()
    private static let key = "trayPaths"

    @Published private(set) var items: [TrayItem] = []

    init() {
        let paths = UserDefaults.standard.stringArray(forKey: Self.key) ?? []
        items = paths.map { URL(fileURLWithPath: $0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
            .map { TrayItem(id: $0) }
    }

    func add(_ urls: [URL]) {
        for url in urls where !items.contains(where: { $0.url == url }) {
            items.append(TrayItem(id: url.standardizedFileURL))
        }
        save()
    }

    func remove(_ item: TrayItem) {
        items.removeAll { $0 == item }
        save()
    }

    func clear() {
        items = []
        save()
    }

    func prune() {
        let alive = items.filter { FileManager.default.fileExists(atPath: $0.url.path) }
        if alive != items {
            items = alive
            save()
        }
    }

    private func save() {
        UserDefaults.standard.set(items.map(\.url.path), forKey: Self.key)
    }

    func debugInject(_ urls: [URL]) { items = urls.map { TrayItem(id: $0) } }

    /// Loads file URLs from drop providers and adds them.
    func add(providers: [NSItemProvider]) {
        for p in providers where p.canLoadObject(ofClass: NSURL.self) {
            _ = p.loadObject(ofClass: NSURL.self) { obj, _ in
                guard let url = (obj as? NSURL).map({ $0 as URL }), url.isFileURL else { return }
                DispatchQueue.main.async { MainActor.assumeIsolated { TrayService.shared.add([url]) } }
            }
        }
    }
}

// MARK: - Widget

private struct TrayTile: View {
    let item: TrayItem
    var size: CGFloat = 40
    let tray: TrayService
    @State private var hover = false
    @Environment(\.isSnapshot) private var isSnapshot

    var body: some View {
        VStack(spacing: 4) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: item.url.path))
                .resizable()
                .frame(width: size, height: size)
            Text(item.name)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.white.opacity(0.75))
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .frame(width: size + 18)
        }
        .padding(4)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.white.opacity(hover ? 0.1 : 0)))
        .overlay(alignment: .topTrailing) {
            if hover {
                Button { withAnimation { tray.remove(item) } } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .heavy))
                        .foregroundStyle(.white)
                        .frame(width: 16, height: 16)
                        .background(Circle().fill(Color(white: 0.3)))
                }
                .buttonStyle(PressableStyle())
                .help("Убрать из трея (файл останется на месте)")
            }
        }
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture { NSWorkspace.shared.open(item.url) }
        .modifier(TrayDragSource(url: item.url, enabled: !isSnapshot))
        .help(item.url.path)
    }
}

/// Drag a tray file out to Finder / Mail / Telegram…
private struct TrayDragSource: ViewModifier {
    let url: URL
    let enabled: Bool
    func body(content: Content) -> some View {
        if enabled {
            content.onDrag { NSItemProvider(contentsOf: url) ?? NSItemProvider() }
        } else {
            content
        }
    }
}

private struct TrayDropTarget: ViewModifier {
    @Environment(\.isSnapshot) private var isSnapshot
    @Binding var targeted: Bool
    func body(content: Content) -> some View {
        if isSnapshot {
            content
        } else {
            content.onDrop(of: [.fileURL], isTargeted: $targeted) { providers in
                TrayService.shared.add(providers: providers)
                return true
            }
        }
    }
}

struct TrayCard: View {
    @ObservedObject var tray: TrayService
    var small = false
    @State private var targeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "tray.full.fill").font(.system(size: 12, weight: .bold)).foregroundStyle(.white.opacity(0.6))
                Text(tray.items.isEmpty ? "Трей" : "Трей · \(tray.items.count)")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.6))
                Spacer()
                if !tray.items.isEmpty {
                    Button { withAnimation { tray.clear() } } label: {
                        Text("Очистить")
                            .font(.system(size: 10, weight: .semibold))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Capsule().fill(Color.white.opacity(0.12)))
                    }
                    .buttonStyle(PressableStyle())
                }
            }
            if tray.items.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "tray.and.arrow.down").font(.system(size: 20, weight: .semibold))
                    Text("Перетащи файлы к вырезу")
                        .font(.system(size: 11, weight: .semibold))
                        .multilineTextAlignment(.center)
                }
                .foregroundStyle(.white.opacity(targeted ? 0.9 : 0.4))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(style: StrokeStyle(lineWidth: 1.2, dash: [5, 4]))
                        .foregroundStyle(.white.opacity(targeted ? 0.6 : 0.2))
                )
            } else if small {
                let shown = Array(tray.items.suffix(4))
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 4) {
                    ForEach(shown) { TrayTile(item: $0, size: 34, tray: tray) }
                }
                Spacer(minLength: 0)
            } else {
                let shown = Array(tray.items.suffix(5))
                HStack(alignment: .top, spacing: 2) {
                    ForEach(shown) { TrayTile(item: $0, tray: tray) }
                    if tray.items.count > shown.count {
                        Text("+\(tray.items.count - shown.count)")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(.white.opacity(0.5))
                            .frame(width: 34, height: 40)
                    }
                    Spacer(minLength: 0)
                }
                Spacer(minLength: 0)
            }
        }
        .foregroundStyle(.white)
        .contentShape(Rectangle())
        .modifier(TrayDropTarget(targeted: $targeted))
        .onAppear { tray.prune() }
    }
}
