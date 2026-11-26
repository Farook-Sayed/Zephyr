import SwiftUI

enum DashboardSection: String, CaseIterable, Identifiable {
    case overview = "Overview"
    case fans = "Fans & Thermals"
    case power = "Power & Battery"
    case memory = "Memory"
    case network = "Network"
    case storage = "Storage & GPU"
    case aiUsage = "AI Usage"

    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .overview: "gauge.with.dots.needle.50percent"
        case .fans: "fan"
        case .power: "bolt.batteryblock"
        case .memory: "memorychip"
        case .network: "wifi"
        case .storage: "internaldrive"
        case .aiUsage: "gauge.with.dots.needle.67percent"
        }
    }
}

struct DashboardView: View {
    @Environment(TelemetryStore.self) private var store
    @Environment(\.dismissWindow) private var dismissWindow
    @AppStorage("dashboardSection") private var stored = DashboardSection.overview.rawValue
    private var selection: Binding<DashboardSection?> {
        Binding(get: { DashboardSection(rawValue: stored) }, set: { if let v = $0 { stored = v.rawValue } })
    }

    var body: some View {
        NavigationSplitView {
            List(DashboardSection.allCases, selection: selection) { section in
                Label(section.rawValue, systemImage: section.symbol).tag(section)
            }
            .navigationSplitViewColumnWidth(min: 190, ideal: 210, max: 260)
            .safeAreaInset(edge: .bottom) {
                HStack(spacing: 6) {
                    Circle().fill(store.snapshot.pressure.color).frame(width: 8, height: 8)
                    Text("Thermal pressure: \(store.snapshot.pressure.title)").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(12)
            }
        } detail: {
            ScrollView {
                Group {
                    switch selection.wrappedValue ?? .overview {
                    case .overview: OverviewPage()
                    case .fans: FansPage()
                    case .power: PowerPage()
                    case .memory: MemoryPage()
                    case .network: NetworkPage()
                    case .storage: StoragePage()
                    case .aiUsage: AIUsagePage()
                    }
                }
                .padding(24)
                .frame(maxWidth: 1100)
                .frame(maxWidth: .infinity)
            }
            .background(.background)
            .navigationTitle((selection.wrappedValue ?? .overview).rawValue)
            .toolbar {
                ToolbarItem {
                    Button { SnapshotExporter.export(store.snapshot) } label: {
                        Label("Export Health Snapshot", systemImage: "square.and.arrow.up")
                    }
                    .help("Export a hardware health snapshot as JSON")
                }
            }
        }
        .frame(minWidth: 860, minHeight: 600)
        .onAppear {
            // macOS 14 can't suppress the window at launch, so close it unless the user asked for it.
            if #unavailable(macOS 15.0), !AppPresence.dashboardRequested, !AppPresence.suppressedInitialLaunch {
                AppPresence.suppressedInitialLaunch = true
                dismissWindow(id: "dashboard")
                return
            }
            AppPresence.dashboardRequested = false
            store.surface(visible: true)
            AppPresence.showInDock()
        }
        .onDisappear {
            store.surface(visible: false)
            AppPresence.hideIfNoWindows()
        }
    }
}

// MARK: - Overview

struct OverviewPage: View {
    @Environment(TelemetryStore.self) private var store
    private let columns = [GridItem(.adaptive(minimum: 230), spacing: 16)]

    var body: some View {
        let s = store.snapshot
        VStack(alignment: .leading, spacing: 16) {
            Card("Fan Control", symbol: "fan", accessory: AnyView(Text(store.controller.statusLine).font(.caption).foregroundStyle(.secondary))) {
                ModePicker(modes: FanMode.allCases, columns: 5)
                HelperBanner()
            }

            LazyVGrid(columns: columns, spacing: 16) {
                MetricTile(title: "CPU", symbol: "cpu", value: Fmt.temp(s.cpuMax).replacingOccurrences(of: "°", with: ""), unit: "°C",
                           caption: "Average \(Fmt.temp(s.cpuAverage))", tint: TempColor.color(s.cpuMax), series: store.series(.cpuTemp))
                MetricTile(title: "GPU", symbol: "display", value: Fmt.temp(s.gpuTemp).replacingOccurrences(of: "°", with: ""), unit: "°C",
                           caption: "Utilization \(Fmt.percent(s.gpu.utilization))", tint: TempColor.color(s.gpuTemp), series: store.series(.gpuTemp))
                MetricTile(title: "Fans", symbol: "fan", value: Fmt.rpm(s.averageFanRPM), unit: "rpm",
                           caption: s.fans.isEmpty ? nil : "\(Fmt.percent(s.averageFanPercent)) of maximum", tint: .blue, series: store.series(.fan0))
                MetricTile(title: "System Power", symbol: "bolt.fill", value: Fmt.watts(s.power.systemW), unit: "W",
                           caption: s.adapter.connected ? "Adapter \(Fmt.watts(s.power.dcInW, digits: 0)) W in" : "On battery", tint: .yellow, series: store.series(.systemW))
                MetricTile(title: "Memory", symbol: "memorychip", value: String(format: "%.0f", s.memory.usedFraction * 100), unit: "%",
                           caption: "\(Fmt.gbString(s.memory.usedBytes)) of \(Fmt.gbString(s.memory.totalBytes)) · \(s.memory.pressureTitle) pressure", tint: s.memory.pressure.color, series: store.series(.memUsed))
                let net = Fmt.rate(s.network.downBytesPerSec)
                MetricTile(title: "Network", symbol: "wifi", value: net.value, unit: net.unit,
                           caption: "Up \(Fmt.rate(s.network.upBytesPerSec).value) \(Fmt.rate(s.network.upBytesPerSec).unit)" + (s.network.wifi.map { " · Wi-Fi \($0.qualityTitle)" } ?? ""),
                           tint: .teal, series: store.series(.netDown))
                MetricTile(title: "SSD", symbol: "internaldrive", value: Fmt.temp(s.ssdTemp).replacingOccurrences(of: "°", with: ""), unit: "°C",
                           caption: "SMART \(s.storage.smartStatus ?? "—")", tint: TempColor.color(s.ssdTemp), series: store.series(.ssdTemp))
                let r = Fmt.rate(s.storage.readBytesPerSec + s.storage.writeBytesPerSec)
                MetricTile(title: "Disk Activity", symbol: "arrow.up.arrow.down", value: r.value, unit: r.unit,
                           caption: "Read \(Fmt.rate(s.storage.readBytesPerSec).value) · Write \(Fmt.rate(s.storage.writeBytesPerSec).value) \(Fmt.rate(s.storage.writeBytesPerSec).unit)",
                           tint: .teal, series: store.series(.diskRead))
                MetricTile(title: "Battery", symbol: s.adapter.isCharging ? "battery.100.bolt" : "battery.75", value: String(format: "%.0f", s.battery.percent), unit: "%",
                           caption: s.adapter.isCharging ? "Charging at \(Fmt.watts(s.power.batteryW)) W" : (s.adapter.connected ? "Plugged in" : "Discharging"), tint: .green, series: store.series(.batteryW))
            }
        }
    }
}

// MARK: - Fans & Thermals

struct FansPage: View {
    @Environment(TelemetryStore.self) private var store
    private let columns = [GridItem(.adaptive(minimum: 320), spacing: 16)]

    var body: some View {
        let s = store.snapshot
        let c = store.controller
        VStack(alignment: .leading, spacing: 16) {
            Card("Control", symbol: "slider.horizontal.3", accessory: AnyView(Text(c.statusLine).font(.caption).foregroundStyle(.secondary))) {
                ModePicker(modes: FanMode.allCases, columns: 5)
                Text(c.mode.detail).font(.callout).foregroundStyle(.secondary)
                HelperBanner()
                if c.mode == .manual { Divider(); ManualControls() }
                if c.mode == .curve { Divider(); CurveEditor() }
                if c.failsafeActive {
                    Label("A sensor passed \(Int(FanController.failsafeTrip)) °C — fans are forced to maximum until it cools below \(Int(FanController.failsafeRelease)) °C.", systemImage: "exclamationmark.triangle.fill")
                        .font(.callout).foregroundStyle(.orange)
                }
            }

            LazyVGrid(columns: columns, spacing: 16) {
                ForEach(s.fans) { fan in FanCard(fan: fan) }
            }

            ThermalsCard()
        }
    }
}

struct FanCard: View {
    @Environment(TelemetryStore.self) private var store
    var fan: FanReading

    var body: some View {
        let series = store.series(fan.id == 0 ? .fan0 : .fan1)
        Card(fan.name, symbol: "fan", accessory: AnyView(Pill(text: fan.isForced ? "Override" : "Automatic", color: fan.isForced ? .orange : .green))) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(Fmt.rpm(fan.rpm)).font(.system(size: 34, weight: .semibold, design: .rounded)).monospacedDigit()
                Text("rpm").font(.title3).foregroundStyle(.secondary)
                Spacer()
                Text(Fmt.percent(fan.percentOfMax)).font(.title3.weight(.medium)).monospacedDigit().foregroundStyle(.secondary)
            }
            LinearGauge(value: fan.percentOfMax / 100, tint: .blue)
            Sparkline(points: series, tint: .blue, fixedDomain: 0...max(fan.maxRPM, 1))
            Divider()
            StatRow(label: "Target", value: Fmt.rpm(fan.targetRPM), unit: "rpm")
            StatRow(label: "Minimum", value: Fmt.rpm(fan.minRPM), unit: "rpm")
            StatRow(label: "Maximum", value: Fmt.rpm(fan.maxRPM), unit: "rpm")
        }
    }
}

struct ThermalsCard: View {
    @Environment(TelemetryStore.self) private var store
    @State private var expanded: Set<TempGroup> = []

    var body: some View {
        let s = store.snapshot
        Card("Thermals", symbol: "thermometer.medium") {
            VStack(spacing: 0) {
                ForEach(TempGroup.allCases, id: \.self) { group in
                    let items = s.temps(group)
                    if !items.isEmpty { groupRow(group, items) }
                }
            }
            Text("Apple does not publish per-core labels for these SMC and PMU sensors; names above reflect which subsystem they track, not individual cores.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func groupRow(_ group: TempGroup, _ items: [TempReading]) -> some View {
        let values = items.map(\.celsius)
        let hottest = values.max() ?? 0
        let avg = values.reduce(0, +) / Double(values.count)
        let isOpen = expanded.contains(group)
        return VStack(spacing: 0) {
            Button {
                withAnimation(.snappy(duration: 0.25)) {
                    if isOpen { expanded.remove(group) } else { expanded.insert(group) }
                }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: group.symbol).frame(width: 22).foregroundStyle(TempColor.color(hottest))
                    Text(group.title)
                    Text("\(items.count)").font(.caption).foregroundStyle(.tertiary)
                    Spacer()
                    Text("avg \(Fmt.temp1(avg))").foregroundStyle(.secondary).monospacedDigit()
                    Text(Fmt.temp1(hottest)).fontWeight(.semibold).monospacedDigit().frame(width: 60, alignment: .trailing)
                    Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(isOpen ? 90 : 0))
                }
                .padding(.vertical, 9)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if isOpen {
                VStack(spacing: 4) {
                    ForEach(items.sorted { $0.celsius > $1.celsius }) { t in
                        HStack {
                            Text(t.label).foregroundStyle(.secondary)
                            Spacer()
                            Text(Fmt.temp1(t.celsius)).monospacedDigit()
                        }
                        .font(.callout)
                    }
                }
                .padding(.leading, 32).padding(.bottom, 8)
            }
            Divider()
        }
    }
}

// MARK: - Power & Battery

struct PowerPage: View {
    @Environment(TelemetryStore.self) private var store
    private let columns = [GridItem(.adaptive(minimum: 320), spacing: 16)]

    var body: some View {
        let s = store.snapshot
        VStack(alignment: .leading, spacing: 16) {
            LazyVGrid(columns: columns, spacing: 16) {
                adapterCard(s)
                systemPowerCard(s)
                batteryCard(s)
            }
            Card("Power History", symbol: "chart.xyaxis.line") {
                TimeSeriesChart(series: [
                    .init(name: "System", points: store.series(.systemW), color: .yellow),
                    .init(name: "CPU", points: store.series(.cpuW), color: .blue),
                    .init(name: "GPU", points: store.series(.gpuW), color: .pink),
                    .init(name: "Battery", points: store.series(.batteryW), color: .green),
                ], unit: "W")
            }
        }
    }

    private func adapterCard(_ s: Snapshot) -> some View {
        Card("Power Adapter", symbol: "powerplug") {
            if s.adapter.connected {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(Fmt.watts(s.adapter.ratedWatts, digits: 0)).font(.system(size: 34, weight: .semibold, design: .rounded)).monospacedDigit()
                    Text("W adapter").foregroundStyle(.secondary)
                }
                if let n = s.adapter.name { Text(n).font(.callout).foregroundStyle(.secondary) }
                Divider()
                StatRow(label: "Negotiated voltage", value: s.adapter.voltage.map { String(format: "%.1f", $0) } ?? "—", unit: "V")
                StatRow(label: "Maximum current", value: s.adapter.amperage.map { String(format: "%.2f", $0) } ?? "—", unit: "A")
                StatRow(label: "Drawing now", value: Fmt.watts(s.power.dcInW), unit: "W")
                StatRow(label: "State", value: s.adapter.isFullyCharged ? "Fully charged" : (s.adapter.isCharging ? "Charging" : "Not charging"))
            } else {
                Text("Not connected").font(.title3.weight(.medium))
                Text("Running on battery.").foregroundStyle(.secondary)
            }
        }
    }

    private func systemPowerCard(_ s: Snapshot) -> some View {
        let total = max(s.power.systemW ?? 0, 0.1)
        let rows: [(String, Double?, Color)] = [
            ("CPU", s.power.cpuW, .blue),
            ("GPU", s.power.gpuW, .pink),
            ("Neural Engine", s.power.aneW, .purple),
            ("Memory", s.power.dramW, .orange),
        ]
        return Card("System Power", symbol: "bolt.fill") {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(Fmt.watts(s.power.systemW)).font(.system(size: 34, weight: .semibold, design: .rounded)).monospacedDigit()
                Text("W total").foregroundStyle(.secondary)
            }
            Divider()
            ForEach(rows.filter { ($0.1 ?? 0) > 0.005 }, id: \.0) { row in
                VStack(spacing: 4) {
                    StatRow(label: row.0, value: Fmt.watts(row.1, digits: 2), unit: "W")
                    LinearGauge(value: (row.1 ?? 0) / total, tint: row.2)
                }
            }
            StatRow(label: "SoC package", value: Fmt.watts(s.power.packageW), unit: "W")
            StatRow(label: "Battery", value: Fmt.signedWatts(s.power.batteryW), unit: "W")
        }
    }

    private func batteryCard(_ s: Snapshot) -> some View {
        let b = s.battery
        return Card("Battery Health", symbol: "battery.100") {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(Fmt.percent(b.healthPercent).replacingOccurrences(of: "%", with: "")).font(.system(size: 34, weight: .semibold, design: .rounded)).monospacedDigit()
                Text("% maximum capacity").foregroundStyle(.secondary)
            }
            LinearGauge(value: (b.healthPercent ?? 0) / 100, tint: .green)
            Divider()
            StatRow(label: "Charge", value: String(format: "%.0f", b.percent), unit: "%")
            StatRow(label: "Remaining", value: Fmt.rpm(b.remainingMAh), unit: "mAh")
            StatRow(label: "Full charge", value: Fmt.rpm(b.fullChargeMAh), unit: "mAh")
            StatRow(label: "Design capacity", value: Fmt.rpm(b.designMAh), unit: "mAh")
            StatRow(label: "Cycle count", value: b.cycleCount.map(String.init) ?? "—")
            StatRow(label: "Condition", value: b.condition)
            StatRow(label: "Temperature", value: Fmt.temp1(s.batteryTemp))
            StatRow(label: "Pack voltage", value: b.voltage.map { String(format: "%.2f", $0) } ?? "—", unit: "V")
        }
    }
}

// MARK: - Storage & GPU

struct StoragePage: View {
    @Environment(TelemetryStore.self) private var store
    private let columns = [GridItem(.adaptive(minimum: 380), spacing: 16)]

    var body: some View {
        let s = store.snapshot
        LazyVGrid(columns: columns, spacing: 16) {
            Card("SSD", symbol: "internaldrive", accessory: AnyView(Pill(text: s.storage.smartStatus ?? "SMART —", color: s.storage.smartStatus == "Verified" ? .green : .secondary))) {
                HStack(spacing: 24) {
                    rate("Read", s.storage.readBytesPerSec, .teal)
                    rate("Write", s.storage.writeBytesPerSec, .indigo)
                }
                TimeSeriesChart(series: [
                    .init(name: "Read MB/s", points: store.series(.diskRead), color: .teal),
                    .init(name: "Write MB/s", points: store.series(.diskWrite), color: .indigo),
                ], unit: "MB/s")
                Divider()
                if let m = s.storage.model { StatRow(label: "Drive", value: m) }
                StatRow(label: "Temperature", value: Fmt.temp1(s.ssdTemp))
                StatRow(label: "Written since boot", value: Fmt.bytes(s.storage.writtenSinceBootBytes))
                StatRow(label: "Read since boot", value: Fmt.bytes(s.storage.readSinceBootBytes))
                StatRow(label: "Drive life used", value: "Not exposed")
                Text("macOS does not give apps the Apple SSD's wear counters, so lifetime Total Bytes Written and percentage used are unavailable on this Mac.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Card("GPU", symbol: "display", accessory: AnyView(Pill(text: "Thermal \(s.pressure.title)", color: s.pressure.color))) {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(Fmt.rpm(s.gpu.utilization)).font(.system(size: 34, weight: .semibold, design: .rounded)).monospacedDigit()
                    Text("% utilization").foregroundStyle(.secondary)
                }
                Sparkline(points: store.series(.gpuUtil), tint: .pink, fixedDomain: 0...100)
                Divider()
                StatRow(label: "Renderer", value: Fmt.percent(s.gpu.renderer))
                StatRow(label: "Tiler", value: Fmt.percent(s.gpu.tiler))
                StatRow(label: "Power", value: Fmt.watts(s.power.gpuW, digits: 2), unit: "W")
                StatRow(label: "Temperature", value: Fmt.temp1(s.gpuTemp))
                StatRow(label: "Memory in use", value: Fmt.bytes(s.gpu.memoryInUseBytes))
                StatRow(label: "Thermal pressure", value: s.pressure.title)
            }
        }
    }

    private func rate(_ title: String, _ bps: Double, _ tint: Color) -> some View {
        let r = Fmt.rate(bps)
        return VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(r.value).font(.system(size: 28, weight: .semibold, design: .rounded)).monospacedDigit().foregroundStyle(tint)
                Text(r.unit).foregroundStyle(.secondary)
            }
        }
    }
}
