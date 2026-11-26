import Foundation
import ServiceManagement

/// `Zephyr.app/Contents/MacOS/Zephyr --selftest` prints one full sensor sweep and exits.
/// Read-only: it never writes to the SMC.
enum SelfTest {
    static func run() -> Never {
        Task { @MainActor in
            let store = TelemetryStore.shared
            _ = await store.sampleNow()
            try? await Task.sleep(for: .seconds(1.5))
            let s = await store.sampleNow()
            func f(_ v: Double?, _ unit: String = "", _ digits: Int = 1) -> String {
                v.map { String(format: "%.\(digits)f%@", $0, unit) } ?? "n/a"
            }
            print("== Zephyr self-test ==")
            print("mainApp login item status: \(SMAppService.mainApp.status.rawValue) (0 notRegistered,1 enabled,2 requiresApproval,3 notFound)")
            print("Helper registration status: \(store.controller.helperState)")
            print("Fans (\(s.fans.count)):")
            for fan in s.fans {
                print("  \(fan.name): \(f(fan.rpm, " rpm", 0)) (min \(f(fan.minRPM, "", 0)) / max \(f(fan.maxRPM, "", 0)), target \(f(fan.targetRPM, "", 0)), \(f(fan.percentOfMax, "%", 0)) of max, forced=\(fan.isForced))")
            }
            print("Temps: CPU max \(f(s.cpuMax, "°C")) avg \(f(s.cpuAverage, "°C")) | GPU \(f(s.gpuTemp, "°C")) | SSD \(f(s.ssdTemp, "°C")) | Battery \(f(s.batteryTemp, "°C"))")
            for g in TempGroup.allCases {
                let t = s.temps(g)
                print("  [\(g.title)] \(t.count) sensors: " + t.prefix(6).map { "\($0.label)=\(f($0.celsius, "", 1))" }.joined(separator: ", "))
            }
            print("Power: system \(f(s.power.systemW, " W")) | CPU \(f(s.power.cpuW, " W", 2)) | GPU \(f(s.power.gpuW, " W", 2)) | ANE \(f(s.power.aneW, " W", 2)) | DRAM \(f(s.power.dramW, " W", 2)) | DC-in \(f(s.power.dcInW, " W")) | battery \(f(s.power.batteryW, " W"))")
            print("Adapter: connected=\(s.adapter.connected) \(s.adapter.name ?? "-") \(f(s.adapter.ratedWatts, " W", 0)) \(f(s.adapter.voltage, " V")) \(f(s.adapter.amperage, " A", 2)) charging=\(s.adapter.isCharging)")
            print("Battery: \(f(s.battery.percent, "%", 0)) cycles=\(s.battery.cycleCount.map(String.init) ?? "n/a") design=\(f(s.battery.designMAh, " mAh", 0)) full=\(f(s.battery.fullChargeMAh, " mAh", 0)) now=\(f(s.battery.remainingMAh, " mAh", 0)) health=\(f(s.battery.healthPercent, "%", 0)) \(s.battery.condition) temp=\(f(s.battery.temperatureC, "°C"))")
            print("Storage: read \(f(s.storage.readBytesPerSec / 1e6, " MB/s")) write \(f(s.storage.writeBytesPerSec / 1e6, " MB/s")) SMART=\(s.storage.smartStatus ?? "n/a") written-since-boot=\(f((s.storage.writtenSinceBootBytes ?? 0) / 1e9, " GB", 0))")
            print("GPU: util \(f(s.gpu.utilization, "%", 0)) renderer \(f(s.gpu.renderer, "%", 0)) tiler \(f(s.gpu.tiler, "%", 0))")
            let m = s.memory
            func g(_ b: UInt64) -> String { String(format: "%.2f GB", Double(b) / 1_073_741_824) }
            print("Memory: total \(g(m.totalBytes)) used \(g(m.usedBytes)) (app \(g(m.appBytes)), wired \(g(m.wiredBytes)), compressed \(g(m.compressedBytes))) cached \(g(m.cachedBytes)) free \(g(m.freeBytes)) swap \(g(m.swapUsedBytes))/\(g(m.swapTotalBytes)) pressure=\(m.pressureTitle)")
            print("  top: " + m.topProcesses.prefix(6).map { "\($0.name) \(g($0.bytes)) x\($0.processCount)" }.joined(separator: ", "))
            for t in MemoryAdvisor.tips(for: m) { print("  tip: \(t.title)") }
            let n = s.network
            print("Network: connected=\(n.connected) iface=\(n.primaryInterface ?? "-") kind=\(n.kind) ip=\(n.localIPv4 ?? "-") vpn=\(n.vpnActive) down=\(f(n.downBytesPerSec / 1e6, " MB/s", 2)) up=\(f(n.upBytesPerSec / 1e6, " MB/s", 2)) sinceBoot=\(f(n.downSinceBootBytes / 1e9, " GB↓", 1)) \(f(n.upSinceBootBytes / 1e9, " GB↑", 1))")
            if let w = n.wifi { print("  Wi-Fi: \(w.interfaceName) rssi=\(w.rssi) noise=\(w.noise) snr=\(w.snr) tx=\(w.txRateMbps) Mbps ch=\(w.channel.map(String.init) ?? "-") band=\(w.bandGHz.map { "\($0)" } ?? "-") width=\(w.widthMHz.map(String.init) ?? "-") phy=\(w.phyMode ?? "-") sec=\(w.security ?? "-") ssid=\(w.ssid ?? "nil (needs Location)") quality=\(w.qualityTitle)") } else { print("  Wi-Fi: none") }
            let t0 = Date()
            if let c = CodexSessionLog().latest() {
                print("Codex (session log, \(Int(Date().timeIntervalSince(t0) * 1000)) ms): " + c.windows.map { "\($0.title) \(Int($0.remainingPercent.rounded()))% left" }.joined(separator: ", ") + " — reported \(Int(Date().timeIntervalSince(c.reportedAt) / 60)) min ago")
            } else { print("Codex (session log): no reading") }
            let rec = "/Applications/Zephyr.app/Contents/MacOS/ZephyrUsage"
            let stacked = "zephyr_input=$(/bin/cat); printf '%s' \"$zephyr_input\" | '\(rec)'; printf '%s' \"$zephyr_input\" | (\n'/x/Zephyr' --record-claude-usage\n)"
            let own = "~/.claude/my-line.sh"
            let a = ClaudeStatusLine.command(for: rec, preserving: stacked) == "'\(rec)'"
            let b = ClaudeStatusLine.command(for: rec, preserving: "'/x/Zephyr' --record-claude-usage") == "'\(rec)'"
            let wrapped = ClaudeStatusLine.command(for: rec, preserving: own)
            let c = ClaudeStatusLine.command(for: rec, preserving: wrapped) == wrapped
            print("StatusLine rebuild: stacked-old→clean=\(a) legacy-only→clean=\(b) keeps-own-command=\(wrapped.contains(own)) idempotent=\(c)")
            print("Thermal pressure: \(s.pressure.title)")
            if CommandLine.arguments.contains("--channels") {
                print("IOReport energy channels: " + (await store.energyChannels()).joined(separator: "; "))
            }
            exit(0)
        }
        RunLoop.main.run()
        exit(0)
    }
}
