import Foundation
import Observation

/// Single source of truth for the UI: latest snapshot, rolling history and the poll schedule.
@MainActor
@Observable
final class TelemetryStore {
    static let shared = TelemetryStore()

    private(set) var snapshot = Snapshot.empty
    private(set) var history: [Metric: [SeriesPoint]] = [:]
    private(set) var hasReceivedData = false

    let controller = FanController()

    /// Polling cadence in seconds. Foreground (dashboard or popover visible) vs. background.
    var foregroundInterval: Double { didSet { defaults.set(foregroundInterval, forKey: "fgInterval") } }
    var backgroundInterval: Double { didSet { defaults.set(backgroundInterval, forKey: "bgInterval") } }

    @ObservationIgnored private(set) var visibleSurfaces = 0
    @ObservationIgnored private let hub = SensorHub()
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var sleeper: Task<Void, Never>?
    @ObservationIgnored private var counter = 0
    @ObservationIgnored private let defaults = UserDefaults.standard
    private let capacity = 120

    private init() {
        let fg = UserDefaults.standard.double(forKey: "fgInterval")
        let bg = UserDefaults.standard.double(forKey: "bgInterval")
        foregroundInterval = fg > 0 ? fg : 1
        backgroundInterval = bg > 0 ? bg : 3
    }

    var interval: Double { visibleSurfaces > 0 ? foregroundInterval : backgroundInterval }

    func start() {
        guard task == nil else { return }
        task = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let snap = await self.hub.sample(detailed: self.visibleSurfaces > 0)
                self.apply(snap)
                let nap = Task<Void, Never> { try? await Task.sleep(for: .seconds(self.interval)) }
                self.sleeper = nap
                await nap.value
            }
        }
    }

    /// Dashboard window or popover appeared / disappeared.
    func surface(visible: Bool) {
        visibleSurfaces = max(0, visibleSurfaces + (visible ? 1 : -1))
        if visible {
            controller.refreshHelperState()
            if visibleSurfaces == 1 { sleeper?.cancel() } // wake the loop now instead of after the long background nap
        }
    }

    private func apply(_ s: Snapshot) {
        snapshot = s
        hasReceivedData = true
        record(s)
        controller.update(with: s)
    }

    private func record(_ s: Snapshot) {
        func add(_ m: Metric, _ v: Double?) {
            guard let v else { return }
            counter += 1
            var arr = history[m] ?? []
            arr.append(SeriesPoint(id: counter, date: s.date, value: v))
            if arr.count > capacity { arr.removeFirst(arr.count - capacity) }
            history[m] = arr
        }
        add(.cpuTemp, s.cpuMax)
        add(.gpuTemp, s.gpuTemp)
        add(.ssdTemp, s.ssdTemp)
        add(.batteryTemp, s.batteryTemp)
        add(.fan0, s.fans.first?.rpm)
        add(.fan1, s.fans.count > 1 ? s.fans[1].rpm : nil)
        add(.fanPercent, s.averageFanPercent)
        add(.systemW, s.power.systemW)
        add(.cpuW, s.power.cpuW)
        add(.gpuW, s.power.gpuW)
        add(.batteryW, s.power.batteryW)
        add(.diskRead, s.storage.readBytesPerSec / 1_000_000)
        add(.diskWrite, s.storage.writeBytesPerSec / 1_000_000)
        add(.gpuUtil, s.gpu.utilization)
        add(.netDown, s.network.downBytesPerSec / 1_000_000)
        add(.netUp, s.network.upBytesPerSec / 1_000_000)
        add(.memUsed, s.memory.totalBytes > 0 ? s.memory.usedFraction * 100 : nil)
    }

    func series(_ m: Metric) -> [SeriesPoint] { history[m] ?? [] }

    /// One-shot read used by `--selftest` and export.
    func sampleNow() async -> Snapshot { await hub.sample(detailed: true) }
    func energyChannels() async -> [String] { await hub.energyChannelNames() }
}
