import Charts
import SwiftUI

/// Interactive temperature → fan-speed curve. Drag nodes; double-click empty space to add one.
struct CurveEditor: View {
    @Environment(TelemetryStore.self) private var store
    @State private var dragging: UUID?
    @State private var selected: UUID?

    private let tempRange: ClosedRange<Double> = 20...100

    var body: some View {
        let c = store.controller
        let nodes = c.curveNodes.sorted { $0.temperature < $1.temperature }
        let current = c.curveSensor.temperature(in: store.snapshot)

        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Picker("Sensor", selection: Binding(get: { c.curveSensor }, set: { c.curveSensor = $0 })) {
                    ForEach(CurveSensor.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 220)
                .labelsHidden()
                Spacer()
                Button("Remove Node") { remove() }.disabled(selected == nil || c.curveNodes.count <= 2)
                Button("Reset") { c.curveNodes = FanPolicy.defaultCurve; selected = nil; c.persistCurve() }
            }
            .controlSize(.small)

            Chart {
                ForEach(nodes) { n in
                    LineMark(x: .value("Temperature", n.temperature), y: .value("Speed", n.percent))
                        .interpolationMethod(.linear)
                        .foregroundStyle(Color.accentColor)
                        .lineStyle(StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
                }
                ForEach(nodes) { n in
                    PointMark(x: .value("Temperature", n.temperature), y: .value("Speed", n.percent))
                        .symbolSize(n.id == selected ? 190 : 110)
                        .foregroundStyle(n.id == selected ? Color.accentColor : Color.white)
                }
                if let current {
                    RuleMark(x: .value("Now", current))
                        .foregroundStyle(TempColor.color(current))
                        .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                        .annotation(position: .top, alignment: .leading, spacing: 2) {
                            Text("\(c.curveSensor.title) \(Fmt.temp(current))").font(.caption2.weight(.semibold)).monospacedDigit()
                                .foregroundStyle(TempColor.color(current))
                        }
                }
            }
            .chartXScale(domain: tempRange)
            .chartYScale(domain: 0...100)
            .chartXAxis {
                AxisMarks(values: .stride(by: 10)) { v in
                    AxisGridLine().foregroundStyle(.quaternary)
                    AxisValueLabel { if let d = v.as(Double.self) { Text("\(Int(d))°").monospacedDigit() } }
                }
            }
            .chartYAxis {
                AxisMarks(values: [0, 25, 50, 75, 100]) { v in
                    AxisGridLine().foregroundStyle(.quaternary)
                    AxisValueLabel { if let d = v.as(Double.self) { Text("\(Int(d))%").monospacedDigit() } }
                }
            }
            .chartOverlay { proxy in
                GeometryReader { geo in
                    Rectangle().fill(.clear).contentShape(Rectangle())
                        .gesture(DragGesture(minimumDistance: 0)
                            .onChanged { value in handleDrag(value, proxy: proxy, geo: geo) }
                            .onEnded { _ in dragging = nil; store.controller.persistCurve() })
                        .simultaneousGesture(SpatialTapGesture(count: 2).onEnded { value in
                            add(at: value.location, proxy: proxy, geo: geo)
                        })
                }
            }
            .frame(height: 220)

            Text("Drag a point to reshape the curve · double-click to add a point. Speeds are % of each fan's maximum and never go below its minimum.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func plotPoint(_ location: CGPoint, proxy: ChartProxy, geo: GeometryProxy) -> (temp: Double, pct: Double)? {
        guard let anchor = proxy.plotFrame else { return nil }
        let frame = geo[anchor]
        guard let t = proxy.value(atX: location.x - frame.origin.x, as: Double.self),
              let p = proxy.value(atY: location.y - frame.origin.y, as: Double.self) else { return nil }
        return (min(max(t.rounded(), tempRange.lowerBound), tempRange.upperBound), min(max(p.rounded(), 0), 100))
    }

    private func screenPoint(_ n: CurveNode, proxy: ChartProxy, geo: GeometryProxy) -> CGPoint? {
        guard let anchor = proxy.plotFrame else { return nil }
        let frame = geo[anchor]
        guard let x = proxy.position(forX: n.temperature), let y = proxy.position(forY: n.percent) else { return nil }
        return CGPoint(x: x + frame.origin.x, y: y + frame.origin.y)
    }

    private func handleDrag(_ value: DragGesture.Value, proxy: ChartProxy, geo: GeometryProxy) {
        let c = store.controller
        if dragging == nil {
            let hit = c.curveNodes.compactMap { n -> (UUID, CGFloat)? in
                guard let p = screenPoint(n, proxy: proxy, geo: geo) else { return nil }
                return (n.id, hypot(p.x - value.startLocation.x, p.y - value.startLocation.y))
            }.min { $0.1 < $1.1 }
            if let hit, hit.1 < 24 { dragging = hit.0; selected = hit.0 } else { return }
        }
        guard let id = dragging, let idx = c.curveNodes.firstIndex(where: { $0.id == id }),
              let pt = plotPoint(value.location, proxy: proxy, geo: geo) else { return }
        c.curveNodes[idx].temperature = pt.temp
        c.curveNodes[idx].percent = pt.pct
    }

    private func add(at location: CGPoint, proxy: ChartProxy, geo: GeometryProxy) {
        guard let pt = plotPoint(location, proxy: proxy, geo: geo), store.controller.curveNodes.count < 12 else { return }
        let node = CurveNode(temperature: pt.temp, percent: pt.pct)
        store.controller.curveNodes.append(node)
        store.controller.persistCurve()
        selected = node.id
    }

    private func remove() {
        guard let id = selected, store.controller.curveNodes.count > 2 else { return }
        store.controller.curveNodes.removeAll { $0.id == id }
        store.controller.persistCurve()
        selected = nil
    }
}
