import AppKit
import CoreImage
import ImageIO
import SwiftUI
import UniformTypeIdentifiers
import Vision

/// Drop images on the notch → subject cut out on-device → PNG(s) on the clipboard.
/// Nothing is written to disk.
@MainActor
enum BackgroundRemover {
    private static let context = CIContext(options: [.cacheIntermediates: false])

    static func handle(_ providers: [NSItemProvider]) {
        Task {
            var images: [CGImage] = []
            for p in providers.prefix(10) {
                if let url = await loadURL(p), let cg = loadImage(at: url) {
                    images.append(cg)
                } else if let cg = await loadDroppedImage(p) {
                    images.append(cg)
                }
            }
            guard !images.isEmpty else {
                AgentsService.shared.notify(title: "Нужна картинка", subtitle: "Перетащи фото или PNG/JPG/HEIC")
                return
            }
            let pngs = await Task.detached(priority: .userInitiated) {
                images.compactMap { BackgroundRemover.cutoutPNG($0) }
            }.value
            guard !pngs.isEmpty else {
                AgentsService.shared.notify(title: "Не нашёл объект", subtitle: "Попробуй фото с чётким объектом")
                return
            }
            copyToPasteboard(pngs)
            AgentsService.shared.notify(
                title: "Фон убран",
                subtitle: pngs.count == 1 ? "PNG в буфере обмена — вставляй ⌘V" : "\(pngs.count) PNG в буфере обмена"
            )
        }
    }

    private static func loadURL(_ provider: NSItemProvider) async -> URL? {
        guard provider.canLoadObject(ofClass: NSURL.self) else { return nil }
        return await withCheckedContinuation { cont in
            _ = provider.loadObject(ofClass: NSURL.self) { obj, _ in
                cont.resume(returning: (obj as? NSURL).map { $0 as URL })
            }
        }
    }

    private static func loadDroppedImage(_ provider: NSItemProvider) async -> CGImage? {
        guard provider.canLoadObject(ofClass: NSImage.self) else { return nil }
        let image: NSImage? = await withCheckedContinuation { cont in
            _ = provider.loadObject(ofClass: NSImage.self) { obj, _ in cont.resume(returning: obj as? NSImage) }
        }
        return image?.cgImage(forProposedRect: nil, context: nil, hints: nil)
    }

    /// Decoded with EXIF orientation applied; capped at 4096 px.
    nonisolated static func loadImage(at url: URL) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: 4096,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
    }

    /// Subject on a transparent background, cropped to the subject.
    nonisolated static func cutoutPNG(_ cg: CGImage) -> Data? {
        let request = VNGenerateForegroundInstanceMaskRequest()
        let handler = VNImageRequestHandler(cgImage: cg, options: [:])
        do { try handler.perform([request]) } catch { return nil }
        guard let obs = request.results?.first, !obs.allInstances.isEmpty,
              let buffer = try? obs.generateMaskedImage(ofInstances: obs.allInstances, from: handler, croppedToInstancesExtent: true)
        else { return nil }
        let ci = CIImage(cvPixelBuffer: buffer)
        guard let out = CIContext(options: [.cacheIntermediates: false]).createCGImage(ci, from: ci.extent) else { return nil }
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, out, nil)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return data as Data
    }

    private static func copyToPasteboard(_ pngs: [Data]) {
        let items = pngs.map { png -> NSPasteboardItem in
            let item = NSPasteboardItem()
            item.setData(png, forType: .png)
            if let tiff = NSBitmapImageRep(data: png)?.tiffRepresentation { item.setData(tiff, forType: .tiff) }
            return item
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects(items)
    }
}

/// What each drop target does.
enum DropAction: CaseIterable {
    case tray, removeBackground, uninstall

    var symbol: String {
        switch self {
        case .tray: "tray.and.arrow.down.fill"
        case .removeBackground: "wand.and.stars"
        case .uninstall: "trash"
        }
    }

    var title: String {
        switch self {
        case .tray: "В трей"
        case .removeBackground: "Убрать фон"
        case .uninstall: "Удалить приложение"
        }
    }

    var subtitle: String {
        switch self {
        case .tray: "Ссылка на файл, сам файл не двигается"
        case .removeBackground: "PNG без фона — в буфер обмена"
        case .uninstall: "Покажу файлы — уберёшь в Корзину"
        }
    }

    /// Targets shown for what is being dragged.
    static func targets(for kind: DropKind) -> [DropAction] {
        switch kind {
        case .file: [.tray]
        case .image: [.tray, .removeBackground]
        case .imageData: [.removeBackground]
        case .app: [.tray, .uninstall]
        }
    }
}

/// The island while files are dragged near it: one target per action.
struct NotchDropZoneView: View {
    @ObservedObject var model: NotchModel

    var body: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: model.notchSize.height)
            HStack(spacing: 10) {
                ForEach(Array(DropAction.targets(for: model.dropKind).enumerated()), id: \.offset) { i, action in
                    DropTargetTile(action: action, model: model, highlighted: model.dropTargeted && i == 0)
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 6)
            .padding(.bottom, 14)
        }
    }
}

private struct DropTargetTile: View {
    let action: DropAction
    @ObservedObject var model: NotchModel
    /// Snapshot-only highlight.
    let highlighted: Bool
    @State private var targeted = false
    @Environment(\.isSnapshot) private var isSnapshot

    var body: some View {
        let on = targeted || highlighted
        HStack(spacing: 12) {
            Image(systemName: action.symbol)
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(on ? Color.accentColor : .white)
                .symbolEffect(.bounce, value: targeted)
            VStack(alignment: .leading, spacing: 2) {
                Text(action.title)
                    .font(.system(size: 14, weight: .semibold))
                Text(action.subtitle)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.white.opacity(0.55))
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color.white.opacity(on ? 0.12 : 0.05)))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [6, 5]))
                .foregroundStyle(on ? Color.accentColor : Color.white.opacity(0.35))
        )
        .contentShape(Rectangle())
        .modifier(DropHandler(action: action, model: model, targeted: $targeted, enabled: !isSnapshot))
        .animation(.easeOut(duration: 0.15), value: on)
    }
}

/// onDrop isn't drawable by ImageRenderer, so snapshots skip it.
private struct DropHandler: ViewModifier {
    let action: DropAction
    @ObservedObject var model: NotchModel
    @Binding var targeted: Bool
    let enabled: Bool

    func body(content: Content) -> some View {
        if !enabled {
            content
        } else {
            content.onDrop(of: [.fileURL, .image], isTargeted: $targeted) { providers in
                switch action {
                case .tray:
                    TrayService.shared.add(providers: providers)
                    AgentsService.shared.notify(title: "В трее", subtitle: providers.count == 1 ? "1 файл" : "\(providers.count) файлов")
                case .removeBackground:
                    BackgroundRemover.handle(providers)
                case .uninstall:
                    for p in providers.prefix(3) {
                        _ = p.loadObject(ofClass: NSURL.self) { obj, _ in
                            guard let url = (obj as? NSURL).map({ $0 as URL }), url.pathExtension == "app" else { return }
                            DispatchQueue.main.async { MainActor.assumeIsolated { CleanerWindows.open(app: url) } }
                        }
                    }
                }
                withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) { model.dropMode = false }
                return true
            }
        }
    }
}
