import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers

enum DropKind { case file, image, imageData, app }

@MainActor
final class NotchModel: ObservableObject {
    @Published var expanded = false
    @Published var notchSize = CGSize(width: 185, height: 32)
    @Published var hasNotch = true
    /// Mouse is on the menu bar next to the notch: shrink back to the notch so menu items show.
    @Published var menuReveal = false
    /// Volume / brightness HUD currently shown in the collapsed island.
    @Published var hud: HUDInfo?
    /// A file / image is being dragged near the notch: show the drop zone.
    @Published var dropMode = false
    @Published var dropTargeted = false
    /// What is being dragged: apps open the Cleaner, anything else goes to background removal.
    @Published var dropKind: DropKind = .file

    // MARK: Shelf pages (scroll / swipe between them, like Control Center)

    @Published var pages: [[ShelfWidget]] = ShelfPages.load()
    @Published var page = 0
    /// +1 when moving forward, -1 backward (which way pages slide).
    @Published var pageDirection = 1
    @Published var editing = false
    @Published var draftPages: [[ShelfWidget]] = [[]]

    var pageCount: Int { max(1, (editing ? draftPages : pages).count) }

    /// Widgets of the current page.
    var widgets: [ShelfWidget] {
        get { pages.indices.contains(page) ? pages[page] : [] }
        set {
            if pages.isEmpty { pages = [newValue] } else { pages[min(page, pages.count - 1)] = newValue }
        }
    }

    /// Current page while editing.
    var draft: [ShelfWidget] {
        get { draftPages.indices.contains(page) ? draftPages[page] : [] }
        set { if draftPages.indices.contains(page) { draftPages[page] = newValue } }
    }

    var visibleWidgets: [ShelfWidget] { editing ? draft : widgets }

    /// Two steps: set the direction first (no animation) so the outgoing page re-renders
    /// with the right slide, then change the page animated on the next turn of the run loop.
    func goToPage(_ target: Int) {
        let p = max(0, min(target, pageCount - 1))
        guard p != page else { return }
        pageDirection = p > page ? 1 : -1
        DispatchQueue.main.async {
            withAnimation(.spring(response: 0.42, dampingFraction: 0.88)) { self.page = p }
        }
    }

    /// Page (while editing) a widget sits on, if any.
    func pageOf(_ widget: ShelfWidget) -> Int? {
        draftPages.firstIndex { $0.contains(widget) }
    }

    /// Palette tap: remove from this page, or bring here (moving it off another page).
    func togglePalette(_ widget: ShelfWidget) {
        if draft.contains(widget) {
            draft.removeAll { $0 == widget }
            return
        }
        guard canAdd(widget) else { return }
        if let other = pageOf(widget) { draftPages[other].removeAll { $0 == widget } }
        draft.append(widget)
    }

    func addPage() {
        draftPages.append([])
        goToPage(draftPages.count - 1)
    }

    func deleteCurrentPage() {
        guard draftPages.count > 1 else { return }
        draftPages.remove(at: page)
        pageDirection = -1
        page = min(page, draftPages.count - 1)
    }

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
        draftPages = pages.isEmpty ? [[]] : pages
        draftSizes = sizes
        editing = true
    }

    /// `persist: false` for tests: never touch the user's saved layout.
    func commitEditing(persist: Bool = true) {
        let kept = draftPages.filter { !$0.isEmpty }
        pages = kept.isEmpty ? [[]] : kept
        sizes = draftSizes
        if persist {
            ShelfPages.save(pages)
            WidgetSize.save(sizes)
        }
        editing = false
        page = min(page, pages.count - 1)
    }

    func cancelEditing() {
        editing = false
        page = min(page, max(pages.count - 1, 0))
    }
}

enum NotchMetrics {
    /// Concave "ear" radius where the island meets the top edge.
    static let ear: CGFloat = 8
    /// Width added on each side of the notch by the volume / brightness HUD.
    static let hudSide: CGFloat = 100
    /// Agent toast: wider island grown downward.
    static let toastSide: CGFloat = 110
    static let toastExtraHeight: CGFloat = 44
    static let dropSize = CGSize(width: 420, height: 104)
    static let panelSize = CGSize(width: 1200, height: 520)

    static let cardHeight: CGFloat = 168
    static let emptyHeight: CGFloat = 90
    static let cardGap: CGFloat = 12
    static let shelfPad: CGFloat = 16
    /// Two rows of widget tiles + spacing.
    static let paletteHeight: CGFloat = 150
    /// Tab bar pill below the island (pill + gap).
    static let tabBarHeight: CGFloat = 50

    @MainActor
    static func shelfBody(model: NotchModel) -> CGSize {
        let list = model.visibleWidgets
        var w = list.map(model.width(of:)).reduce(0, +) + cardGap * CGFloat(max(0, list.count - 1)) + shelfPad * 2
        if list.isEmpty { w = 380 }
        if model.editing { w = max(w, 820) }
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
        if model.dropMode {
            let targets = CGFloat(DropAction.targets(for: model.dropKind).count)
            return CGSize(width: 40 + targets * 280 + (targets - 1) * 10 + ear * 2, height: n.height + dropSize.height)
        }
        if model.hud != nil {
            return CGSize(width: n.width + hudSide * 2 + ear * 2, height: n.height)
        }
        if AgentsService.shared.toast != nil {
            return CGSize(width: n.width + toastSide * 2 + ear * 2, height: n.height + toastExtraHeight)
        }
        if AgentsService.shared.active != nil {
            return CGSize(width: n.width + liveSide(notchHeight: n.height) * 2 + ear * 2, height: n.height)
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
    private var cancellables = Set<AnyCancellable>()
    private var scrollAccum: CGFloat = 0
    private var scrollLocked = false
    private var scrollIdle: DispatchWorkItem?
    private var dragChangeCount = NSPasteboard(name: .drag).changeCount
    private var fileDrag = false

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

        // The panel takes clicks only while the shelf or the drop zone is open. Derived from
        // state so no code path (e.g. a drop closing the zone from the view) can leave it
        // swallowing clicks across the top of the screen.
        model.$expanded.combineLatest(model.$dropMode)
            .sink { [weak p] expanded, drop in p?.ignoresMouseEvents = !(expanded || drop) }
            .store(in: &cancellables)

        let onMove: (NSEvent) -> Void = { [weak self] event in
            let type = event.type
            MainActor.assumeIsolated { self?.handleMouse(type) }
        }
        let mask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .leftMouseDown, .leftMouseUp]
        if let g = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: onMove) {
            monitors.append(g)
        }
        if let l = NSEvent.addLocalMonitorForEvents(matching: mask.union(.scrollWheel), handler: { [weak self] e in
            if e.type == .scrollWheel {
                let dx = e.scrollingDeltaX, dy = e.scrollingDeltaY, precise = e.hasPreciseScrollingDeltas
                MainActor.assumeIsolated { self?.handleScroll(dx: dx, dy: dy, precise: precise) }
                return e
            }
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

    // MARK: - Paging (scroll wheel / two-finger swipe)

    private func handleScroll(dx: CGFloat, dy: CGFloat, precise: Bool) {
        guard model.expanded, model.pageCount > 1 else { return }
        // Unlock once the gesture (incl. momentum) has been quiet for a moment.
        scrollIdle?.cancel()
        let idle = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                self?.scrollLocked = false
                self?.scrollAccum = 0
            }
        }
        scrollIdle = idle
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: idle)
        guard !scrollLocked else { return }

        scrollAccum += abs(dx) > abs(dy) ? dx : dy
        let threshold: CGFloat = precise ? 30 : 0.9
        guard abs(scrollAccum) >= threshold else { return }
        let forward = scrollAccum < 0 // wheel down / swipe up or left → next page
        scrollAccum = 0
        scrollLocked = true
        model.goToPage(model.page + (forward ? 1 : -1))
    }

    // MARK: - File drag → drop zone

    private func handleMouse(_ type: NSEvent.EventType) {
        switch type {
        case .leftMouseDown:
            dragChangeCount = NSPasteboard(name: .drag).changeCount
            fileDrag = false
        case .leftMouseDragged:
            if !fileDrag {
                let pb = NSPasteboard(name: .drag)
                let types = pb.types ?? []
                if pb.changeCount != dragChangeCount,
                   types.contains(.fileURL) || types.contains(.png) || types.contains(.tiff) {
                    fileDrag = true
                    let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
                    if urls.isEmpty {
                        model.dropKind = .imageData
                    } else if urls.allSatisfy({ $0.pathExtension == "app" }) {
                        model.dropKind = .app
                    } else if urls.allSatisfy({ UTType(filenameExtension: $0.pathExtension)?.conforms(to: .image) == true }) {
                        model.dropKind = .image
                    } else {
                        model.dropKind = .file
                    }
                }
            }
            if fileDrag { dragMoved() } else { mouseMoved() }
        case .leftMouseUp:
            if fileDrag || model.dropMode {
                fileDrag = false
                // Let the drop land first, then fold the zone away.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                    MainActor.assumeIsolated { self?.setDropMode(false) }
                }
            }
        default:
            mouseMoved()
        }
    }

    /// Where approaching with a file opens the drop zone: the notch plus a generous margin.
    private func dropActivationRect() -> NSRect {
        notchRect().insetBy(dx: -160, dy: -70)
    }

    private func dropZoneRect() -> NSRect {
        guard let screen else { return .zero }
        let targets = CGFloat(DropAction.targets(for: model.dropKind).count)
        let size = CGSize(width: 40 + targets * 280 + (targets - 1) * 10, height: NotchMetrics.dropSize.height)
        let height = model.notchSize.height + size.height
        return NSRect(x: screen.frame.midX - size.width / 2, y: screen.frame.maxY - height, width: size.width, height: height)
            .insetBy(dx: -60, dy: -50)
    }

    private func dragMoved() {
        let p = NSEvent.mouseLocation
        if !model.dropMode, !model.expanded, dropActivationRect().contains(p) {
            setDropMode(true)
        } else if model.dropMode, !dropZoneRect().contains(p) {
            setDropMode(false)
        }
    }

    private func setDropMode(_ on: Bool) {
        guard model.dropMode != on else { return }
        withAnimation(.spring(response: 0.38, dampingFraction: 0.8)) {
            model.dropMode = on
            if !on { model.dropTargeted = false }
        }
        panel?.ignoresMouseEvents = !(on || model.expanded)
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
        if model.dropMode { return }
        withAnimation(.spring(response: 0.42, dampingFraction: 0.8)) {
            model.expanded = expanded
        }
        panel?.ignoresMouseEvents = !(expanded || model.dropMode)
    }
}
