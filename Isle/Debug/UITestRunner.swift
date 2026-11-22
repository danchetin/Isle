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
        model.widgets = [.nowPlaying, .calendar, .weather]
        model.sizes = [:]
        model.expanded = true
        model.beginEditing()

        let size = CGSize(width: 1300, height: 480)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.alphaValue = 0
        window.contentView = FirstMouseHostingView(rootView: NotchRootView(model: model, spotify: SpotifyController.shared).frame(width: size.width, height: size.height))
        window.orderFrontRegardless()

        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 800_000_000)

            // Geometry mirrors NotchMetrics / ShelfView.
            let body = NotchMetrics.shelfBody(model: model)
            let cardTop = model.notchSize.height + 6
            var cardX = size.width / 2 - body.width / 2 + NotchMetrics.shelfPad
            let first = model.draft[0]
            let firstWidth = model.width(of: first)

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
                print("\(label): draft=\(model.draft.map(\.rawValue)) sizes=\(model.draftSizes.map { "\($0.key.rawValue)=\($0.value.rawValue)" }.sorted())")
            }

            print("before: draft=\(model.draft.map(\.rawValue)) firstWidth=\(firstWidth)")
            // Control: palette tile "Календарь" (second tile) should remove the calendar.
            await click("after palette click (control)", x: cardX + 72 + 31, yFromTop: cardTop + NotchMetrics.cardHeight + 14 + 28)
            await click("after palette click again", x: cardX + 72 + 31, yFromTop: cardTop + NotchMetrics.cardHeight + 14 + 28)
            cardX = size.width / 2 - NotchMetrics.shelfBody(model: model).width / 2 + NotchMetrics.shelfPad
            // Resize button: bottom-left corner of the first card.
            await click("after resize click", x: cardX, yFromTop: cardTop + NotchMetrics.cardHeight)
            // Minus button: top-right corner of the (now resized) first card.
            // The card row is centered inside the shelf when it's narrower than the palette.
            let row = model.draft.map(model.width(of:)).reduce(0, +) + NotchMetrics.cardGap * CGFloat(model.draft.count - 1)
            cardX = size.width / 2 - row / 2
            await click("after minus click", x: cardX + model.width(of: first), yFromTop: cardTop)
            exit(0)
        }
        app.run()
    }
}
