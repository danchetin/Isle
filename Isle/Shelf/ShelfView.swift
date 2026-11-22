import SwiftUI

/// Expanded notch: a row of widgets, plus the editor (dashed cards, remove, drag to reorder,
/// palette to add) when editing.
struct ShelfView: View {
    @ObservedObject var model: NotchModel
    @ObservedObject var spotify: SpotifyController
    @State private var dragItem: ShelfWidget?
    @State private var dragOffset: CGFloat = 0
    /// Layout shift already absorbed by swaps during the current drag.
    @State private var dragConsumed: CGFloat = 0
    @AppStorage(SmallStatsStyle.key) private var smallStatsStyle = SmallStatsStyle.single.rawValue

    var body: some View {
        let list = model.visibleWidgets
        VStack(spacing: 0) {
            Color.clear.frame(height: model.notchSize.height + 6)
            pager(current: list)
            if model.editing {
                ShelfPalette(model: model)
                    .padding(.top, 14)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
        .padding(.horizontal, NotchMetrics.shelfPad)
        .padding(.bottom, NotchMetrics.shelfPad)
    }

    /// All pages stacked in one vertical strip; the strip slides so the current page shows.
    /// Next page sits below, previous above — the motion always follows the scroll.
    private func pager(current: [ShelfWidget]) -> some View {
        let all = model.editing ? model.draftPages : model.pages
        let step = NotchMetrics.cardHeight + 40
        return ZStack(alignment: .top) {
            ForEach(Array(all.indices), id: \.self) { i in
                pageContent(i == model.page ? current : all[i])
                    .offset(y: CGFloat(i - model.page) * step)
                    .opacity(i == model.page ? 1 : 0.35)
                    .allowsHitTesting(i == model.page)
            }
        }
        .frame(height: current.isEmpty ? NotchMetrics.emptyHeight : NotchMetrics.cardHeight, alignment: .top)
        .frame(maxWidth: .infinity)
        .clipped()
    }

    @ViewBuilder
    private func pageContent(_ list: [ShelfWidget]) -> some View {
            if list.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "square.grid.2x2")
                        .font(.system(size: 20, weight: .semibold))
                    Text(model.editing ? "Пустая страница — добавь виджеты из палитры" : "Пустая страница")
                        .font(.system(size: 12, weight: .semibold))
                }
                .foregroundStyle(.white.opacity(0.5))
                .frame(maxWidth: .infinity)
                .frame(height: NotchMetrics.emptyHeight)
            } else {
                HStack(alignment: .top, spacing: NotchMetrics.cardGap) {
                    ForEach(list) { widget in
                        card(widget, small: model.size(of: widget) == .small)
                            .frame(width: model.width(of: widget), height: NotchMetrics.cardHeight)
                            .modifier(EditDecoration(
                                editing: model.editing,
                                small: model.size(of: widget) == .small,
                                onRemove: {
                                    withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                                        model.draft.removeAll { $0 == widget }
                                    }
                                },
                                onResize: {
                                    withAnimation(.spring(response: 0.4, dampingFraction: 0.82)) { model.toggleSize(widget) }
                                },
                                variant: variant(for: widget)
                            ))
                            .offset(x: dragItem == widget ? dragOffset : 0)
                            .scaleEffect(dragItem == widget ? 1.03 : 1)
                            .shadow(color: .black.opacity(dragItem == widget ? 0.5 : 0), radius: 14, y: 6)
                            .zIndex(dragItem == widget ? 1 : 0)
                            // The dragged card follows the pointer 1:1; only its neighbours animate.
                            .transaction { t in if dragItem == widget { t.animation = nil } }
                            .gesture(reorderGesture(widget), including: model.editing ? .all : .subviews)
                            .transition(.scale(scale: 0.85).combined(with: .opacity))
                    }
                }
            }
    }

    /// Extra look switch for cards that have one (square System: one ring / four rings).
    private func variant(for widget: ShelfWidget) -> EditDecoration.Variant? {
        guard widget == .systemStats, model.size(of: widget) == .small else { return nil }
        let quad = smallStatsStyle == SmallStatsStyle.quad.rawValue
        return EditDecoration.Variant(
            symbol: quad ? "circle" : "circle.grid.2x2",
            help: quad ? "Одно кольцо" : "Четыре кольца",
            action: {
                withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
                    smallStatsStyle = (quad ? SmallStatsStyle.single : .quad).rawValue
                }
            }
        )
    }

    /// Edit mode: drag a card sideways; passing half of a neighbour swaps them.
    private func reorderGesture(_ widget: ShelfWidget) -> some Gesture {
        DragGesture(minimumDistance: 3, coordinateSpace: .global)
            .onChanged { value in
                if dragItem != widget {
                    dragItem = widget
                    dragConsumed = 0
                }
                let gap = NotchMetrics.cardGap
                var offset = value.translation.width - dragConsumed
                if let i = model.draft.firstIndex(of: widget) {
                    if offset > 0, i + 1 < model.draft.count {
                        let rightWidth = model.width(of: model.draft[i + 1])
                        if offset > rightWidth / 2 + gap {
                            withAnimation(.spring(response: 0.35, dampingFraction: 0.82)) { model.draft.swapAt(i, i + 1) }
                            dragConsumed += rightWidth + gap
                        }
                    } else if offset < 0, i > 0 {
                        let leftWidth = model.width(of: model.draft[i - 1])
                        if -offset > leftWidth / 2 + gap {
                            withAnimation(.spring(response: 0.35, dampingFraction: 0.82)) { model.draft.swapAt(i, i - 1) }
                            dragConsumed -= leftWidth + gap
                        }
                    }
                }
                offset = value.translation.width - dragConsumed
                dragOffset = offset
            }
            .onEnded { _ in
                withAnimation(.spring(response: 0.35, dampingFraction: 0.82)) {
                    dragOffset = 0
                    dragItem = nil
                }
                dragConsumed = 0
            }
    }

    @ViewBuilder
    private func card(_ widget: ShelfWidget, small: Bool) -> some View {
        switch (widget, small) {
        case (.nowPlaying, false): NowPlayingCard(spotify: spotify)
        case (.nowPlaying, true): SmallNowPlayingCard(spotify: spotify)
        case (.calendar, false): CalendarCard(calendar: CalendarService.shared)
        case (.calendar, true): SmallCalendarCard(calendar: CalendarService.shared)
        case (.weather, false): WeatherCard(weather: WeatherService.shared)
        case (.weather, true): SmallWeatherCard(weather: WeatherService.shared)
        case (.systemStats, false): StatsCard(stats: SystemStatsService.shared)
        case (.systemStats, true): SmallStatsCard(stats: SystemStatsService.shared)
        case (.batteries, false): BatteriesCard(batteries: BatteryService.shared)
        case (.batteries, true): SmallBatteriesCard(batteries: BatteryService.shared)
        case (.agents, false): AgentsCard(agents: AgentsService.shared)
        case (.agents, true): SmallAgentsCard(agents: AgentsService.shared)
        case (.mixer, false): MixerCard(mixer: AudioMixer.shared)
        case (.mixer, true): MixerCard(mixer: AudioMixer.shared, small: true)
        case (.clipboard, false): ClipboardCard(clips: ClipboardService.shared)
        case (.clipboard, true): ClipboardCard(clips: ClipboardService.shared, small: true)
        }
    }
}

/// Dashed outline + red minus badge in edit mode.
struct EditDecoration: ViewModifier {
    struct Variant {
        let symbol: String
        let help: String
        let action: () -> Void
    }

    let editing: Bool
    let small: Bool
    let onRemove: () -> Void
    let onResize: () -> Void
    var variant: Variant?

    func body(content: Content) -> some View {
        content
            .allowsHitTesting(!editing)
            .padding(editing ? 4 : 0)
            // Drag area = the card. Must come before the corner buttons: a rounded content
            // shape applied after them cuts off their hit area at the rounded corners.
            .contentShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay {
                if editing {
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .strokeBorder(style: StrokeStyle(lineWidth: 1.2, dash: [5, 4]))
                        .foregroundStyle(.white.opacity(0.4))
                        .allowsHitTesting(false)
                }
            }
            .overlay(alignment: .topTrailing) {
                if editing {
                    Button(action: onRemove) {
                        Image(systemName: "minus")
                            .font(.system(size: 10, weight: .heavy))
                            .foregroundStyle(.white)
                            .frame(width: 20, height: 20)
                            .background(Circle().fill(Color(red: 0.55, green: 0.12, blue: 0.12)))
                    }
                    .buttonStyle(PressableStyle())
                    .offset(x: 6, y: -6)
                    .transition(.scale.combined(with: .opacity))
                }
            }
            .overlay(alignment: .bottomLeading) {
                if editing {
                    Button(action: onResize) {
                        Image(systemName: small ? "arrow.left.and.right" : "square")
                            .font(.system(size: 9, weight: .heavy))
                            .foregroundStyle(.white)
                            .frame(width: 20, height: 20)
                            .background(Circle().fill(Color(white: 0.3)))
                    }
                    .buttonStyle(PressableStyle())
                    .help(small ? "Сделать широким" : "Сделать квадратным")
                    .offset(x: -6, y: 6)
                    .transition(.scale.combined(with: .opacity))
                }
            }
            .overlay(alignment: .bottom) {
                if editing, let variant {
                    Button(action: variant.action) {
                        Image(systemName: variant.symbol)
                            .font(.system(size: 9, weight: .heavy))
                            .foregroundStyle(.white)
                            .frame(width: 20, height: 20)
                            .background(Circle().fill(Color.accentColor))
                    }
                    .buttonStyle(PressableStyle())
                    .help(variant.help)
                    .offset(y: 10)
                    .transition(.scale.combined(with: .opacity))
                }
            }
            .padding(editing ? -4 : 0)
    }
}

/// All widgets with a checkmark on the ones in the shelf; cancel / save on the right.
private struct ShelfPalette: View {
    @ObservedObject var model: NotchModel

    var body: some View {
        HStack(spacing: 10) {
            ForEach(ShelfWidget.allCases) { widget in
                let on = model.draft.contains(widget)
                let elsewhere = on ? nil : model.pageOf(widget)
                let fits = on || model.canAdd(widget)
                Button {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { model.togglePalette(widget) }
                } label: {
                    VStack(spacing: 5) {
                        RoundedRectangle(cornerRadius: 11, style: .continuous)
                            .fill(Color.white.opacity(0.1))
                            .frame(width: 44, height: 44)
                            .overlay(
                                Image(systemName: widget.symbol)
                                    .symbolRenderingMode(.multicolor)
                                    .font(.system(size: 19))
                            )
                            .overlay(alignment: .bottomTrailing) {
                                if on {
                                    Image(systemName: "checkmark.circle.fill")
                                        .font(.system(size: 15))
                                        .symbolRenderingMode(.palette)
                                        .foregroundStyle(.white, Color.accentColor)
                                        .offset(x: 5, y: 5)
                                } else if let elsewhere {
                                    Text("\(elsewhere + 1)")
                                        .font(.system(size: 9, weight: .heavy))
                                        .foregroundStyle(.white)
                                        .frame(width: 15, height: 15)
                                        .background(Circle().fill(Color.gray))
                                        .offset(x: 5, y: 5)
                                }
                            }
                        Text(widget.title)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.white.opacity(0.7))
                            .lineLimit(1)
                    }
                    .frame(width: 58)
                    .opacity(fits ? 1 : 0.35)
                }
                .buttonStyle(PressableStyle())
                .help(!fits ? "Не помещается — убери другой виджет"
                      : elsewhere.map { "На странице \($0 + 1) — нажми, чтобы перенести сюда" } ?? widget.title)
            }
            Spacer()
            pageButton("plus.rectangle.on.rectangle", help: "Новая страница") { model.addPage() }
            if model.pageCount > 1 {
                pageButton("trash", help: "Удалить эту страницу (виджеты вернутся в палитру)") { model.deleteCurrentPage() }
            }
            Button { withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) { model.cancelEditing() } } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 38, height: 38)
                    .isleGlass(Circle())
            }
            .buttonStyle(PressableStyle())
            Button { withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) { model.commitEditing() } } label: {
                Image(systemName: "checkmark")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 38, height: 38)
                    .background(Circle().fill(Color.accentColor))
            }
            .buttonStyle(PressableStyle())
        }
        .frame(height: NotchMetrics.paletteHeight - 14)
    }

    private func pageButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button { withAnimation(.spring(response: 0.45, dampingFraction: 0.86)) { action() } } label: {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 34, height: 34)
                .background(Circle().fill(Color.white.opacity(0.12)))
        }
        .buttonStyle(PressableStyle())
        .help(help)
    }
}

/// Glass pill under the island: shelf / widget editor.
struct ShelfTabBar: View {
    @ObservedObject var model: NotchModel

    var body: some View {
        HStack(spacing: 2) {
            tab("house.fill", selected: !model.editing) {
                if model.editing { model.cancelEditing() }
            }
            tab("square.grid.2x2.fill", selected: model.editing) {
                if model.editing { model.cancelEditing() } else { model.beginEditing() }
            }
            if model.pageCount > 1 {
                Capsule().fill(Color.white.opacity(0.2)).frame(width: 1, height: 18).padding(.horizontal, 4)
                ForEach(0..<model.pageCount, id: \.self) { i in
                    Button {
                        withAnimation(.spring(response: 0.45, dampingFraction: 0.86)) { model.goToPage(i) }
                    } label: {
                        Circle()
                            .fill(Color.white.opacity(i == model.page ? 0.95 : 0.3))
                            .frame(width: 7, height: 7)
                            .frame(width: 16, height: 30)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(PressableStyle())
                }
                .padding(.trailing, 2)
            }
        }
        .padding(4)
        .isleGlass(Capsule())
        .environment(\.colorScheme, .dark)
    }

    private func tab(_ symbol: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button {
            withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) { action() }
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white.opacity(selected ? 1 : 0.6))
                .frame(width: 42, height: 30)
                .background {
                    if selected { Capsule().fill(Color.white.opacity(0.18)) }
                }
                .contentShape(Capsule())
        }
        .buttonStyle(PressableStyle())
    }
}
