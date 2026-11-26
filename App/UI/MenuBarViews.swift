import SwiftUI

/// Live telemetry shown in the menu bar itself.
struct MenuBarLabel: View {
    @Environment(TelemetryStore.self) private var store
    @Environment(\.openWindow) private var openWindow
    @Binding var showAIUsage: Bool
    @AppStorage("pillCPU") private var showCPU = true
    @AppStorage("pillFan") private var showFan = true
    @AppStorage("pillPower") private var showPower = true
    @AppStorage("pillRAM") private var showRAM = false
    @AppStorage("pillNet") private var showNet = false

    var body: some View {
        Group {
            if showAIUsage {
                AIUsageMenuLabel(failsafeActive: store.controller.failsafeActive)
            } else {
                HStack(spacing: 5) {
                    Image(systemName: store.controller.failsafeActive ? "exclamationmark.triangle.fill" : "fan.fill")
                    if store.hasReceivedData {
                        Text(text(store.snapshot)).monospacedDigit()
                    }
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .openDashboard)) { _ in
            AppPresence.dashboardRequested = true
            AppPresence.showInDock()
            openWindow(id: "dashboard")
        }
    }

    private func text(_ s: Snapshot) -> String {
        var parts: [String] = []
        if showCPU { parts.append(Fmt.temp(s.cpuMax)) }
        if showFan { parts.append("\(Fmt.rpm(s.averageFanRPM)) rpm") }
        if showPower, let w = s.power.systemW { parts.append(String(format: "%.0f W", w)) }
        if showRAM, s.memory.totalBytes > 0 { parts.append(String(format: "%.0f%% RAM", s.memory.usedFraction * 100)) }
        if showNet { parts.append("↓\(Fmt.compactRate(s.network.downBytesPerSec)) ↑\(Fmt.compactRate(s.network.upBytesPerSec))") }
        return parts.joined(separator: " · ")
    }
}

/// The popover: mode switching, manual speed and the top vitals.
struct MenuBarContent: View {
    @Environment(TelemetryStore.self) private var store
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    @Environment(\.dismiss) private var dismiss
    @Binding var showAIUsage: Bool
    @AppStorage("dashboardSection") private var dashboardSection = DashboardSection.overview.rawValue

    var body: some View {
        let c = store.controller
        let s = store.snapshot
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Fans").font(.headline)
                Spacer()
                Pill(text: "Thermal: \(s.pressure.title)", color: s.pressure.color)
            }

            ModePicker(modes: FanMode.quick)
            if c.mode == .curve {
                Label("Custom Curve active", systemImage: FanMode.curve.symbol).font(.callout).foregroundStyle(.secondary)
            }
            HStack(spacing: 6) {
                Image(systemName: c.failsafeActive ? "exclamationmark.triangle.fill" : "info.circle")
                    .foregroundStyle(c.failsafeActive ? .orange : .secondary)
                Text(c.statusLine).font(.caption).foregroundStyle(.secondary)
            }

            if c.mode == .manual, c.helperState.isReady { ManualControls(compact: true).transition(.opacity.combined(with: .move(edge: .top))) }
            HelperBanner()

            Divider()

            Grid(horizontalSpacing: 10, verticalSpacing: 10) {
                GridRow {
                    vital("CPU", Fmt.temp(s.cpuMax), "C", symbol: "cpu", tint: TempColor.color(s.cpuMax))
                    vital("GPU", Fmt.temp(s.gpuTemp), "C", symbol: "display", tint: TempColor.color(s.gpuTemp))
                }
                GridRow {
                    vital("Fans", Fmt.rpm(s.averageFanRPM), "rpm", symbol: "fan", tint: .blue)
                    vital("System", Fmt.watts(s.power.systemW), "W", symbol: "bolt.fill", tint: .yellow)
                }
            }

            Divider()

            HStack {
                Button("Open Dashboard", action: openDashboard)
                Spacer()
                Menu {
                    Button(showAIUsage ? "Show Hardware in Menu Bar" : "Show AI Usage in Menu Bar") {
                        // Swapping the status-item label resizes the status item, which re-parents the popover.
                        // Doing that inside this menu's own action callback is unsafe, so: let the menu finish,
                        // close the popover, and only then change what the menu bar shows.
                        let target = !showAIUsage
                        DispatchQueue.main.async {
                            dismiss()
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { showAIUsage = target }
                        }
                    }
                    Button("Open AI Usage Dashboard") {
                        dashboardSection = DashboardSection.aiUsage.rawValue
                        openDashboard()
                    }
                } label: {
                    Image(systemName: "gauge.with.dots.needle.67percent")
                        .accessibilityLabel("AI Usage")
                }
                .menuIndicator(.hidden)
                .fixedSize()
                .help("AI Usage")
                Button {
                    DispatchQueue.main.async {
                        AppPresence.showInDock()
                        openSettings()
                        dismiss()
                    }
                } label: { Image(systemName: "gearshape") }
                    .help("Settings")
                Button { NSApp.terminate(nil) } label: { Image(systemName: "power") }
                    .help("Quit Zephyr")
            }
            .controlSize(.regular)
        }
        .padding(16)
        .frame(width: 340)
        .animation(.snappy(duration: 0.25), value: c.mode)
        .onAppear { store.surface(visible: true) }
        .onDisappear { store.surface(visible: false) }
    }

    private func openDashboard() {
        AppPresence.dashboardRequested = true
        // Defer past NSMenu's action callback so dismissing the MenuBarExtra popover
        // doesn't tear down its window while a menu item inside it is still unwinding.
        DispatchQueue.main.async {
            AppPresence.showInDock()
            openWindow(id: "dashboard")
            dismiss()
            DispatchQueue.main.async { NSApp.activate() }
        }
    }

    private func vital(_ title: String, _ value: String, _ unit: String, symbol: String, tint: Color) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol).foregroundStyle(tint).frame(width: 20)
            VStack(alignment: .leading, spacing: 0) {
                Text(title).font(.caption).foregroundStyle(.secondary)
                HStack(alignment: .firstTextBaseline, spacing: 2) {
                    Text(value).font(.title3.weight(.semibold)).monospacedDigit()
                    Text(unit).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .frame(maxWidth: .infinity)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}
