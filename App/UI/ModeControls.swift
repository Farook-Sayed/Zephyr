import SwiftUI

// MARK: - Mode selection

struct ModePicker: View {
    @Environment(TelemetryStore.self) private var store
    var modes: [FanMode]
    var columns = 2

    var body: some View {
        let c = store.controller
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: columns), spacing: 8) {
            ForEach(modes) { mode in
                let selected = c.mode == mode
                Button {
                    withAnimation(.snappy(duration: 0.25)) { c.setMode(mode) }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: mode.symbol).font(.body.weight(.semibold)).frame(width: 20)
                        Text(mode.title).font(.callout.weight(.medium)).lineLimit(1).minimumScaleFactor(0.85)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 10).padding(.vertical, 9)
                    .foregroundStyle(selected ? Color.white : Color.primary)
                    .background(selected ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.quaternary.opacity(0.6)),
                                in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
    }
}

struct HelperBanner: View {
    @Environment(TelemetryStore.self) private var store

    var body: some View {
        let c = store.controller
        switch c.helperState {
        case .ready:
            EmptyView()
        default:
            VStack(alignment: .leading, spacing: 8) {
                Label(title(c.helperState), systemImage: "lock.shield").font(.callout.weight(.semibold))
                Text(detail(c.helperState)).font(.caption).foregroundStyle(.secondary)
                HStack {
                    if c.helperState == .requiresApproval {
                        Button("Open Login Items…") { c.openApprovalSettings() }
                    } else {
                        Button("Enable Fan Control…") { c.installHelper() }
                    }
                }
                .controlSize(.small)
                if let e = c.lastError { Text(e).font(.caption2).foregroundStyle(.red) }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }

    private func title(_ s: HelperState) -> String {
        switch s {
        case .requiresApproval: "Approval needed"
        case .notFound: "Helper not registered"
        case .unreachable: "Helper not responding"
        default: "Fan control is off"
        }
    }

    private func detail(_ s: HelperState) -> String {
        switch s {
        case .requiresApproval: "Allow “Zephyr” under System Settings → General → Login Items & Extensions."
        case .notFound: "macOS won't register helpers for ad-hoc signed builds. Sign with a developer certificate, or run scripts/install-helper.sh once in Terminal."
        case .unreachable(let m): m
        default: "Reading sensors works as-is. Changing fan speed needs a small background helper — you approve it once."
        }
    }
}

// MARK: - Manual control

struct ManualControls: View {
    @Environment(TelemetryStore.self) private var store
    var compact = false

    private let detents: [Double] = [25, 50, 75, 100]

    var body: some View {
        let c = store.controller
        let fans = store.snapshot.fans
        VStack(alignment: .leading, spacing: compact ? 8 : 14) {
            if fans.count > 1 {
                Toggle("Sync All Fans", isOn: Binding(get: { c.syncAll }, set: { c.syncAll = $0 }))
                    .toggleStyle(.switch).controlSize(.small)
            }
            if c.syncAll || fans.count <= 1, let first = fans.first {
                FanSlider(fan: first, label: fans.count > 1 ? "All Fans" : first.name, fans: fans, detents: detents, compact: compact)
            } else {
                ForEach(fans) { fan in
                    FanSlider(fan: fan, label: fan.name, fans: fans, detents: detents, compact: compact)
                }
            }
        }
    }
}

struct FanSlider: View {
    @Environment(TelemetryStore.self) private var store
    var fan: FanReading
    var label: String
    var fans: [FanReading]
    var detents: [Double]
    var compact: Bool

    @State private var lastDetent: Double?
    @FocusState private var rpmFocused: Bool
    @FocusState private var pctFocused: Bool

    private var minPercent: Double {
        // In sync mode every fan must be able to reach the value.
        let c = store.controller
        let relevant = c.syncAll ? fans : [fan]
        return (relevant.map { $0.minRPM / max($0.maxRPM, 1) * 100 }.max() ?? 0).rounded(.up)
    }

    private var percent: Double { min(max(store.controller.percent(forFan: fan.id, fan: fan), minPercent), 100) }
    private var activeDetents: [Double] { detents.filter { $0 >= minPercent } }

    private func set(_ raw: Double, snap allowSnap: Bool = true) {
        var v = min(max(raw, minPercent), 100)
        // Magnetic detents (slider only): lock exactly onto 25/50/75/100 %. Typed values are taken as entered.
        if allowSnap, let snap = activeDetents.first(where: { abs($0 - v) < 1.6 }) {
            v = snap
            if lastDetent != snap { Haptics.detent(); lastDetent = snap }
        } else {
            lastDetent = nil
        }
        store.controller.setManualPercent(v.rounded(), fan: fan.id, fans: fans)
    }

    var body: some View {
        let maxRPM = max(fan.maxRPM, 1)
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(label).font(compact ? .callout : .body.weight(.medium))
                Spacer()
                if store.snapshot.fans.isEmpty == false {
                    Text("now \(Fmt.rpm(fan.rpm)) rpm").font(.caption).foregroundStyle(.secondary).monospacedDigit()
                }
            }
            tickSlider(maxRPM: maxRPM)
            .labelsHidden()
            .accessibilityValue("\(Int(percent)) percent, \(Int(percent / 100 * maxRPM)) RPM")

            HStack(spacing: 14) {
                numberField(title: "RPM", value: Binding(
                    get: { (percent / 100 * maxRPM).rounded() },
                    set: { set($0 / maxRPM * 100, snap: false) }), width: 64, focus: $rpmFocused)
                numberField(title: "% of max", value: Binding(
                    get: { percent },
                    set: { set($0, snap: false) }), width: 48, focus: $pctFocused)
                Spacer()
                Text("\(Fmt.rpm(fan.minRPM))–\(Fmt.rpm(fan.maxRPM)) rpm")
                    .font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
            .font(.callout)
        }
    }

    /// Native tick marks arrive in macOS 26; older systems get the plain slider (detent haptics still work).
    @ViewBuilder
    private func tickSlider(maxRPM: Double) -> some View {
        let binding = Binding(get: { percent }, set: { set($0) })
        if #available(macOS 26.0, *) {
            Slider(value: binding, in: minPercent...100) {
                Text(label)
            } ticks: {
                SliderTickContentForEach(activeDetents, id: \.self) { value in
                    SliderTick(value)
                }
            }
        } else {
            Slider(value: binding, in: minPercent...100) { Text(label) }
        }
    }

    private func numberField(title: String, value: Binding<Double>, width: CGFloat, focus: FocusState<Bool>.Binding) -> some View {
        HStack(spacing: 5) {
            TextField(title, value: value, format: .number.precision(.fractionLength(0)))
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.trailing)
                .monospacedDigit()
                .frame(width: width)
                .focused(focus)
            Text(title).foregroundStyle(.secondary).font(.caption)
        }
    }
}
