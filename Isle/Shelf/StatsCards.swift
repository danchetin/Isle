import SwiftUI

// MARK: - Building blocks

/// Rolling line with a soft fill under it.
struct Sparkline: View {
    let values: [Double] // already 0…1
    let color: Color

    var body: some View {
        GeometryReader { geo in
            let pts = points(in: geo.size)
            ZStack {
                if pts.count > 1 {
                    Path { p in
                        p.move(to: CGPoint(x: pts[0].x, y: geo.size.height))
                        pts.forEach { p.addLine(to: $0) }
                        p.addLine(to: CGPoint(x: pts.last!.x, y: geo.size.height))
                        p.closeSubpath()
                    }
                    .fill(LinearGradient(colors: [color.opacity(0.35), color.opacity(0)], startPoint: .top, endPoint: .bottom))
                    Path { p in
                        p.move(to: pts[0])
                        pts.dropFirst().forEach { p.addLine(to: $0) }
                    }
                    .stroke(color, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                    Circle()
                        .fill(color)
                        .frame(width: 6, height: 6)
                        .position(pts.last!)
                } else {
                    Capsule().fill(color.opacity(0.4)).frame(height: 2)
                }
            }
        }
    }

    private func points(in size: CGSize) -> [CGPoint] {
        guard values.count > 1 else { return [] }
        // Spread whatever history exists across the full width; it scrolls once full.
        let step = size.width / CGFloat(max(values.count - 1, 1))
        return values.enumerated().map { i, v in
            CGPoint(x: CGFloat(i) * step, y: size.height * (1 - CGFloat(min(max(v, 0), 1))) * 0.9 + 2)
        }
    }
}

struct RingGauge: View {
    let fraction: Double
    let color: Color
    let symbol: String
    var size: CGFloat = 46
    var lineWidth: CGFloat = 5

    var body: some View {
        ZStack {
            Circle().stroke(color.opacity(0.22), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: CGFloat(min(max(fraction, 0.001), 1)))
                .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Image(systemName: symbol)
                .font(.system(size: size * 0.33, weight: .semibold))
                .foregroundStyle(color)
        }
        .frame(width: size, height: size)
        .animation(.spring(response: 0.5, dampingFraction: 0.85), value: fraction)
    }
}

private struct Metric {
    var title: String
    var value: String
    var unit: String
    var caption: String
    var fraction: Double
    var color: Color
    var symbol: String
    var history: [Double]
}

private struct MetricColumn: View {
    let metric: Metric
    let mirrored: Bool

    var body: some View {
        VStack(alignment: mirrored ? .trailing : .leading, spacing: 6) {
            Text(metric.title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(metric.color)
            HStack(spacing: 10) {
                if !mirrored { RingGauge(fraction: metric.fraction, color: metric.color, symbol: metric.symbol) }
                VStack(alignment: mirrored ? .trailing : .leading, spacing: 0) {
                    HStack(alignment: .firstTextBaseline, spacing: 1) {
                        Text(metric.value)
                            .font(.system(size: 32, weight: .bold, design: .rounded))
                            .contentTransition(.numericText())
                        Text(metric.unit)
                            .font(.system(size: 15, weight: .semibold))
                    }
                    Text(metric.caption)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.55))
                        .lineLimit(1)
                }
                if mirrored { RingGauge(fraction: metric.fraction, color: metric.color, symbol: metric.symbol) }
            }
            Sparkline(values: metric.history, color: metric.color)
                .frame(height: 28)
        }
        .frame(maxWidth: .infinity, alignment: mirrored ? .trailing : .leading)
    }
}

// MARK: - System Stats

struct StatsCard: View {
    @ObservedObject var stats: SystemStatsService
    @AppStorage("statsPage") private var page = 0
    @Environment(\.isSnapshot) private var isSnapshot

    private static let orange = Color(red: 1, green: 0.58, blue: 0.25)
    private static let indigo = Color(red: 0.55, green: 0.56, blue: 1)
    private static let green = Color(red: 0.3, green: 0.85, blue: 0.5)
    private static let cyan = Color(red: 0.3, green: 0.8, blue: 0.95)
    private static let blue = Color(red: 0.35, green: 0.6, blue: 1)
    private static let pink = Color(red: 1, green: 0.4, blue: 0.62)

    var body: some View {
        let pair = metrics(page: page % 3)
        VStack(spacing: 8) {
            HStack(alignment: .top, spacing: 18) {
                MetricColumn(metric: pair.0, mirrored: false)
                MetricColumn(metric: pair.1, mirrored: true)
            }
            .id(page % 3)
            .transition(.opacity.combined(with: .move(edge: .bottom)))
            HStack(spacing: 5) {
                ForEach(0..<3, id: \.self) { i in
                    Circle()
                        .fill(Color.white.opacity(i == page % 3 ? 0.9 : 0.25))
                        .frame(width: 5, height: 5)
                }
            }
        }
        .foregroundStyle(.white)
        .frame(maxHeight: .infinity)
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) { page = (page + 1) % 3 }
        }
        .onAppear { if !isSnapshot { stats.activate() } }
        .onDisappear { if !isSnapshot { stats.deactivate() } }
    }

    private func metrics(page: Int) -> (Metric, Metric) {
        switch page {
        case 1:
            let usedGB = stats.memoryUsed / 1_073_741_824
            let totalGB = stats.memoryTotal / 1_073_741_824
            return (
                Metric(title: "Память", value: String(format: "%.1f", usedGB), unit: "ГБ",
                       caption: "из \(Int(totalGB.rounded())) ГБ", fraction: stats.memoryUsed / max(stats.memoryTotal, 1),
                       color: Self.green, symbol: "memorychip", history: stats.memoryHistory),
                Metric(title: "GPU", value: stats.gpu.map { "\(Int(($0 * 100).rounded()))" } ?? "—", unit: "%",
                       caption: "загрузка", fraction: stats.gpu ?? 0,
                       color: Self.cyan, symbol: "cube.transparent", history: stats.gpuHistory)
            )
        case 2:
            let freeGB = stats.diskFree / 1_000_000_000
            let used = 1 - stats.diskFree / max(stats.diskTotal, 1)
            let (rate, unit) = Self.rate(stats.netDown)
            let (upRate, upUnit) = Self.rate(stats.netUp)
            let peak = max(stats.netHistory.max() ?? 1, 1)
            return (
                Metric(title: "Диск", value: "\(Int(freeGB.rounded()))", unit: "ГБ",
                       caption: "свободно", fraction: used,
                       color: Self.blue, symbol: "internaldrive", history: []),
                Metric(title: "Сеть", value: rate, unit: unit,
                       caption: "↑ \(upRate) \(upUnit)", fraction: min(1, stats.netDown / peak),
                       color: Self.pink, symbol: "arrow.down", history: stats.netHistory.map { $0 / peak })
            )
        default:
            let t = stats.temperature
            return (
                Metric(title: "Температура", value: t.map { "\(Int($0.rounded()))" } ?? "—", unit: "°C",
                       caption: Self.thermalText(stats.thermal), fraction: (t ?? 0) / 105,
                       color: Self.orange, symbol: "thermometer.medium",
                       history: stats.tempHistory.map { ($0 - 25) / 80 }),
                Metric(title: "CPU", value: "\(Int((stats.cpu * 100).rounded()))", unit: "%",
                       caption: "загрузка", fraction: stats.cpu,
                       color: Self.indigo, symbol: "cpu", history: stats.cpuHistory)
            )
        }
    }

    private static func thermalText(_ s: ProcessInfo.ThermalState) -> String {
        switch s {
        case .nominal: "Норма"
        case .fair: "Тепло"
        case .serious: "Горячо"
        case .critical: "Перегрев"
        @unknown default: "—"
        }
    }

    private static func rate(_ bytesPerSecond: Double) -> (String, String) {
        let kb = bytesPerSecond / 1024
        if kb < 1000 { return ("\(Int(kb.rounded()))", "КБ/с") }
        return (String(format: "%.1f", kb / 1024), "МБ/с")
    }
}

// MARK: - Batteries

struct BatteriesCard: View {
    @ObservedObject var batteries: BatteryService
    @Environment(\.isSnapshot) private var isSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Батареи")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white.opacity(0.6))
            if batteries.devices.isEmpty {
                Text("Нет устройств с батареей")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.5))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HStack(spacing: 8) {
                    ForEach(batteries.devices.prefix(4)) { d in
                        VStack(spacing: 8) {
                            ZStack(alignment: .topTrailing) {
                                RingGauge(fraction: d.level, color: color(d), symbol: d.symbol, size: 58, lineWidth: 5)
                                    .foregroundStyle(.white)
                                if d.charging {
                                    Image(systemName: "bolt.fill")
                                        .font(.system(size: 9, weight: .bold))
                                        .foregroundStyle(.black)
                                        .frame(width: 17, height: 17)
                                        .background(Circle().fill(Color.green))
                                        .offset(x: 3, y: -3)
                                }
                            }
                            Text("\(Int((d.level * 100).rounded()))%")
                                .font(.system(size: 13, weight: .semibold).monospacedDigit())
                            Text(d.name)
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(.white.opacity(0.5))
                                .lineLimit(1)
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
                Spacer(minLength: 0)
            }
        }
        .foregroundStyle(.white)
        .onAppear { if !isSnapshot { batteries.activate() } }
        .onDisappear { if !isSnapshot { batteries.deactivate() } }
    }

    private func color(_ d: BatteryDevice) -> Color {
        if d.level < 0.2, !d.charging { return Color(red: 1, green: 0.3, blue: 0.3) }
        return Color(red: 0.3, green: 0.85, blue: 0.45)
    }
}
