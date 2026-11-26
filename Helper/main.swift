import Foundation
import Security

// Zephyr privileged helper.
//
// Runs as root under launchd (registered through SMAppService). It exposes exactly one capability —
// writing SMC fan registers — and layers three independent safety nets on top:
//   1. Only the Zephyr app (verified by code-signing requirement + executable path) may connect.
//   2. If the app disappears or stops sending updates, fans go back to automatic control.
//   3. A hardware over-temperature failsafe that runs here, regardless of what the app asks for.

setvbuf(stdout, nil, _IOLBF, 0)

// MARK: - Fan driver

final class FanDriver {
    let smc: SMC
    let limits: [FanLimits]

    init?() {
        guard let smc = SMC() else { return nil }
        self.smc = smc
        self.limits = smc.fanLimits()
    }

    /// Puts a fan in forced mode and sets its target. Apple Silicon on recent macOS may need the
    /// `Ftst` unlock key; Macs without it (such as M5 generation) accept `F%dmd` directly.
    func setTarget(fan: FanLimits, rpm: Double) throws {
        guard rpm.isFinite else { return }
        let clamped = min(max(rpm, fan.minRPM), fan.maxRPM)
        try ensureForced(fan: fan.index)
        try smc.writeNumber("F\(fan.index)Tg", clamped)
    }

    /// Per-fan mode key: Apple Silicon `F%dmd`, newer Intel `F%dMd`; older Intel only has the `FS! ` bitmask.
    private func modeKey(_ fan: Int) -> String? {
        for key in ["F\(fan)md", "F\(fan)Md"] where smc.exists(key) { return key }
        return nil
    }

    /// Sets or clears one fan's bit in the 16-bit `FS! ` mask without disturbing the others.
    private func setMaskBit(fan: Int, on: Bool) throws {
        let current = UInt16(smc.number("FS! ") ?? 0)
        let bit = UInt16(1) << UInt16(fan)
        let next = on ? (current | bit) : (current & ~bit)
        try smc.write("FS! ", bytes: [UInt8(next >> 8), UInt8(next & 0xFF)])
    }

    private func ensureForced(fan: Int) throws {
        guard let key = modeKey(fan) else { return try setMaskBit(fan: fan, on: true) }
        if smc.number(key) == 1 { return }
        do {
            try smc.writeByte(key, 1)
        } catch {
            // Newer Apple Silicon firmware can require the Ftst unlock first. Bounded wait: this runs on the
            // helper's safety queue, so it must never stall the failsafe for long.
            guard smc.exists("Ftst") else { throw error }
            try smc.writeByte("Ftst", 1)
            var lastError: Error = error
            for _ in 0..<6 {
                Thread.sleep(forTimeInterval: 0.25)
                do { try smc.writeByte(key, 1); return } catch { lastError = error }
            }
            throw lastError
        }
    }

    /// Returns one fan to automatic control.
    func release(fan: Int) {
        if let key = modeKey(fan) { try? smc.writeByte(key, 0) } else if smc.exists("FS! ") { try? setMaskBit(fan: fan, on: false) }
    }

    func restoreAutomatic() {
        for fan in limits { release(fan: fan.index) }
        if smc.exists("Ftst") { try? smc.writeByte("Ftst", 0) }
    }

    private var safetyKeys: [String] = []

    /// Hottest core-class sensor. The key list is rebuilt whenever it is empty, so one failed enumeration
    /// can never permanently disable the failsafe.
    func hottestCoreSensor() -> Double {
        if safetyKeys.isEmpty {
            safetyKeys = smc.allKeys().filter { key in
                ["Tp", "Tm", "Te", "Tg", "TH", "TC", "TG"].contains { key.hasPrefix($0) } && ["flt ", "sp78"].contains(smc.read(key)?.type ?? "")
            }
        }
        var hottest = 0.0
        for key in safetyKeys {
            if let v = smc.number(key), v > hottest, v < 150 { hottest = v }
        }
        return hottest
    }
}

// MARK: - Service

final class HelperService: NSObject, NSXPCListenerDelegate, ZephyrHelperProtocol {
    private let queue = DispatchQueue(label: "app.zephyr.helper.state")
    private let driver: FanDriver?
    private var desired: [Double]?           // nil → automatic
    private var lastContact = Date()
    private var failsafe = false
    private var lastMaxTemp = 0.0
    private var timer: DispatchSourceTimer?
    private let appExecutablePath: String
    private let requirement: String
    private var connectionCount = 0

    override init() {
        driver = FanDriver()
        let me = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        // SMAppService installs keep the helper next to the app executable; the manual installer passes `--app`.
        if let i = CommandLine.arguments.firstIndex(of: "--app"), i + 1 < CommandLine.arguments.count {
            appExecutablePath = URL(fileURLWithPath: CommandLine.arguments[i + 1]).resolvingSymlinksInPath().path
        } else {
            appExecutablePath = me.deletingLastPathComponent().appendingPathComponent("Zephyr").path
        }
        requirement = HelperService.makeRequirement()
        super.init()
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 1, repeating: 1.0)
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        timer = t
    }

    /// Pins clients to this app: bundle identifier, plus the same Team ID as this helper when signed.
    private static func makeRequirement() -> String {
        var team: String?
        var code: SecCode?
        if SecCodeCopySelf([], &code) == errSecSuccess, let code {
            var staticCode: SecStaticCode?
            if SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode {
                var info: CFDictionary?
                if SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
                   let dict = info as? [String: Any] {
                    team = dict[kSecCodeInfoTeamIdentifier as String] as? String
                }
            }
        }
        let id = "identifier \"\(HelperConstants.appBundleID)\""
        if let team, !team.isEmpty {
            return "anchor apple generic and certificate leaf[subject.OU] = \"\(team)\" and \(id)"
        }
        return id // ad-hoc local build; the executable-path check below still applies
    }

    // MARK: NSXPCListenerDelegate

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        var buffer = [CChar](repeating: 0, count: 4096)
        let n = proc_pidpath(connection.processIdentifier, &buffer, UInt32(buffer.count))
        let callerPath = n > 0 ? String(cString: buffer) : ""
        let resolved = URL(fileURLWithPath: callerPath).resolvingSymlinksInPath().path
        guard resolved == appExecutablePath else {
            print("rejected connection from \(callerPath)")
            return false
        }
        connection.setCodeSigningRequirement(requirement)
        connection.exportedInterface = NSXPCInterface(with: ZephyrHelperProtocol.self)
        connection.exportedObject = self
        queue.async { self.connectionCount += 1 }
        connection.invalidationHandler = { [weak self] in self?.clientDisconnected() }
        connection.interruptionHandler = { [weak self] in self?.clientDisconnected() }
        connection.resume()
        return true
    }

    private func clientDisconnected() {
        queue.async {
            self.connectionCount = max(0, self.connectionCount - 1)
            if self.connectionCount == 0 { self.releaseToSystem(reason: "client disconnected") }
        }
    }

    // MARK: Safety loop (runs on `queue`)

    private func tick() {
        guard let driver else { return }
        let hot = driver.hottestCoreSensor()
        lastMaxTemp = hot
        // In Automatic macOS owns thermal management. If the failsafe was latched when the override ended,
        // keep the fans at maximum until the system has cooled, then hand control back.
        if desired == nil {
            guard failsafe else { return }
            if hot < HelperConstants.criticalRelease {
                failsafe = false
                print("failsafe released at \(hot)°C; restoring automatic control")
                driver.restoreAutomatic()
            } else {
                for fan in driver.limits { try? driver.setTarget(fan: fan, rpm: fan.maxRPM) }
            }
            return
        }
        if hot >= HelperConstants.criticalTemperature, !failsafe {
            failsafe = true
            print("FAILSAFE: \(hot)°C — forcing fans to maximum")
        } else if failsafe, hot < HelperConstants.criticalRelease {
            failsafe = false
            print("failsafe released at \(hot)°C")
            if let desired { for fan in driver.limits where fan.index < desired.count && desired[fan.index] >= 0 { try? driver.setTarget(fan: fan, rpm: desired[fan.index]) } }
        }
        if failsafe {
            for fan in driver.limits { try? driver.setTarget(fan: fan, rpm: fan.maxRPM) }
            return
        }
        if desired != nil, Date().timeIntervalSince(lastContact) > HelperConstants.clientTimeout {
            releaseToSystem(reason: "client heartbeat timeout")
        }
    }

    private func releaseToSystem(reason: String) {
        guard desired != nil else { return }
        print("restoring automatic fan control: \(reason)")
        desired = nil
        if !failsafe { driver?.restoreAutomatic() }
    }

    // MARK: ZephyrHelperProtocol

    func version(reply: @escaping (String) -> Void) { reply(HelperConstants.helperVersion) }

    func setFanTargets(_ rpms: [NSNumber], reply: @escaping (String?) -> Void) {
        queue.async {
            guard let driver = self.driver else { return reply("SMC unavailable") }
            self.lastContact = Date()
            let values = rpms.map { $0.doubleValue }
            guard values.allSatisfy({ $0.isFinite }) else { return reply("Invalid fan target") }
            if values.allSatisfy({ $0 < 0 }) {
                self.releaseToSystem(reason: "requested")
                return reply(nil)
            }
            if self.failsafe { self.desired = values; return reply(nil) }
            var firstError: String?
            for fan in driver.limits where fan.index < values.count {
                let rpm = values[fan.index]
                do {
                    if rpm < 0 {
                        driver.release(fan: fan.index)
                    } else {
                        try driver.setTarget(fan: fan, rpm: rpm)
                    }
                } catch {
                    firstError = firstError ?? "\(error)"
                }
            }
            self.desired = values
            reply(firstError)
        }
    }

    func restoreAutomatic(reply: @escaping (String?) -> Void) {
        queue.async {
            self.lastContact = Date()
            self.releaseToSystem(reason: "requested")
            reply(nil)
        }
    }

    func status(reply: @escaping ([String: NSNumber]) -> Void) {
        queue.async {
            self.lastContact = Date()
            reply(["override": NSNumber(value: self.desired != nil),
                   "failsafe": NSNumber(value: self.failsafe),
                   "maxTemp": NSNumber(value: self.lastMaxTemp)])
        }
    }

    func shutdown() {
        queue.sync {
            desired = nil
            driver?.restoreAutomatic()
        }
    }
}

// MARK: - Entry point

let service = HelperService()
let listener = NSXPCListener(machServiceName: HelperConstants.machService)
listener.delegate = service
listener.resume()

// Hand fans back to macOS if launchd stops us.
let signalSources = [SIGTERM, SIGINT].map { sig -> DispatchSourceSignal in
    signal(sig, SIG_IGN)
    let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
    source.setEventHandler {
        service.shutdown()
        exit(0)
    }
    source.resume()
    return source
}
_ = signalSources

print("ZephyrHelper \(HelperConstants.helperVersion) ready")
RunLoop.main.run()
