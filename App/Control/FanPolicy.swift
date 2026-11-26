import Foundation

enum FanMode: String, CaseIterable, Codable, Identifiable, Sendable {
    case automatic, performance, manual, fullBlast, curve

    var id: String { rawValue }

    var title: String {
        switch self {
        case .automatic: "Automatic"
        case .performance: "Performance"
        case .manual: "Manual"
        case .fullBlast: "Full Blast"
        case .curve: "Custom Curve"
        }
    }

    var symbol: String {
        switch self {
        case .automatic: "fan"
        case .performance: "gauge.with.dots.needle.67percent"
        case .manual: "slider.horizontal.3"
        case .fullBlast: "wind"
        case .curve: "chart.xyaxis.line"
        }
    }

    var detail: String {
        switch self {
        case .automatic: "macOS manages the fans."
        case .performance: "Ramps smoothly from 45 to 80 °C."
        case .manual: "Hold a fixed speed."
        case .fullBlast: "Maximum cooling."
        case .curve: "Speed follows a sensor you choose."
        }
    }

    /// The four modes shown in the menu bar popover.
    static let quick: [FanMode] = [.automatic, .performance, .manual, .fullBlast]
}

enum CurveSensor: String, CaseIterable, Codable, Identifiable, Sendable {
    case cpu, gpu, ssd
    var id: String { rawValue }
    var title: String { ["cpu": "CPU", "gpu": "GPU", "ssd": "SSD"][rawValue]! }

    func temperature(in s: Snapshot) -> Double? {
        switch self {
        case .cpu: s.cpuMax
        case .gpu: s.gpuTemp
        case .ssd: s.ssdTemp
        }
    }
}

struct CurveNode: Codable, Identifiable, Equatable, Sendable {
    var id = UUID()
    var temperature: Double   // °C
    var percent: Double       // % of max RPM
}

enum FanPolicy {
    static let performanceStart = 45.0
    static let performanceEnd = 80.0

    static let defaultCurve: [CurveNode] = [
        CurveNode(temperature: 40, percent: 30),
        CurveNode(temperature: 55, percent: 40),
        CurveNode(temperature: 70, percent: 65),
        CurveNode(temperature: 85, percent: 100),
    ]

    /// Smoothstep between 45 °C (quiet) and 80 °C (maximum): no corners, so the fan never lurches.
    static func performancePercent(temp: Double, minPercent: Double) -> Double {
        let t = min(max((temp - performanceStart) / (performanceEnd - performanceStart), 0), 1)
        let eased = t * t * (3 - 2 * t)
        return minPercent + (100 - minPercent) * eased
    }

    /// Piecewise-linear interpolation through the user's nodes; flat outside the first/last node.
    static func curvePercent(temp: Double, nodes: [CurveNode]) -> Double {
        let n = nodes.sorted { $0.temperature < $1.temperature }
        guard let first = n.first, let last = n.last else { return 0 }
        if temp <= first.temperature { return first.percent }
        if temp >= last.temperature { return last.percent }
        for (a, b) in zip(n, n.dropFirst()) where temp <= b.temperature {
            let span = max(b.temperature - a.temperature, 0.001)
            return a.percent + (b.percent - a.percent) * (temp - a.temperature) / span
        }
        return last.percent
    }

    /// Limits how fast a target may move so ramps are inaudible-ish (RPM per second).
    static func slew(current: Double, target: Double, dt: Double, up: Double, down: Double) -> Double {
        let delta = target - current
        let limit = (delta > 0 ? up : down) * max(dt, 0.1)
        return abs(delta) <= limit ? target : current + (delta > 0 ? limit : -limit)
    }
}
