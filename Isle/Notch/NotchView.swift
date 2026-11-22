import SwiftUI

/// Black island hanging from the top edge: concave ears at the top, round bottom corners.
struct NotchShape: Shape {
    var topRadius: CGFloat
    var bottomRadius: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(topRadius, bottomRadius) }
        set {
            topRadius = newValue.first
            bottomRadius = newValue.second
        }
    }

    func path(in rect: CGRect) -> Path {
        let t = topRadius
        let b = max(0, min(bottomRadius, (rect.width - 2 * t) / 2, rect.height - t))
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.minY))
        p.addQuadCurve(to: CGPoint(x: rect.minX + t, y: rect.minY + t), control: CGPoint(x: rect.minX + t, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.minX + t, y: rect.maxY - b))
        p.addQuadCurve(to: CGPoint(x: rect.minX + t + b, y: rect.maxY), control: CGPoint(x: rect.minX + t, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.maxX - t - b, y: rect.maxY))
        p.addQuadCurve(to: CGPoint(x: rect.maxX - t, y: rect.maxY - b), control: CGPoint(x: rect.maxX - t, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.maxX - t, y: rect.minY + t))
        p.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY), control: CGPoint(x: rect.maxX - t, y: rect.minY))
        p.closeSubpath()
        return p
    }
}

struct NotchRootView: View {
    @ObservedObject var model: NotchModel
    @ObservedObject var spotify: SpotifyController
    @ObservedObject private var agents = AgentsService.shared

    private let spring = Animation.spring(response: 0.42, dampingFraction: 0.82)

    var body: some View {
        let hasTrack = spotify.track != nil
        let live = NotchMetrics.isLive(model: model, playing: spotify.isPlaying, hasTrack: hasTrack)
        let size = NotchMetrics.size(model: model, playing: spotify.isPlaying, hasTrack: hasTrack)
        let ear = NotchMetrics.ear
        let toast = !model.expanded && !model.dropMode && model.hud == nil ? agents.toast : nil
        let agent = !model.expanded && model.hud == nil && toast == nil ? agents.active : nil
        let shape = NotchShape(topRadius: ear, bottomRadius: model.expanded || model.dropMode ? 28 : (toast != nil ? 18 : 11))

        VStack(spacing: 8) {
            ZStack(alignment: .top) {
                shape.fill(Color.black)
                Group {
                    if model.expanded {
                        ShelfView(model: model, spotify: spotify)
                            .transition(.opacity.combined(with: .scale(scale: 0.94, anchor: .top)))
                    } else if model.dropMode {
                        NotchDropZoneView(model: model)
                            .transition(.opacity.combined(with: .scale(scale: 0.94, anchor: .top)))
                    } else if let hud = model.hud {
                        NotchHUDView(info: hud, notchHeight: model.notchSize.height)
                            .transition(.opacity)
                    } else if let toast {
                        NotchToastView(toast: toast, notchHeight: model.notchSize.height)
                            .transition(.opacity)
                    } else if let agent {
                        NotchAgentLiveView(session: agent, notchHeight: model.notchSize.height)
                            .transition(.opacity)
                    } else {
                        NotchLiveView(model: model, spotify: spotify, live: live)
                            .transition(.opacity)
                    }
                }
                .padding(.horizontal, ear)
            }
            .frame(width: size.width, height: size.height)
            .clipShape(shape)
            .shadow(color: .black.opacity(model.expanded ? 0.45 : 0), radius: 18, y: 8)

            if model.expanded {
                ShelfTabBar(model: model)
                    .transition(.opacity.combined(with: .move(edge: .top)).combined(with: .scale(scale: 0.8, anchor: .top)))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(spring, value: model.expanded)
        .animation(spring, value: model.editing)
        .animation(.spring(response: 0.45, dampingFraction: 0.86), value: model.page)
        .animation(spring, value: model.pageCount)
        .animation(spring, value: model.visibleWidgets)
        .animation(spring, value: model.draftSizes)
        .animation(spring, value: model.sizes)
        .animation(spring, value: live)
        .animation(spring, value: model.hud?.kind)
        .animation(spring, value: agents.toast)
        .animation(spring, value: model.dropMode)
        .animation(spring, value: agents.active?.id)
        .environment(\.colorScheme, .dark)
    }
}

private extension SpotifyController {
    var accent: Color { Color(nsColor: artwork?.accent ?? .systemPink) }
}

/// Collapsed "live activity": cover on the left of the camera, bars on the right.
struct NotchLiveView: View {
    @ObservedObject var model: NotchModel
    @ObservedObject var spotify: SpotifyController
    let live: Bool

    var body: some View {
        let h = model.notchSize.height
        // Each element slides out from under the camera instead of just fading in.
        let fromNotch = { (edge: Edge) in
            AnyTransition.move(edge: edge == .leading ? .trailing : .leading)
                .combined(with: .opacity)
                .combined(with: .scale(scale: 0.4))
        }
        HStack {
            if live {
                ArtThumb(artwork: spotify.artwork, size: h - 10, radius: 6)
                    .transition(fromNotch(.leading))
            }
            Spacer()
            if live {
                Waveform(color: spotify.accent, playing: spotify.isPlaying, barWidth: 2.5)
                    .frame(width: h - 10, height: (h - 10) * 0.62)
                    .transition(fromNotch(.trailing))
            }
        }
        .padding(.horizontal, 8)
        .frame(height: h)
    }
}
