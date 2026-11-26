import AppKit
import SwiftUI

struct MemoryPage: View {
    @Environment(TelemetryStore.self) private var store
    @State private var pendingQuit: MemoryTip?

    var body: some View {
        let m = store.snapshot.memory
        VStack(alignment: .leading, spacing: 16) {
            Card("Memory", symbol: "memorychip", accessory: AnyView(Pill(text: "Pressure: \(m.pressureTitle)", color: m.pressure.color))) {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(String(format: "%.1f", Double(m.usedBytes) / 1_073_741_824)).font(.system(size: 34, weight: .semibold, design: .rounded)).monospacedDigit()
                    Text("GB of \(Fmt.gbString(m.totalBytes)) used").foregroundStyle(.secondary)
                    Spacer()
                    Text(String(format: "%.0f%%", m.usedFraction * 100)).font(.title3.weight(.medium)).foregroundStyle(.secondary).monospacedDigit()
                }
                MemoryBar(memory: m)
                Sparkline(points: store.series(.memUsed), tint: m.pressure.color, fixedDomain: 0...100)
                Divider()
                legend(m)
            }

            Card("Biggest Memory Users", symbol: "chart.bar.xaxis") {
                if m.topProcesses.isEmpty {
                    Text("Collecting…").foregroundStyle(.secondary)
                } else {
                    let peak = Double(m.topProcesses.first?.bytes ?? 1)
                    ForEach(m.topProcesses) { p in
                        VStack(spacing: 4) {
                            HStack {
                                Text(p.name).lineLimit(1)
                                if p.processCount > 1 { Text("\(p.processCount) processes").font(.caption).foregroundStyle(.tertiary) }
                                Spacer()
                                Text(Fmt.gbString(p.bytes)).monospacedDigit().foregroundStyle(.secondary)
                            }
                            .font(.callout)
                            LinearGauge(value: Double(p.bytes) / peak, tint: .indigo)
                        }
                    }
                    Text("Memory footprint as Activity Monitor reports it, with each app's helper processes added together.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            Card("Recommendations", symbol: "lightbulb") {
                ForEach(MemoryAdvisor.tips(for: m)) { tip in
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: tip.symbol).font(.title3).frame(width: 26)
                            .foregroundStyle(tip.severity == .warning ? .orange : (tip.severity == .good ? .green : .blue))
                        VStack(alignment: .leading, spacing: 4) {
                            Text(tip.title).font(.callout.weight(.semibold))
                            Text(tip.detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                            if let name = tip.quitName, tip.quitPath != nil {
                                Button("Quit \(name)…") { pendingQuit = tip }.controlSize(.small).padding(.top, 2)
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .confirmationDialog("Quit \(pendingQuit?.quitName ?? "app")?", isPresented: Binding(get: { pendingQuit != nil }, set: { if !$0 { pendingQuit = nil } }), titleVisibility: .visible) {
            Button("Quit", role: .destructive) { quit(pendingQuit); pendingQuit = nil }
            Button("Cancel", role: .cancel) { pendingQuit = nil }
        } message: {
            Text("The app is asked to quit normally, so it can still prompt you to save open work.")
        }
    }

    private func quit(_ tip: MemoryTip?) {
        guard let path = tip?.quitPath else { return }
        NSWorkspace.shared.runningApplications.filter { $0.bundleURL?.path == path }.forEach { $0.terminate() }
    }

    private func legend(_ m: MemoryInfo) -> some View {
        VStack(spacing: 6) {
            ForEach(MemoryBar.segments(m), id: \.name) { seg in
                HStack(spacing: 8) {
                    Circle().fill(seg.color).frame(width: 9, height: 9)
                    Text(seg.name).foregroundStyle(.secondary)
                    Spacer()
                    Text(Fmt.gbString(seg.bytes)).monospacedDigit().fontWeight(.medium)
                }
                .font(.callout)
            }
            HStack {
                Text("Swap used").foregroundStyle(.secondary)
                Spacer()
                Text(Fmt.gbString(m.swapUsedBytes)).monospacedDigit().fontWeight(.medium)
            }
            .font(.callout)
        }
    }
}

struct MemoryBar: View {
    var memory: MemoryInfo

    struct Segment { var name: String; var bytes: UInt64; var color: Color }

    static func segments(_ m: MemoryInfo) -> [Segment] {
        [Segment(name: "App Memory", bytes: m.appBytes, color: .blue),
         Segment(name: "Wired", bytes: m.wiredBytes, color: .orange),
         Segment(name: "Compressed", bytes: m.compressedBytes, color: .purple),
         Segment(name: "Cached Files", bytes: m.cachedBytes, color: .teal),
         Segment(name: "Free", bytes: m.freeBytes, color: Color.secondary.opacity(0.35))]
    }

    var body: some View {
        let segs = Self.segments(memory)
        let total = Double(max(memory.totalBytes, 1))
        GeometryReader { geo in
            HStack(spacing: 2) {
                ForEach(segs, id: \.name) { s in
                    RoundedRectangle(cornerRadius: 3, style: .continuous).fill(s.color)
                        .frame(width: max(0, geo.size.width * Double(s.bytes) / total - 2))
                }
                Spacer(minLength: 0)
            }
        }
        .frame(height: 14)
        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
    }
}
