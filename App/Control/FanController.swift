import Foundation
import Observation
@preconcurrency import UserNotifications

/// Decides what every fan should be doing and talks to the helper. All policy lives here (and in
/// `FanPolicy`); the helper only executes writes and enforces its own independent safety limits.
@MainActor
@Observable
final class FanController {
    // MARK: User settings
    private(set) var mode: FanMode = .automatic
    var syncAll: Bool { didSet { defaults.set(syncAll, forKey: "syncAll") } }
    var manualPercent: [Double] { didSet { defaults.set(manualPercent, forKey: "manualPercent") } }
    var curveNodes: [CurveNode]
    var curveSensor: CurveSensor { didSet { defaults.set(curveSensor.rawValue, forKey: "curveSensor") } }

    // MARK: State
    private(set) var failsafeActive = false
    private(set) var helperState: HelperState = .notInstalled
    private(set) var helperNotice: String?
    private(set) var lastError: String?
    private(set) var lastTargets: [Double] = []

    @ObservationIgnored private let helper = HelperClient()
    @ObservationIgnored private let defaults = UserDefaults.standard
    @ObservationIgnored private var slewState: [Int: Double] = [:]
    @ObservationIgnored private var lastSentTargets: [Double] = []
    @ObservationIgnored private var lastSendDate = Date.distantPast
    @ObservationIgnored private var overriding = false
    @ObservationIgnored private var lastHelperCheck = Date.distantPast
    @ObservationIgnored private var lastUpdate = Date()
    /// Helper commands run strictly in order; `generation` invalidates anything queued before a mode change.
    @ObservationIgnored private var commandChain: Task<Void, Never>?
    @ObservationIgnored private var generation = 0

    static let failsafeTrip = HelperConstants.criticalTemperature
    static let failsafeRelease = HelperConstants.criticalRelease

    init() {
        syncAll = defaults.object(forKey: "syncAll") as? Bool ?? true
        manualPercent = defaults.array(forKey: "manualPercent") as? [Double] ?? []
        curveSensor = CurveSensor(rawValue: defaults.string(forKey: "curveSensor") ?? "") ?? .cpu
        if let data = defaults.data(forKey: "curveNodes"), let nodes = try? JSONDecoder().decode([CurveNode].self, from: data), nodes.count >= 2 {
            curveNodes = nodes
        } else {
            curveNodes = FanPolicy.defaultCurve
        }
        // Launch argument for UI testing: `--mode manual`.
        if let i = CommandLine.arguments.firstIndex(of: "--mode"), i + 1 < CommandLine.arguments.count,
           let m = FanMode(rawValue: CommandLine.arguments[i + 1]) { mode = m }
    }

    /// Called when an edit finishes (not on every drag frame).
    func persistCurve() {
        if let data = try? JSONEncoder().encode(curveNodes) { defaults.set(data, forKey: "curveNodes") }
    }

    // MARK: Intent

    func setMode(_ new: FanMode) {
        guard new != mode else { return }
        mode = new
        generation += 1
        slewState.removeAll()
        lastSentTargets = []
        lastError = nil
        if new == .automatic { releaseToSystem() }
    }

    func cycleMode() {
        let order: [FanMode] = [.automatic, .performance, .manual, .fullBlast]
        let i = order.firstIndex(of: mode) ?? -1
        setMode(order[(i + 1) % order.count])
    }

    func percent(forFan i: Int, fan: FanReading?) -> Double {
        if i < manualPercent.count { return manualPercent[i] }
        return fan.map { max($0.minRPM / max($0.maxRPM, 1) * 100, 50) } ?? 50
    }

    func setManualPercent(_ value: Double, fan: Int, fans: [FanReading]) {
        ensureManualCapacity(fans.count)
        if syncAll {
            for i in manualPercent.indices { manualPercent[i] = value }
        } else if fan < manualPercent.count {
            manualPercent[fan] = value
        }
    }

    private func ensureManualCapacity(_ n: Int) {
        while manualPercent.count < n { manualPercent.append(50) }
    }

    // MARK: Helper lifecycle

    /// Never trust the registration record alone: macOS can say "enabled" while the helper rejects this copy of
    /// the app (wrong location for an ad-hoc install, outdated helper). A real XPC round trip is the truth.
    func refreshHelperState() {
        let registered = helper.registrationState
        Task {
            if let version = await helper.ping() {
                helperState = .ready
                helperNotice = version == HelperConstants.helperVersion ? nil
                    : "The installed fan helper (v\(version)) is out of date. Run scripts/install-helper.sh again to update it."
            } else {
                helperNotice = nil
                switch registered {
                case .requiresApproval: helperState = .requiresApproval
                case .ready: helperState = .unreachable("The fan helper is installed but refused or didn't answer this copy of Zephyr. Reinstall it for this app with scripts/install-helper.sh.")
                default: helperState = .notFound
                }
            }
        }
    }

    /// For `--selftest`: the helper's version string, or nil if it can't be reached.
    func pingHelper() async -> String? { await helper.ping() }

    func installHelper() {
        do {
            try helper.register()
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
        refreshHelperState()
        if helper.registrationState == .requiresApproval { helper.openApprovalSettings() }
    }

    func uninstallHelper() {
        Task {
            _ = await helper.restoreAutomatic()
            try? await helper.unregister()
            refreshHelperState()
        }
    }

    func openApprovalSettings() { helper.openApprovalSettings() }

    /// Called as the app terminates; the helper also restores automatic control when we disconnect.
    func restoreForQuit() async {
        generation += 1
        releaseToSystem()
        await commandChain?.value
    }

    private func enqueue(_ operation: @escaping @MainActor () async -> Void) {
        let previous = commandChain
        commandChain = Task { @MainActor in
            await previous?.value
            await operation()
        }
    }

    private func releaseToSystem() {
        guard overriding || helperState.isReady else { return }
        overriding = false
        lastTargets = []
        lastSentTargets = []
        enqueue { [self] in
            if let error = await helper.restoreAutomatic(), helperState.isReady { lastError = error }
        }
    }

    // MARK: Control loop

    func update(with snap: Snapshot) {
        let now = Date()
        let dt = now.timeIntervalSince(lastUpdate)
        lastUpdate = now
        if now.timeIntervalSince(lastHelperCheck) > 30 { lastHelperCheck = now; refreshHelperState() }
        guard !snap.fans.isEmpty else { return }
        ensureManualCapacity(snap.fans.count)
        updateFailsafe(snap)

        guard mode != .automatic || failsafeActive else { return }

        let controlTemp = [snap.cpuMax, snap.gpuTemp].compactMap { $0 }.max()
        var targets: [Double] = []
        for fan in snap.fans {
            let span = max(fan.maxRPM, 1)
            var wantPercent: Double
            var immediate = true
            switch mode {
            case .automatic, .fullBlast:
                wantPercent = 100
            case .manual:
                wantPercent = percent(forFan: fan.id, fan: fan)
            case .performance:
                immediate = false
                wantPercent = controlTemp.map { FanPolicy.performancePercent(temp: $0, minPercent: fan.minRPM / span * 100) } ?? 100
            case .curve:
                immediate = false
                wantPercent = curveSensor.temperature(in: snap).map { FanPolicy.curvePercent(temp: $0, nodes: curveNodes) } ?? 100
            }
            if failsafeActive { wantPercent = 100; immediate = true }

            let raw = min(max(wantPercent / 100 * span, fan.minRPM), fan.maxRPM)
            let previous = slewState[fan.id] ?? fan.rpm
            let next = immediate ? raw : FanPolicy.slew(current: previous, target: raw, dt: dt, up: 700, down: 220)
            slewState[fan.id] = next
            targets.append(min(max(next, fan.minRPM), fan.maxRPM))
        }
        lastTargets = targets
        send(targets)
    }

    private func updateFailsafe(_ snap: Snapshot) {
        guard let hot = snap.hottestCore else { return }
        if !failsafeActive, hot >= Self.failsafeTrip, mode != .automatic {
            failsafeActive = true
            notifyFailsafe(temp: hot)
        } else if failsafeActive, hot < Self.failsafeRelease || mode == .automatic {
            failsafeActive = false
        }
    }

    private func notifyFailsafe(temp: Double) {
        let body = String(format: "A sensor reached %.0f °C, so Zephyr overrode your fan setting. It returns to normal below %.0f °C.", temp, Self.failsafeRelease)
        Task {
            let center = UNUserNotificationCenter.current()
            guard (try? await center.requestAuthorization(options: [.alert, .sound])) == true else { return }
            let content = UNMutableNotificationContent()
            content.title = "Fans raised to protect your Mac"
            content.body = body
            content.interruptionLevel = .timeSensitive
            try? await center.add(UNNotificationRequest(identifier: "zephyr.failsafe", content: content, trigger: nil))
        }
    }

    private func send(_ targets: [Double]) {
        guard helperState.isReady else { return }
        let now = Date()
        let changed = zip(targets, lastSentTargets).contains { abs($0 - $1) > 25 } || targets.count != lastSentTargets.count
        // Resend periodically even when unchanged: it doubles as the helper's heartbeat.
        guard changed || now.timeIntervalSince(lastSendDate) > 5 else { return }
        lastSentTargets = targets
        lastSendDate = now
        overriding = true
        let gen = generation
        enqueue { [self] in
            guard gen == generation, mode != .automatic || failsafeActive else { return } // superseded by a mode change
            if let error = await helper.setFanTargets(targets) {
                lastError = error
                lastSentTargets = []
            } else {
                lastError = nil
            }
        }
    }

    var statusLine: String {
        if failsafeActive { return "Safety override active" }
        if mode != .automatic, !helperState.isReady { return "Fan helper required" }
        return mode == .automatic ? "Handled by macOS" : mode.title
    }
}
