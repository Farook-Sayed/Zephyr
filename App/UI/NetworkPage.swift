import SwiftUI

struct NetworkPage: View {
    @Environment(TelemetryStore.self) private var store
    private let columns = [GridItem(.adaptive(minimum: 320), spacing: 16, alignment: .top)]

    var body: some View {
        let n = store.snapshot.network
        VStack(alignment: .leading, spacing: 16) {
            Card("Speed", symbol: "arrow.up.arrow.down", accessory: AnyView(Pill(text: n.connected ? n.kind : "Offline", color: n.connected ? .green : .secondary))) {
                HStack(spacing: 32) {
                    rate("Download", n.downBytesPerSec, .teal, "arrow.down")
                    rate("Upload", n.upBytesPerSec, .indigo, "arrow.up")
                }
                TimeSeriesChart(series: [
                    .init(name: "Download MB/s", points: store.series(.netDown), color: .teal),
                    .init(name: "Upload MB/s", points: store.series(.netUp), color: .indigo),
                ], unit: "MB/s", domain: nil)
            }

            LazyVGrid(columns: columns, spacing: 16) {
                if let w = n.wifi { wifiCard(w) }
                connectionCard(n)
                Card("Data Since Boot", symbol: "chart.bar") {
                    StatRow(label: "Downloaded", value: Fmt.bytes(n.downSinceBootBytes))
                    StatRow(label: "Uploaded", value: Fmt.bytes(n.upSinceBootBytes))
                    Text("Counted on physical network ports only, so a VPN tunnel doesn't count twice.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func rate(_ title: String, _ bps: Double, _ tint: Color, _ symbol: String) -> some View {
        let r = Fmt.rate(bps)
        return VStack(alignment: .leading, spacing: 2) {
            Label(title, systemImage: symbol).font(.caption).foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(r.value).font(.system(size: 34, weight: .semibold, design: .rounded)).monospacedDigit().foregroundStyle(tint)
                Text(r.unit).foregroundStyle(.secondary)
            }
            Text(String(format: "%.1f Mbit/s", bps * 8 / 1_000_000)).font(.caption).foregroundStyle(.secondary).monospacedDigit()
        }
    }

    private func wifiCard(_ w: WifiInfo) -> some View {
        let tint: Color = w.rssi >= -60 ? .green : (w.rssi >= -70 ? .yellow : .orange)
        return Card("Wi-Fi", symbol: "wifi", accessory: AnyView(Pill(text: w.qualityTitle, color: tint))) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text("\(w.rssi)").font(.system(size: 34, weight: .semibold, design: .rounded)).monospacedDigit()
                Text("dBm signal").foregroundStyle(.secondary)
            }
            LinearGauge(value: w.qualityFraction, tint: tint)
            Divider()
            StatRow(label: "Noise", value: "\(w.noise)", unit: "dBm")
            StatRow(label: "Signal-to-noise", value: "\(w.snr)", unit: "dB")
            StatRow(label: "Link speed", value: String(format: "%.0f", w.txRateMbps), unit: "Mbit/s")
            StatRow(label: "Channel", value: channelText(w))
            if let phy = w.phyMode { StatRow(label: "Standard", value: phy) }
            if let sec = w.security { StatRow(label: "Security", value: sec) }
            StatRow(label: "Network name", value: w.ssid ?? "Hidden by macOS")
            if w.ssid == nil {
                Text("macOS only reveals the network name to apps with Location access. Signal, speed and channel work without it.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func channelText(_ w: WifiInfo) -> String {
        var parts: [String] = []
        if let c = w.channel { parts.append("\(c)") }
        var detail: [String] = []
        if let b = w.bandGHz { detail.append(b == 2.4 ? "2.4 GHz" : "\(Int(b)) GHz") }
        if let wd = w.widthMHz { detail.append("\(wd) MHz") }
        if !detail.isEmpty { parts.append("(\(detail.joined(separator: ", ")))") }
        return parts.isEmpty ? "—" : parts.joined(separator: " ")
    }

    private func connectionCard(_ n: NetworkInfo) -> some View {
        Card("Connection", symbol: "network") {
            StatRow(label: "Status", value: n.connected ? "Connected" : "Offline")
            StatRow(label: "Type", value: n.kind)
            StatRow(label: "Interface", value: n.primaryInterface ?? "—")
            StatRow(label: "Local IP", value: n.localIPv4 ?? "—")
            StatRow(label: "VPN", value: n.vpnActive ? "Active" : "Off")
        }
    }
}
