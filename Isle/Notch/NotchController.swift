import AppKit
import SwiftUI

@MainActor
final class NotchModel: ObservableObject {
    @Published var expanded = false
    @Published var notchSize = CGSize(width: 185, height: 32)
    @Published var hasNotch = true
    /// Mouse is on the menu bar next to the notch: shrink back to the notch so menu items show.
    @Published var menuReveal = false
    /// Volume / brightness HUD currently shown in the collapsed island.
    @Published var hud: HUDInfo?

    @Published var widgets = ShelfWidget.load()
    @Published var editing = false
    @Published var draft: [ShelfWidget] = []

    var visibleWidgets: [ShelfWidget] { editing ? draft : widgets }

    @Published var sizes = WidgetSize.load()
    @Published var draftSizes: [ShelfWidget: WidgetSize] = [:]

    func size(of widget: ShelfWidget) -> WidgetSize {
        (editing ? draftSizes : sizes)[widget] ?? .medium
    }

    func width(of widget: ShelfWidget) -> CGFloat {
        size(of: widget) == .small ? NotchMetrics.cardHeight : widget.width
    }

    func toggleSize(_ widget: ShelfWidget) {
        draftSizes[widget] = size(of: widget) == .small ? .medium : .small
    }

    /// Widest the shelf may get on this screen.
    @Published var maxBodyWidth: CGFloat = 1400

    func canAdd(_ widget: ShelfWidget) -> Bool {
        let list = draft + [widget]
        let width = list.map(width(of:)).reduce(0, +) + NotchMetrics.cardGap * CGFloat(list.count - 1) + NotchMetrics.shelfPad * 2
        return width <= maxBodyWidth
    }

    func beginEditing() {
        draft = widgets
        draftSizes = sizes
        editing = true
    }

    func commitEditing() {
        widgets = draft
        sizes = draftSizes
        ShelfWidget.save(widgets)
        WidgetSize.save(sizes)
        editing = false
    }

    func cancelEditing() {
        editing = false
    }
}

enum NotchMetrics {
    /// Concave "ear" radius where the island meets the top edge.
    static let ear: CGFloat = 8
    /// Width added on each side of the notch by the volume / brightness HUD.
    static let hudSide: CGFloat = 100
    static let panelSize = CGSize(width: 1200, height: 520)

    static let cardHeight: CGFloat = 168
    static let emptyHeight: CGFloat = 90
    static let cardGap: CGFloat = 12
    static let shelfPad: CGFloat = 16
    static let paletteHeight: CGFloat = 86
    /// Tab bar pill below the island (pill + gap).
    static let tabBarHeight: CGFloat = 50

    @MainActor
    static func shelfBody(model: NotchModel) -> CGSize {
        let list = model.visibleWidgets
        var w = list.map(model.width(of:)).reduce(0, +) + cardGap * CGFloat(max(0, list.count - 1)) + shelfPad * 2
        if list.isEmpty { w = 380 }
        if model.editing { w = max(w, 640) }
        var h = model.notchSize.height + 6 + (list.isEmpty ? emptyHeight : cardHeight) + shelfPad
        if model.editing { h += paletteHeight }
        return CGSize(width: w, height: h)
    }

    /// Width added on each side of the notch by the collapsed live activity.
    static func liveSide(notchHeight h: CGFloat) -> CGFloat { h + 10 }

    @MainActor
    static func isLive(model: NotchModel, playing: Bool, hasTrack: Bool) -> Bool {
        playing && hasTrack && !model.menuReveal
    }

    /// Full frame of the black shape, ears included.
    @MainActor
    static func size(model: NotchModel, playing: Bool, hasTrack: Bool) -> CGSize {
        let n = model.notchSize
        if model.expanded {
            let body = shelfBody(model: model)
            return CGSize(width: body.width + ear * 2, height: body.height)
        }
        if model.hud != nil {
            return CGSize(width: n.width + hudSide * 2 + ear * 2, height: n.height)
        }
        if isLive(model: model, playing: playing, hasTrack: hasTrack) {
            return CGSize(width: n.width + liveSide(notchHeight: n.height) * 2 + ear * 2, height: n.height)
        }
        return CGSize(width: n.width + ear * 2, height: n.height)
    }
}

/// Transparent panel over the notch. Ignores the mouse while collapsed (menu bar stays
/// clickable); hover is tracked with event monitors and expands it.
@MainActor
final class NotchController {
    private let spotify: SpotifyController
    let model = NotchModel()
    private var panel: OverlayPanel?
    private var monitors: [Any] = []
    private var screenObserver: NSObjectProtocol?
    private var collapseWork: DispatchWorkItem?

    init(spotify: SpotifyController) {
        self.spotify = spotify
    }

    private var screen: NSScreen? {
        NSScreen.screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.screens.first
    }

    func setEnabled(_ enabled: Bool) {
        if enabled { start() } else { stop() }
    }

    func start() {
        guard Prefs.notchEnabled, panel == nil, let screen else { return }
        updateGeometry(screen)

        let p = OverlayPanel(
            contentRect: frame(for: screen),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.isMovable = false
        p.hidesOnDeactivate = false
        p.ignoresMouseEvents = true
        p.acceptsMouseMovedEvents = true
        p.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)
        p.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]

        let host = FirstMouseHostingView(rootView: NotchRootView(model: model, spotify: spotify))
        host.sizingOptions = []
        p.contentView = host
        p.orderFrontRegardless()
        panel = p

        let onMove: (NSEvent) -> Void = { [weak self] _ in
            MainActor.assumeIsolated { self?.mouseMoved() }
        }
        if let g = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged], handler: onMove) {
            monitors.append(g)
        }
        if let l = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged], handler: { e in
            onMove(e)
            return e
        }) {
            monitors.append(l)
        }
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.reposition() }
        }
    }

    func stop() {
        monitors.forEach { NSEvent.removeMonitor($0) }
        monitors = []
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        screenObserver = nil
        panel?.orderOut(nil)
        panel = nil
        model.expanded = false
    }

    private func reposition() {
        guard let screen, let panel else { return }
        updateGeometry(screen)
        panel.setFrame(frame(for: screen), display: true)
    }

    private func frame(for s: NSScreen) -> NSRect {
        let size = NSSize(width: s.frame.width, height: NotchMetrics.panelSize.height)
        return NSRect(x: s.frame.midX - size.width / 2, y: s.frame.maxY - size.height, width: size.width, height: size.height)
    }

    private func updateGeometry(_ s: NSScreen) {
        model.maxBodyWidth = s.frame.width - 40
        let top = s.safeAreaInsets.top
        if top > 0, let left = s.auxiliaryTopLeftArea, let right = s.auxiliaryTopRightArea {
            model.hasNotch = true
            model.notchSize = CGSize(width: s.frame.width - left.width - right.width, height: top)
        } else {
            model.hasNotch = false
            model.notchSize = CGSize(width: 180, height: max(24, s.frame.maxY - s.visibleFrame.maxY))
        }
    }

    // MARK: - Hover

    /// The physical notch (camera housing). Only hovering here opens the player,
    /// so the menu items beside it stay usable.
    private func notchRect() -> NSRect {
        guard let screen else { return .zero }
        let n = model.notchSize
        return NSRect(x: screen.frame.midX - n.width / 2, y: screen.frame.maxY - n.height, width: n.width, height: n.height)
            .insetBy(dx: -2, dy: -2)
    }

    /// Area the expanded player occupies; leaving it collapses the player.
    private func expandedRect() -> NSRect {
        guard let screen else { return .zero }
        let size = NotchMetrics.size(model: model, playing: spotify.isPlaying, hasTrack: spotify.track != nil)
        let bodyWidth = size.width - NotchMetrics.ear * 2
        let height = size.height + NotchMetrics.tabBarHeight
        return NSRect(x: screen.frame.midX - bodyWidth / 2, y: screen.frame.maxY - height, width: bodyWidth, height: height)
            .insetBy(dx: -14, dy: -14)
    }

    /// Menu bar strip covered by the live activity's sides (plus some approach margin).
    private func menuRevealRect() -> NSRect {
        guard let screen else { return .zero }
        let n = model.notchSize
        let side = NotchMetrics.liveSide(notchHeight: n.height) + NotchMetrics.ear + 60
        return NSRect(x: screen.frame.midX - n.width / 2 - side, y: screen.frame.maxY - n.height - 2,
                      width: n.width + side * 2, height: n.height + 2)
    }

    private func mouseMoved() {
        let p = NSEvent.mouseLocation
        let overNotch = notchRect().contains(p)

        let reveal = !model.expanded && !overNotch && menuRevealRect().contains(p)
        if reveal != model.menuReveal {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { model.menuReveal = reveal }
        }

        if model.expanded ? expandedRect().contains(p) : overNotch {
            collapseWork?.cancel()
            collapseWork = nil
            if !model.expanded { setExpanded(true) }
        } else if model.expanded, collapseWork == nil {
            let work = DispatchWorkItem { [weak self] in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.collapseWork = nil
                    if !self.expandedRect().contains(NSEvent.mouseLocation) { self.setExpanded(false) }
                }
            }
            collapseWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: work)
        }
    }

    private func setExpanded(_ expanded: Bool) {
        if !expanded, model.editing { return } // stay open while editing; ✓ / ✕ closes the editor
        withAnimation(.spring(response: 0.42, dampingFraction: 0.8)) {
            model.expanded = expanded
        }
        panel?.ignoresMouseEvents = !expanded
    }
}
