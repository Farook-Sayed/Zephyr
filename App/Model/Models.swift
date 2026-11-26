import Foundation
import SwiftUI

enum TempGroup: String, Codable, CaseIterable, Sendable {
    case cpu, gpu, ssd, battery, enclosure, other

    var title: String {
        switch self {
        case .cpu: "CPU"
        case .gpu: "GPU"
        case .ssd: "SSD / NAND"
        case .battery: "Battery"
        case .enclosure: "Enclosure & Palm Rest"
        case .other: "Other Sensors"
        }
    }

    var symbol: String {
        switch self {
        case .cpu: "cpu"
        case .gpu: "display"
        case .ssd: "internaldrive"
        case .battery: "battery.100"
        case .enclosure: "hand.raised"
        case .other: "thermometer.medium"
        }
    }
}

struct FanReading: Identifiable, Codable, Sendable, Equatable {
    var id: Int
    var name: String
    var rpm: Double
    var minRPM: Double
    var maxRPM: Double
    var targetRPM: Double
    var isForced: Bool

    var percentOfMax: Double { maxRPM > 0 ? rpm / maxRPM * 100 : 0 }
}

struct TempReading: Identifiable, Codable, Sendable, Equatable {
    var id: String
    var label: String
    var group: TempGroup
    var celsius: Double
}

struct PowerReading: Codable, Sendable, Equatable {
    var systemW: Double?
    var cpuW: Double?
    var gpuW: Double?
    var aneW: Double?
    var dramW: Double?
    var dcInW: Double?
    var packageW: Double?
    /// Positive while charging, negative while discharging.
    var batteryW: Double?

    static let empty = PowerReading()
}

struct AdapterInfo: Codable, Sendable, Equatable {
    var connected = false
    var name: String?
    var ratedWatts: Double?
    var voltage: Double?
    var amperage: Double?
    var isCharging = false
    var isFullyCharged = false
}

struct BatteryInfo: Codable, Sendable, Equatable {
    var present = false
    var percent: Double = 0
    var cycleCount: Int?
    var designMAh: Double?
    var fullChargeMAh: Double?
    var remainingMAh: Double?
    var voltage: Double?
    var amperage: Double?
    var temperatureC: Double?

    var healthPercent: Double? {
        guard let d = designMAh, let f = fullChargeMAh, d > 0 else { return nil }
        return min(100, f / d * 100)
    }
    /// Derived with Apple's published 80% service threshold; the OS-level flag is not exposed to apps.
    var condition: String {
        guard let h = healthPercent else { return "Unknown" }
        return h >= 80 ? "Normal" : "Service Recommended"
    }
}

struct StorageInfo: Codable, Sendable, Equatable {
    var readBytesPerSec: Double = 0
    var writeBytesPerSec: Double = 0
    var smartStatus: String?
    var model: String?
    var writtenSinceBootBytes: Double?
    var readSinceBootBytes: Double?
}

struct GPUInfo: Codable, Sendable, Equatable {
    var utilization: Double?
    var renderer: Double?
    var tiler: Double?
    var memoryInUseBytes: Double?
}

enum ThermalPressure: Int, Codable, Sendable, Comparable {
    case nominal, fair, serious, critical

    static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }

    init(_ state: ProcessInfo.ThermalState) {
        switch state {
        case .nominal: self = .nominal
        case .fair: self = .fair
        case .serious: self = .serious
        case .critical: self = .critical
        @unknown default: self = .nominal
        }
    }

    var title: String {
        switch self {
        case .nominal: "Nominal"
        case .fair: "Fair"
        case .serious: "Serious"
        case .critical: "Critical"
        }
    }

    var color: Color {
        switch self {
        case .nominal: .green
        case .fair: .yellow
        case .serious: .orange
        case .critical: .red
        }
    }
}

struct Snapshot: Codable, Sendable, Equatable {
    var date = Date()
    var fans: [FanReading] = []
    var temps: [TempReading] = []
    var power = PowerReading.empty
    var adapter = AdapterInfo()
    var battery = BatteryInfo()
    var storage = StorageInfo()
    var gpu = GPUInfo()
    var memory = MemoryInfo.empty
    var network = NetworkInfo.empty
    var pressure = ThermalPressure.nominal

    static let empty = Snapshot()

    func temps(_ group: TempGroup) -> [TempReading] { temps.filter { $0.group == group } }

    var cpuMax: Double? { temps(.cpu).map(\.celsius).max() }
    var cpuAverage: Double? { average(.cpu) }
    var gpuTemp: Double? { average(.gpu) }
    var ssdTemp: Double? { temps(.ssd).map(\.celsius).max() }
    var batteryTemp: Double? { battery.temperatureC ?? temps(.battery).map(\.celsius).max() }

    /// Hottest of the sensors that matter for throttling and the safety watchdog.
    var hottestCore: Double? { [cpuMax, gpuTemp, ssdTemp].compactMap { $0 }.max() }

    var averageFanRPM: Double? {
        fans.isEmpty ? nil : fans.map(\.rpm).reduce(0, +) / Double(fans.count)
    }

    var averageFanPercent: Double? {
        fans.isEmpty ? nil : fans.map(\.percentOfMax).reduce(0, +) / Double(fans.count)
    }

    private func average(_ group: TempGroup) -> Double? {
        let v = temps(group).map(\.celsius)
        return v.isEmpty ? nil : v.reduce(0, +) / Double(v.count)
    }
}

// MARK: - History

enum Metric: String, CaseIterable, Sendable {
    case cpuTemp, gpuTemp, ssdTemp, batteryTemp
    case fan0, fan1
    case fanPercent
    case systemW, cpuW, gpuW, batteryW
    case diskRead, diskWrite
    case gpuUtil
    case memUsed
    case netDown, netUp
}

struct SeriesPoint: Identifiable, Sendable {
    let id: Int
    let date: Date
    let value: Double
}
