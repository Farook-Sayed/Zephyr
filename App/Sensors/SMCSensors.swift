import Foundation

/// Reads fans, temperatures and power rails from the SMC (no privileges required).
final class SMCSensors {
    let smc: SMC
    private struct TempKey { let key: String; let group: TempGroup; let label: String }
    private let tempKeys: [TempKey]
    private let fanCount: Int
    private var lastKnownLimits: [Int: (Double, Double)] = [:]

    init?() {
        guard let smc = SMC() else { return nil }
        self.smc = smc
        self.fanCount = smc.fanCount
        var found: [TempKey] = []
        var gpuIndex = 0
        for key in smc.allKeys().sorted() where key.hasPrefix("T") {
            guard let v = smc.read(key), ["flt ", "sp78"].contains(v.type), let c = v.number, c > 5, c < 150 else { continue }
            let (group, label) = Self.classify(key, gpuIndex: &gpuIndex)
            found.append(TempKey(key: key, group: group, label: label))
        }
        self.tempKeys = found
    }

    /// SMC temperature keys are undocumented; these follow long-standing Apple naming conventions.
    private static func classify(_ key: String, gpuIndex: inout Int) -> (TempGroup, String) {
        let tail = String(key.dropFirst(2))
        switch key {
        case "TH0a", "TH0b", "TH0x", "TH0P": return (.ssd, "NAND \(key.last!)")
        case "TS0P": return (.enclosure, "Palm Rest")
        case "TAOL", "TA0P": return (.enclosure, "Ambient")
        case "TW0P": return (.enclosure, "Wireless Module")
        default: break
        }
        // Measured on M5 Pro: Tp*/Tm* all track CPU load; Apple does not publish which core each belongs to.
        if key.hasPrefix("Tp") { return (.cpu, "Core Sensor \(tail)") }
        if key.hasPrefix("Tm") { return (.cpu, "Cluster Sensor \(tail)") }
        if key.hasPrefix("Te") { return (.cpu, "E-Core \(tail)") }
        if key.hasPrefix("TC") { return (.cpu, "CPU \(tail)") }          // Intel: TC0P, TC0D, TC1C…
        if key.hasPrefix("TG") { gpuIndex += 1; return (.gpu, "GPU \(tail)") } // Intel: TG0P, TG0D
        if key.hasPrefix("Tg") { gpuIndex += 1; return (.gpu, "GPU Die \(gpuIndex)") }
        if key.hasPrefix("TB") { return (.battery, "Battery \(key.dropFirst(2).dropLast())") }
        if key.hasPrefix("Ta") { return (.enclosure, "Airflow \(tail)") }
        return (.other, "SMC \(key)")
    }

    func fans() -> [FanReading] {
        (0..<fanCount).compactMap { i in
            guard let rpm = smc.number("F\(i)Ac") else { return nil }
            let mn = smc.number("F\(i)Mn") ?? lastKnownLimits[i]?.0 ?? 0
            let mx = smc.number("F\(i)Mx") ?? lastKnownLimits[i]?.1 ?? 0
            lastKnownLimits[i] = (mn, mx)
            let name = fanCount == 2 ? (i == 0 ? "Left Fan" : "Right Fan") : "Fan \(i + 1)"
            return FanReading(id: i, name: name, rpm: rpm, minRPM: mn, maxRPM: mx,
                              targetRPM: smc.number("F\(i)Tg") ?? rpm,
                              isForced: (smc.number("F\(i)md") ?? smc.number("F\(i)Md") ?? 0) == 1)
        }
    }

    private var tick = 0
    private var lightKeys: [TempKey] = []

    /// Each SMC read is a round trip to the SoC's management firmware (~100 µs), and there are ~300 sensors.
    /// With the dashboard closed we therefore read only the hottest CPU/GPU sensors (plus SSD and battery)
    /// and do a full sweep every fifth poll to find which sensors those are.
    func temps(detailed: Bool) -> [TempReading] {
        tick += 1
        let full = detailed || tick % 10 == 1 || lightKeys.isEmpty
        let keys = full ? tempKeys.filter { detailed || $0.group != .other } : lightKeys
        let readings: [TempReading] = keys.compactMap { k in
            guard let c = smc.number(k.key), c > 5, c < 150 else { return nil }
            return TempReading(id: k.key, label: k.label, group: k.group, celsius: c)
        }
        if full {
            let hot = Set(readings.filter { $0.group == .cpu }.sorted { $0.celsius > $1.celsius }.prefix(8).map(\.id))
                .union(readings.filter { $0.group == .gpu }.sorted { $0.celsius > $1.celsius }.prefix(2).map(\.id))
            lightKeys = tempKeys.filter {
                hot.contains($0.key) || $0.group == .ssd || $0.group == .battery
                    || ($0.group == .enclosure && ($0.label == "Palm Rest" || $0.label == "Ambient"))
            }
        }
        return readings
    }

    /// PSTR = total system power, PDTR = DC-in (adapter) power, PHPC = SoC package, PPMC = CPU complex.
    /// (PHPC/PPMC were identified empirically by their response to a pure CPU load on an M5 Pro.)
    func systemPower() -> (system: Double?, dcIn: Double?, package: Double?, cpu: Double?) {
        (smc.number("PSTR"), smc.number("PDTR"), smc.number("PHPC"), smc.number("PPMC"))
    }
}
