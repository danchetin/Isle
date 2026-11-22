import AppKit
import SwiftUI

/// `Isle --uitest`: opens the shelf editor in an invisible window and clicks the editor
/// buttons with synthetic in-process mouse events, then prints what changed.
/// Checks real SwiftUI hit-testing without needing to drive the screen.
@MainActor
enum UITestRunner {
    static func run() {
        Prefs.register()
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)

        let model = NotchModel()
        model.notchSize = CGSize(width: 185, height: 32)
        model.pages = [[.nowPlaying, .calendar, .weather]]
        model.page = 0
        model.sizes = [:]
        model.expanded = true
        model.beginEditing()

        let size = CGSize(width: 1400, height: 520)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.alphaValue = 0
        window.contentView = FirstMouseHostingView(rootView: NotchRootView(model: model, spotify: SpotifyController.shared).frame(width: size.width, height: size.height))
        window.orderFrontRegardless()

        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 800_000_000)

            // Geometry mirrors NotchMetrics / ShelfView.
            let cardTop = model.notchSize.height + 6
            /// Left edge of the card row (centered inside the shelf when narrower than the palette).
            @MainActor func rowX() -> CGFloat {
                let row = model.draft.map(model.width(of:)).reduce(0, +) + NotchMetrics.cardGap * CGFloat(max(model.draft.count - 1, 0))
                let inner = NotchMetrics.shelfBody(model: model).width - NotchMetrics.shelfPad * 2
                return size.width / 2 - inner / 2 + max(0, (inner - row) / 2)
            }
            /// Center of palette tile i (tiles are 58 wide, 10 apart, from the shelf's left edge).
            @MainActor func tileX(_ i: Int) -> CGFloat {
                size.width / 2 - NotchMetrics.shelfBody(model: model).width / 2 + NotchMetrics.shelfPad + CGFloat(i) * 68 + 29
            }
            let tileY = cardTop + NotchMetrics.cardHeight + 14 + 28
            let first = model.draft[0]

            @MainActor func click(_ label: String, x: CGFloat, yFromTop: CGFloat) async {
                let p = NSPoint(x: x, y: size.height - yFromTop)
                for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                    if let e = NSEvent.mouseEvent(with: type, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                  windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) {
                        window.sendEvent(e)
                    }
                    try? await Task.sleep(nanoseconds: 60_000_000)
                }
                try? await Task.sleep(nanoseconds: 400_000_000)
                print("\(label): page=\(model.page + 1)/\(model.pageCount) pages=\(model.draftPages.map { $0.map(\.rawValue) }) sizes=\(model.draftSizes.map { "\($0.key.rawValue)=\($0.value.rawValue)" }.sorted())")
            }

            print("before: pages=\(model.draftPages.map { $0.map(\.rawValue) })")
            // Palette tile "Календарь" (second) removes the calendar from this page.
            await click("palette remove calendar", x: tileX(1), yFromTop: tileY)
            // Resize button: bottom-left corner of the first card.
            await click("resize first card", x: rowX(), yFromTop: cardTop + NotchMetrics.cardHeight)
            // Minus button: top-right corner of the first card.
            await click("minus first card", x: rowX() + model.width(of: first), yFromTop: cardTop)

            // Pages: new page, then the weather tile (on page 1) moves here.
            withAnimation { model.addPage() }
            try? await Task.sleep(nanoseconds: 400_000_000)
            print("after addPage: page=\(model.page + 1)/\(model.pageCount)")
            await click("palette weather → page 2", x: tileX(2), yFromTop: cardTop + NotchMetrics.emptyHeight + 14 + 28)
            model.commitEditing(persist: false)
            print("committed pages: \(model.pages.map { $0.map(\.rawValue) })")
            model.beginEditing()

            // Square System card: style button at its bottom-right corner.
            let savedStyle = SmallStatsStyle.current
            SmallStatsStyle.current = .single
            model.draft = [.systemStats]
            model.draftSizes[.systemStats] = .small
            try? await Task.sleep(nanoseconds: 500_000_000)
            let side = NotchMetrics.cardHeight
            await click("style click", x: size.width / 2, yFromTop: cardTop + side + 4)
            print("style now: \(SmallStatsStyle.current.rawValue)")
            SmallStatsStyle.current = savedStyle
            exit(0)
        }
        app.run()
    }
}
