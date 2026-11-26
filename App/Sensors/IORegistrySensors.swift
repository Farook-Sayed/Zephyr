import Foundation
import IOKit

enum IORegistry {
    static func properties(matching className: String) -> [[String: Any]] {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching(className), &iterator) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }
        var result: [[String: Any]] = []
        while case let entry = IOIteratorNext(iterator), entry != 0 {
            var props: Unmanaged<CFMutableDictionary>?
            if IORegistryEntryCreateCFProperties(entry, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS,
               let dict = props?.takeRetainedValue() as? [String: Any] {
                result.append(dict)
            }
            IOObjectRelease(entry)
        }
        return result
    }
}

private func number(_ any: Any?) -> Double? { (any as? NSNumber)?.doubleValue }

/// AppleSmartBattery: charge state, capacity, health and adapter negotiation.
enum BatteryReader {
    static func read() -> (BatteryInfo, AdapterInfo) {
        guard let p = IORegistry.properties(matching: "AppleSmartBattery").first else { return (BatteryInfo(), AdapterInfo()) }
        let data = p["BatteryData"] as? [String: Any] ?? [:]

        var battery = BatteryInfo()
        battery.present = (p["BatteryInstalled"] as? Bool) ?? true
        battery.percent = number(p["CurrentCapacity"]) ?? 0
        battery.cycleCount = (p["CycleCount"] as? NSNumber)?.intValue
        battery.designMAh = number(data["DesignCapacity"]) ?? number(p["DesignCapacity"])
        battery.fullChargeMAh = number(data["AppleRawMaxCapacity"]) ?? number(p["AppleRawMaxCapacity"]) ?? number(data["FullChargeCapacity"])
        battery.remainingMAh = number(data["AppleRawCurrentCapacity"]) ?? number(p["AppleRawCurrentCapacity"])
        battery.voltage = number(p["Voltage"]).map { $0 / 1000 }
        // Amperage is reported as an unsigned 64-bit value that wraps negative while discharging.
        if let raw = (p["Amperage"] as? NSNumber)?.uint64Value {
            battery.amperage = Double(Int64(bitPattern: raw)) / 1000
        }
        if let t = number(p["Temperature"]), t > 0 { battery.temperatureC = t / 100 }

        var adapter = AdapterInfo()
        adapter.connected = (p["ExternalConnected"] as? Bool) ?? false
        adapter.isCharging = (p["IsCharging"] as? Bool) ?? false
        adapter.isFullyCharged = (p["FullyCharged"] as? Bool) ?? false
        if let d = p["AdapterDetails"] as? [String: Any] {
            adapter.name = d["Name"] as? String
            adapter.ratedWatts = number(d["Watts"])
            adapter.voltage = number(d["AdapterVoltage"]).map { $0 / 1000 }
            adapter.amperage = number(d["Current"]).map { $0 / 1000 }
        }
        return (battery, adapter)
    }
}

/// Aggregated block-storage counters (bytes since boot) and the SMART verdict.
final class StorageReader: @unchecked Sendable {
    private let smartLock = NSLock()
    private var lastRead: Double?
    private var lastWrite: Double?
    private var lastDate: Date?
    private var smartStatus: String?
    private var model: String?
    private var lastSmartCheck = Date.distantPast

    func read() -> StorageInfo {
        var totalRead = 0.0, totalWrite = 0.0
        for p in IORegistry.properties(matching: "IOBlockStorageDriver") {
            guard let s = p["Statistics"] as? [String: Any] else { continue }
            totalRead += number(s["Bytes (Read)"]) ?? 0
            totalWrite += number(s["Bytes (Write)"]) ?? 0
        }
        let now = Date()
        var info = StorageInfo()
        if let lr = lastRead, let lw = lastWrite, let ld = lastDate {
            let dt = max(now.timeIntervalSince(ld), 0.001)
            info.readBytesPerSec = max(0, (totalRead - lr) / dt)
            info.writeBytesPerSec = max(0, (totalWrite - lw) / dt)
        }
        lastRead = totalRead; lastWrite = totalWrite; lastDate = now
        info.readSinceBootBytes = totalRead
        info.writtenSinceBootBytes = totalWrite

        if now.timeIntervalSince(lastSmartCheck) > 600 {
            lastSmartCheck = now
            // diskutil can stall (e.g. a failing external drive); never let it block the telemetry/heartbeat loop.
            DispatchQueue.global(qos: .utility).async { [self] in
                let r = Self.querySMART()
                smartLock.lock(); smartStatus = r.status; model = r.model; smartLock.unlock()
            }
        }
        smartLock.lock(); info.smartStatus = smartStatus; info.model = model; smartLock.unlock()
        return info
    }

    /// `diskutil` is the supported way to obtain the SMART verdict for the internal drive.
    private static func querySMART() -> (status: String?, model: String?) {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil")
        task.arguments = ["info", "-plist", "disk0"]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        guard (try? task.run()) != nil else { return (nil, nil) }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { return (nil, nil) }
        return (plist["SMARTStatus"] as? String, plist["MediaName"] as? String)
    }
}

enum GPUReader {
    static func read() -> GPUInfo {
        for p in IORegistry.properties(matching: "AGXAccelerator") {
            if let s = p["PerformanceStatistics"] as? [String: Any] {
                return GPUInfo(utilization: number(s["Device Utilization %"]),
                               renderer: number(s["Renderer Utilization %"]),
                               tiler: number(s["Tiler Utilization %"]),
                               memoryInUseBytes: number(s["In use system memory"]))
            }
        }
        return GPUInfo()
    }
}
