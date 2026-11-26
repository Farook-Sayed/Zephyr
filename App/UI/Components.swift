import Charts
import SwiftUI

// MARK: - Formatting

enum Fmt {
    static func temp(_ v: Double?) -> String { v.map { String(format: "%.0f°", $0) } ?? "—" }
    static func temp1(_ v: Double?) -> String { v.map { String(format: "%.1f °C", $0) } ?? "—" }
    static func rpm(_ v: Double?) -> String { v.map { String(format: "%.0f", $0) } ?? "—" }
    static func watts(_ v: Double?, digits: Int = 1) -> String { v.map { String(format: "%.\(digits)f", $0) } ?? "—" }
    static func percent(_ v: Double?) -> String { v.map { String(format: "%.0f%%", $0) } ?? "—" }

    /// Adaptive throughput: KB/s → MB/s → GB/s.
    static func rate(_ bytesPerSec: Double) -> (value: String, unit: String) {
        switch bytesPerSec {
        case ..<1_000_000: (String(format: "%.0f", bytesPerSec / 1_000), "KB/s")
        case ..<1_000_000_000: (String(format: "%.1f", bytesPerSec / 1_000_000), "MB/s")
        default: (String(format: "%.2f", bytesPerSec / 1_000_000_000), "GB/s")
        }
    }

    static func bytes(_ v: Double?) -> String {
        guard let v else { return "—" }
        return ByteCountFormatter.string(fromByteCount: Int64(v), countStyle: .decimal)
    }

    /// Compact fixed-style rate for the menu bar: 12K, 1.2M, 0.9G.
    static func compactRate(_ bps: Double) -> String {
        switch bps {
        case ..<1_000: "0K"
        case ..<1_000_000: String(format: "%.0fK", bps / 1_000)
        case ..<1_000_000_000: String(format: "%.1fM", bps / 1_000_000)
        default: String(format: "%.1fG", bps / 1_000_000_000)
        }
    }

    static func gbString(_ b: UInt64) -> String { String(format: "%.1f GB", Double(b) / 1_073_741_824) }

    static func signedWatts(_ v: Double?) -> String {
        guard let v else { return "—" }
        return String(format: "%+.1f", v)
    }
}

enum TempColor {
    static func color(_ c: Double?) -> Color {
        guard let c else { return .secondary }
        switch c {
        case ..<55: return .green
        case ..<70: return .yellow
        case ..<85: return .orange
        default: return .red
        }
    }
}

// MARK: - Containers

struct Card<Content: View>: View {
    var title: String?
    var symbol: String?
    var accessory: AnyView?
    @ViewBuilder var content: Content

    init(_ title: String? = nil, symbol: String? = nil, accessory: AnyView? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.symbol = symbol
        self.accessory = accessory
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if title != nil || accessory != nil {
                HStack(spacing: 6) {
                    if let symbol { Image(systemName: symbol).foregroundStyle(.secondary).font(.subheadline.weight(.semibold)) }
                    if let title { Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary) }
                    Spacer(minLength: 0)
                    accessory
                }
            }
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(.quaternary))
    }
}

struct StatRow: View {
    var label: String
    var value: String
    var unit: String = ""
    var body: some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value).monospacedDigit().fontWeight(.medium)
            if !unit.isEmpty { Text(unit).foregroundStyle(.secondary).monospacedDigit() }
        }
        .font(.callout)
    }
}

struct Pill: View {
    var text: String
    var color: Color
    var body: some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 8).padding(.vertical, 3)
            .foregroundStyle(color)
            .background(color.opacity(0.15), in: Capsule())
    }
}

// MARK: - Charts

struct Sparkline: View {
    var points: [SeriesPoint]
    var tint: Color
    var includeZero = false
    var fixedDomain: ClosedRange<Double>?

    var body: some View {
        Group {
            if let fixedDomain {
                chart.chartYScale(domain: fixedDomain)
            } else {
                chart.chartYScale(domain: .automatic(includesZero: includeZero))
            }
        }
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .chartLegend(.hidden)
        .frame(height: 44)
    }

    private var chart: some View {
        Chart(points.suffix(60)) { p in
            AreaMark(x: .value("Time", p.date), y: .value("Value", p.value))
                .interpolationMethod(.monotone)
                .foregroundStyle(LinearGradient(colors: [tint.opacity(0.35), tint.opacity(0.02)], startPoint: .top, endPoint: .bottom))
            LineMark(x: .value("Time", p.date), y: .value("Value", p.value))
                .interpolationMethod(.monotone)
                .foregroundStyle(tint)
                .lineStyle(StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
        }
    }
}

/// Larger chart with axes for detail pages.
struct TimeSeriesChart: View {
    struct Series: Identifiable {
        var id: String { name }
        var name: String
        var points: [SeriesPoint]
        var color: Color
    }
    var series: [Series]
    var unit: String
    var domain: ClosedRange<Double>?

    var body: some View {
        Chart {
            ForEach(series) { s in
                ForEach(s.points.suffix(90)) { p in
                    LineMark(x: .value("Time", p.date), y: .value(unit, p.value), series: .value("Series", s.name))
                        .interpolationMethod(.monotone)
                        .foregroundStyle(by: .value("Series", s.name))
                        .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round))
                }
            }
        }
        .chartForegroundStyleScale(domain: series.map(\.name), range: series.map(\.color))
        .chartYAxis {
            AxisMarks(position: .trailing) { v in
                AxisGridLine().foregroundStyle(.quaternary)
                AxisValueLabel { if let d = v.as(Double.self) { Text("\(Int(d))").monospacedDigit() } }
            }
        }
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 4)) { _ in
                AxisGridLine().foregroundStyle(.quaternary)
                AxisValueLabel(format: .dateTime.minute().second())
            }
        }
        .chartLegend(position: .top, alignment: .leading)
        .frame(height: 160)
    }
}

// MARK: - Tiles

struct MetricTile: View {
    var title: String
    var symbol: String
    var value: String
    var unit: String
    var caption: String?
    var tint: Color
    var series: [SeriesPoint]

    var body: some View {
        Card(title, symbol: symbol) {
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value).font(.system(size: 34, weight: .semibold, design: .rounded)).monospacedDigit()
                Text(unit).font(.title3).foregroundStyle(.secondary)
            }
            Group {
                if series.count > 1 { Sparkline(points: series, tint: tint) } else { Color.clear.frame(height: 44) }
            }
            if let caption { Text(caption).font(.caption).foregroundStyle(.secondary).monospacedDigit() }
        }
    }
}

struct LinearGauge: View {
    var value: Double       // 0...1
    var tint: Color
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule().fill(tint).frame(width: max(6, geo.size.width * min(max(value, 0), 1)))
            }
        }
        .frame(height: 6)
    }
}
