import AppKit
import Carbon.HIToolbox
import SwiftUI

@MainActor
final class ClipboardPickerModel: ObservableObject {
    @Published var query = ""
    @Published var selection = 0

    var results: [ClipItem] {
        let all = ClipboardService.shared.items
        guard !query.isEmpty else { return all }
        return all.filter { ($0.text ?? "").localizedCaseInsensitiveContains(query) }
    }
}

/// ⌥⇧V: history list at the mouse. A non-activating key panel, so the app you were typing in
/// stays frontmost and receives the paste.
@MainActor
final class ClipboardPicker {
    static let shared = ClipboardPicker()

    private var panel: OverlayPanel?
    private var keyMonitor: Any?
    private var clickMonitor: Any?
    private let model = ClipboardPickerModel()

    func toggle() {
        if panel != nil { close() } else { open() }
    }

    private func open() {
        model.query = ""
        model.selection = 0
        let size = NSSize(width: 380, height: 440)
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        var origin = NSPoint(x: mouse.x - size.width / 2, y: mouse.y - size.height - 12)
        if let f = screen?.visibleFrame {
            origin.x = min(max(origin.x, f.minX + 8), f.maxX - size.width - 8)
            origin.y = min(max(origin.y, f.minY + 8), f.maxY - size.height - 8)
        }
        let p = OverlayPanel(contentRect: NSRect(origin: origin, size: size), styleMask: [.borderless, .nonactivatingPanel],
                             backing: .buffered, defer: false)
        p.allowsKey = true
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.level = .popUpMenu
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.contentView = NSHostingView(rootView: ClipboardPickerView(model: model, clips: ClipboardService.shared) { [weak self] item in
            self?.paste(item)
        })
        p.makeKeyAndOrderFront(nil)
        panel = p

        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            MainActor.assumeIsolated {
                guard let self else { return event }
                return self.handleKey(event) // nil = swallowed
            }
        }
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated { self?.close() }
        }
    }

    func close() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
        keyMonitor = nil
        clickMonitor = nil
        panel?.orderOut(nil)
        panel = nil
    }

    private func handleKey(_ event: NSEvent) -> NSEvent? {
        let results = model.results
        switch Int(event.keyCode) {
        case kVK_Escape:
            close()
        case kVK_DownArrow:
            model.selection = min(model.selection + 1, max(results.count - 1, 0))
        case kVK_UpArrow:
            model.selection = max(model.selection - 1, 0)
        case kVK_Return, kVK_ANSI_KeypadEnter:
            if results.indices.contains(model.selection) { paste(results[model.selection]) }
        case kVK_Delete:
            if !model.query.isEmpty { model.query.removeLast() }
            model.selection = 0
        default:
            let chars = event.charactersIgnoringModifiers ?? ""
            if event.modifierFlags.intersection([.command, .control]).isEmpty, let c = chars.first {
                if model.query.isEmpty, let n = Int(String(c)), (1...9).contains(n), results.count >= n {
                    paste(results[n - 1])
                } else if !c.isNewline {
                    model.query.append(event.characters ?? chars)
                    model.selection = 0
                }
            }
        }
        return nil
    }

    /// Put the item on the clipboard, close, then press ⌘V in the app that is still frontmost.
    private func paste(_ item: ClipItem) {
        ClipboardService.shared.copy(item)
        close()
        guard AXIsProcessTrusted() else {
            AgentsService.shared.notify(title: "Скопировано", subtitle: "Вставь ⌘V (для автовставки нужен Универсальный доступ)")
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
            let src = CGEventSource(stateID: .combinedSessionState)
            let down = CGEvent(keyboardEventSource: src, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: true)
            down?.flags = .maskCommand
            let up = CGEvent(keyboardEventSource: src, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: false)
            up?.flags = .maskCommand
            down?.post(tap: .cgAnnotatedSessionEventTap)
            up?.post(tap: .cgAnnotatedSessionEventTap)
        }
    }
}

// MARK: - Views

struct ClipRow: View {
    let item: ClipItem
    let index: Int
    let selected: Bool
    var compact = false

    var body: some View {
        HStack(spacing: 10) {
            Group {
                switch item.kind {
                case .image:
                    if let image = item.image {
                        Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
                            .frame(width: compact ? 22 : 28, height: compact ? 22 : 28)
                            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    }
                case .link:
                    Image(systemName: "link").font(.system(size: 12, weight: .semibold)).frame(width: compact ? 22 : 28, height: compact ? 22 : 28)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.1)))
                case .text:
                    Image(systemName: "text.alignleft").font(.system(size: 12, weight: .semibold)).frame(width: compact ? 22 : 28, height: compact ? 22 : 28)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.1)))
                }
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(item.preview)
                    .font(.system(size: compact ? 12 : 13, weight: .medium))
                    .lineLimit(compact ? 1 : 2)
                if !compact {
                    Text([item.sourceApp, item.date.formatted(date: .omitted, time: .shortened)].compactMap { $0 }.joined(separator: " · "))
                        .font(.system(size: 10))
                        .foregroundStyle(.white.opacity(0.45))
                }
            }
            Spacer(minLength: 4)
            if index < 9, !compact {
                Text("\(index + 1)")
                    .font(.system(size: 11, weight: .semibold).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.4))
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, compact ? 4 : 6)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.white.opacity(selected ? 0.16 : 0)))
        .contentShape(Rectangle())
    }
}

struct ClipboardPickerView: View {
    @ObservedObject var model: ClipboardPickerModel
    @ObservedObject var clips: ClipboardService
    let onPick: (ClipItem) -> Void
    @Environment(\.isSnapshot) private var isSnapshot

    var body: some View {
        let results = model.results
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "doc.on.clipboard").foregroundStyle(.white.opacity(0.6))
                Text(model.query.isEmpty ? "Буфер обмена — печатай для поиска" : model.query)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white.opacity(model.query.isEmpty ? 0.5 : 1))
                Spacer()
                Text("⌥⇧V").font(.system(size: 11, weight: .semibold)).foregroundStyle(.white.opacity(0.35))
            }
            .padding(.horizontal, 6)
            if results.isEmpty {
                Text(clips.items.isEmpty ? "История пуста — скопируй что-нибудь" : "Ничего не найдено")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.45))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if isSnapshot {
                VStack(spacing: 2) {
                    ForEach(Array(results.prefix(8).enumerated()), id: \.element.id) { i, item in
                        ClipRow(item: item, index: i, selected: i == model.selection)
                    }
                    Spacer(minLength: 0)
                }
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 2) {
                            ForEach(Array(results.enumerated()), id: \.element.id) { i, item in
                                ClipRow(item: item, index: i, selected: i == model.selection)
                                    .id(i)
                                    .onTapGesture { onPick(item) }
                            }
                        }
                    }
                    .onChange(of: model.selection) { _, s in withAnimation(.easeOut(duration: 0.12)) { proxy.scrollTo(s) } }
                }
            }
        }
        .foregroundStyle(.white)
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color(white: 0.08).opacity(0.97)))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Color.white.opacity(0.12)))
        .environment(\.colorScheme, .dark)
    }
}

/// Shelf widget: recent clips, click to copy back.
struct ClipboardCard: View {
    @ObservedObject var clips: ClipboardService
    var small = false
    @State private var copied: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: "doc.on.clipboard").font(.system(size: 12, weight: .bold)).foregroundStyle(.white.opacity(0.6))
                Text("Буфер").font(.system(size: 13, weight: .semibold)).foregroundStyle(.white.opacity(0.6))
                Spacer()
                if !small {
                    Text("⌥⇧V").font(.system(size: 11, weight: .semibold)).foregroundStyle(.white.opacity(0.35))
                }
            }
            if clips.items.isEmpty {
                Text("Пока пусто")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.45))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(spacing: 2) {
                    ForEach(Array(clips.items.prefix(small ? 4 : 4).enumerated()), id: \.element.id) { i, item in
                        ClipRow(item: item, index: i, selected: copied == item.id, compact: true)
                            .onTapGesture {
                                clips.copy(item)
                                withAnimation { copied = item.id }
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { withAnimation { copied = nil } }
                            }
                    }
                }
                Spacer(minLength: 0)
            }
        }
        .foregroundStyle(.white)
    }
}
