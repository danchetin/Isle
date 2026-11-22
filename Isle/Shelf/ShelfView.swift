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

    var body: some View {
        let list = model.visibleWidgets
        VStack(spacing: 0) {
            Color.clear.frame(height: model.notchSize.height + 6)
            if list.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "square.grid.2x2")
                        .font(.system(size: 20, weight: .semibold))
                    Text("Нет виджетов — добавь их в редакторе")
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
                                }
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
            if model.editing {
                ShelfPalette(model: model)
                    .padding(.top, 14)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
        .padding(.horizontal, NotchMetrics.shelfPad)
        .padding(.bottom, NotchMetrics.shelfPad)
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
        }
    }
}

/// Dashed outline + red minus badge in edit mode.
private struct EditDecoration: ViewModifier {
    let editing: Bool
    let small: Bool
    let onRemove: () -> Void
    let onResize: () -> Void

    func body(content: Content) -> some View {
        content
            .allowsHitTesting(!editing)
            .padding(editing ? 4 : 0)
            .overlay {
                if editing {
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .strokeBorder(style: StrokeStyle(lineWidth: 1.2, dash: [5, 4]))
                        .foregroundStyle(.white.opacity(0.4))
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
            .padding(editing ? -4 : 0)
            .contentShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
    }
}

/// All widgets with a checkmark on the ones in the shelf; cancel / save on the right.
private struct ShelfPalette: View {
    @ObservedObject var model: NotchModel

    var body: some View {
        HStack(spacing: 10) {
            ForEach(ShelfWidget.allCases) { widget in
                let on = model.draft.contains(widget)
                let fits = on || model.canAdd(widget)
                Button {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                        if on { model.draft.removeAll { $0 == widget } } else if fits { model.draft.append(widget) }
                    }
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
                                }
                            }
                        Text(widget.title)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.white.opacity(0.7))
                            .lineLimit(1)
                    }
                    .frame(width: 62)
                    .opacity(fits ? 1 : 0.35)
                }
                .buttonStyle(PressableStyle())
                .help(fits ? widget.title : "Не помещается — убери другой виджет")
            }
            Spacer()
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
