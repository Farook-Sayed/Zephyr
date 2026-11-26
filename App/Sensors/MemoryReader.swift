import Darwin
import Foundation

struct ProcessMemory: Identifiable, Codable, Sendable, Equatable {
    var id: String { name }
    var name: String
    var bytes: UInt64
    var processCount: Int
    /// Path of the enclosing .app bundle, when the process belongs to one (used for "Quit").
    var appPath: String?
}

struct MemoryInfo: Codable, Sendable, Equatable {
    var totalBytes: UInt64 = 0
    var appBytes: UInt64 = 0
    var wiredBytes: UInt64 = 0
    var compressedBytes: UInt64 = 0
    var cachedBytes: UInt64 = 0
    var freeBytes: UInt64 = 0
    var swapUsedBytes: UInt64 = 0
    var swapTotalBytes: UInt64 = 0
    /// 1 = normal, 2 = warning, 4 = critical (kern.memorystatus_vm_pressure_level).
    var pressureLevel: Int = 1
    var topProcesses: [ProcessMemory] = []

    /// Same definition Activity Monitor uses for "Memory Used".
    var usedBytes: UInt64 { appBytes + wiredBytes + compressedBytes }
    var usedFraction: Double { totalBytes > 0 ? Double(usedBytes) / Double(totalBytes) : 0 }

    var pressure: ThermalPressure { pressureLevel >= 4 ? .critical : (pressureLevel == 2 ? .serious : .nominal) }
    var pressureTitle: String { pressureLevel >= 4 ? "Critical" : (pressureLevel == 2 ? "Warning" : "Normal") }

    static let empty = MemoryInfo()
}

/// Reads system memory from the Mach VM statistics and (occasionally) walks the process list.
final class MemoryReader {
    private let pageSize = UInt64(getpagesize())
    private let total = ProcessInfo.processInfo.physicalMemory
    private var scanCounter = 0
    private var cachedTop: [ProcessMemory] = []

    func read(includeProcesses: Bool) -> MemoryInfo {
        var info = MemoryInfo()
        info.totalBytes = total

        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.stride / MemoryLayout<integer_t>.stride)
        let kr = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        if kr == KERN_SUCCESS {
            let internalPages = UInt64(stats.internal_page_count)
            let purgeable = UInt64(stats.purgeable_count)
            info.appBytes = (internalPages > purgeable ? internalPages - purgeable : 0) * pageSize
            info.wiredBytes = UInt64(stats.wire_count) * pageSize
            info.compressedBytes = UInt64(stats.compressor_page_count) * pageSize
            info.cachedBytes = (UInt64(stats.external_page_count) + purgeable) * pageSize
            let free = UInt64(stats.free_count) - min(UInt64(stats.speculative_count), UInt64(stats.free_count))
            info.freeBytes = free * pageSize
        }

        var swap = xsw_usage()
        var swapSize = MemoryLayout<xsw_usage>.stride
        if sysctlbyname("vm.swapusage", &swap, &swapSize, nil, 0) == 0 {
            info.swapUsedBytes = swap.xsu_used
            info.swapTotalBytes = swap.xsu_total
        }

        var level: Int32 = 1
        var levelSize = MemoryLayout<Int32>.size
        if sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &levelSize, nil, 0) == 0 {
            info.pressureLevel = Int(level)
        }

        if includeProcesses {
            // Walking ~500 processes is the expensive part; refresh it every third detailed poll.
            if scanCounter % 3 == 0 || cachedTop.isEmpty { cachedTop = topProcesses(limit: 10) }
            scanCounter += 1
            info.topProcesses = cachedTop
        }
        return info
    }

    /// Per-app physical footprint (the number Activity Monitor shows as "Memory"), helpers folded into their app.
    private func topProcesses(limit: Int) -> [ProcessMemory] {
        let capacity = Int(proc_listallpids(nil, 0)) + 64
        guard capacity > 64 else { return [] }
        var pids = [pid_t](repeating: 0, count: capacity)
        let got = Int(proc_listallpids(&pids, Int32(capacity * MemoryLayout<pid_t>.stride)))
        var groups: [String: ProcessMemory] = [:]
        var pathBuffer = [CChar](repeating: 0, count: 4096)

        for pid in pids.prefix(max(got, 0)) where pid > 0 {
            var usage = rusage_info_current()
            let ok = withUnsafeMutablePointer(to: &usage) {
                $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_CURRENT, $0) }
            }
            guard ok == 0, usage.ri_phys_footprint > 0 else { continue }

            var name = ""
            var appPath: String?
            if proc_pidpath(pid, &pathBuffer, UInt32(pathBuffer.count)) > 0 {
                let path = String(cString: pathBuffer)
                let parts = path.split(separator: "/", omittingEmptySubsequences: true)
                if let i = parts.firstIndex(where: { $0.hasSuffix(".app") }) {
                    name = String(parts[i].dropLast(4))
                    appPath = "/" + parts[...i].joined(separator: "/")
                } else {
                    name = parts.last.map(String.init) ?? ""
                }
            }
            if name.isEmpty { continue }
            var g = groups[name] ?? ProcessMemory(name: name, bytes: 0, processCount: 0, appPath: appPath)
            g.bytes += usage.ri_phys_footprint
            g.processCount += 1
            groups[name] = g
        }
        return Array(groups.values.sorted { $0.bytes > $1.bytes }.prefix(limit))
    }
}
