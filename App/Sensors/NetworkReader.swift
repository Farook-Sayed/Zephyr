import CoreWLAN
import Darwin
import Foundation
import SystemConfiguration

struct WifiInfo: Codable, Sendable, Equatable {
    var interfaceName: String
    var ssid: String?            // nil unless Location access is granted (macOS privacy rule)
    var rssi: Int                // dBm
    var noise: Int               // dBm
    var txRateMbps: Double
    var channel: Int?
    var bandGHz: Double?
    var widthMHz: Int?
    var phyMode: String?
    var security: String?

    var snr: Int { rssi - noise }

    var qualityTitle: String {
        switch rssi {
        case 0...: "No signal"
        case (-50)...: "Excellent"
        case (-60)...: "Good"
        case (-70)...: "Fair"
        default: "Weak"
        }
    }
    /// 0...1 for gauges.
    var qualityFraction: Double { min(max((Double(rssi) + 95) / 55, 0), 1) }
}

struct NetworkInfo: Codable, Sendable, Equatable {
    var connected = false
    var primaryInterface: String?
    var kind = "Offline"          // Wi-Fi / Ethernet / Other
    var downBytesPerSec: Double = 0
    var upBytesPerSec: Double = 0
    var downSinceBootBytes: Double = 0
    var upSinceBootBytes: Double = 0
    var vpnActive = false
    var localIPv4: String?
    var wifi: WifiInfo?

    static let empty = NetworkInfo()
}

/// Throughput from 64-bit interface counters (the 32-bit `getifaddrs` counters wrap every 4 GiB), plus Wi-Fi link
/// quality from CoreWLAN. Only physical interfaces are summed so a VPN tunnel doesn't double-count traffic.
final class NetworkReader {
    private var lastCounters: [String: (rx: UInt64, tx: UInt64)] = [:]
    private var lastDate: Date?
    private var tick = 0
    private var cachedWifi: WifiInfo?
    private let store = SCDynamicStoreCreate(nil, "Zephyr" as CFString, nil, nil)

    func read(includeWifi: Bool) -> NetworkInfo {
        var info = NetworkInfo()
        let counters = Self.interfaceCounters()
        let now = Date()

        var rx: UInt64 = 0, tx: UInt64 = 0, dRx: UInt64 = 0, dTx: UInt64 = 0
        for (name, c) in counters where Self.isPhysical(name) {
            rx += c.rx; tx += c.tx
            if let prev = lastCounters[name] {
                // A lower value means the interface was reset or re-created: skip rather than go negative.
                if c.rx >= prev.rx { dRx += c.rx - prev.rx }
                if c.tx >= prev.tx { dTx += c.tx - prev.tx }
            }
        }
        if let last = lastDate {
            let dt = max(now.timeIntervalSince(last), 0.001)
            info.downBytesPerSec = Double(dRx) / dt
            info.upBytesPerSec = Double(dTx) / dt
        }
        lastCounters = counters.filter { Self.isPhysical($0.key) }
        lastDate = now
        info.downSinceBootBytes = Double(rx)
        info.upSinceBootBytes = Double(tx)

        // Primary interface and address.
        if let store, let global = SCDynamicStoreCopyValue(store, "State:/Network/Global/IPv4" as CFString) as? [String: Any],
           let primary = global["PrimaryInterface"] as? String {
            info.connected = true
            info.primaryInterface = primary
        }
        let addresses = Self.ipv4Addresses()
        info.vpnActive = addresses.keys.contains { $0.hasPrefix("utun") }
        if let p = info.primaryInterface { info.localIPv4 = addresses[p] }

        let client = CWWiFiClient.shared()
        let wifiName = client.interface()?.interfaceName
        if let p = info.primaryInterface {
            info.kind = (p == wifiName) ? "Wi-Fi" : (p.hasPrefix("en") ? "Ethernet" : (p.hasPrefix("utun") ? "VPN" : "Other"))
        }

        // CoreWLAN is an XPC round trip; refresh every few polls unless the UI is open.
        tick += 1
        if includeWifi || tick % 5 == 1 { cachedWifi = Self.readWifi(client) }
        info.wifi = cachedWifi
        return info
    }

    // MARK: Helpers

    /// Real hardware only: en0/en1…, excluding Apple's virtual en-style interfaces such as bridges and AWDL.
    private static func isPhysical(_ name: String) -> Bool {
        guard name.hasPrefix("en"), name.dropFirst(2).allSatisfy(\.isNumber) else { return false }
        return true
    }

    /// Full 64-bit byte counters per physical interface, from the per-interface IFMIB record (the same source
    /// `netstat -ib` uses). `if_data64` sits at byte 52 in that record (packed to 4 bytes), so `ifi_ibytes` is at
    /// 52 + 64 = 116 and `ifi_obytes` at 124. The routing-socket IFLIST2 record truncates received bytes to 32 bits.
    private static func interfaceCounters() -> [String: (rx: UInt64, tx: UInt64)] {
        guard let list = if_nameindex() else { return [:] }
        defer { if_freenameindex(list) }
        var result: [String: (UInt64, UInt64)] = [:]
        var entry = list
        while entry.pointee.if_index != 0, let namePtr = entry.pointee.if_name {
            defer { entry += 1 }
            let name = String(cString: namePtr)
            guard isPhysical(name) else { continue }
            var mib: [Int32] = [CTL_NET, PF_LINK, 0 /* NETLINK_GENERIC */, 2 /* IFMIB_IFDATA */, Int32(entry.pointee.if_index), 1 /* IFDATA_GENERAL */]
            var length = 0
            guard sysctl(&mib, UInt32(mib.count), nil, &length, nil, 0) == 0, length >= 132 else { continue }
            var buffer = [UInt8](repeating: 0, count: length)
            guard sysctl(&mib, UInt32(mib.count), &buffer, &length, nil, 0) == 0 else { continue }
            buffer.withUnsafeBytes { raw in
                result[name] = (raw.loadUnaligned(fromByteOffset: 116, as: UInt64.self),
                                raw.loadUnaligned(fromByteOffset: 124, as: UInt64.self))
            }
        }
        return result
    }

    private static func ipv4Addresses() -> [String: String] {
        var out: [String: String] = [:]
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return out }
        defer { freeifaddrs(head) }
        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let ifa = ptr.pointee
            guard let sa = ifa.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET), (ifa.ifa_flags & UInt32(IFF_UP)) != 0 else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(sa, socklen_t(sa.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                out[String(cString: ifa.ifa_name)] = String(cString: host)
            }
        }
        return out
    }

    private static func readWifi(_ client: CWWiFiClient) -> WifiInfo? {
        guard let i = client.interface(), i.powerOn(), let name = i.interfaceName else { return nil }
        let rssi = i.rssiValue()
        guard rssi != 0 else { return nil } // not associated
        var band: Double?, width: Int?, number: Int?
        if let ch = i.wlanChannel() {
            number = ch.channelNumber
            switch ch.channelBand {
            case .band2GHz: band = 2.4
            case .band5GHz: band = 5
            case .band6GHz: band = 6
            default: break
            }
            switch ch.channelWidth {
            case .width20MHz: width = 20
            case .width40MHz: width = 40
            case .width80MHz: width = 80
            case .width160MHz: width = 160
            default: break
            }
        }
        let phy: String? = {
            switch i.activePHYMode() {
            case .mode11a: "802.11a"
            case .mode11b: "802.11b"
            case .mode11g: "802.11g"
            case .mode11n: "Wi-Fi 4 (802.11n)"
            case .mode11ac: "Wi-Fi 5 (802.11ac)"
            case .mode11ax: "Wi-Fi 6 (802.11ax)"
            default: nil
            }
        }()
        let security: String? = {
            switch i.security() {
            case .none: "Open"
            case .WEP: "WEP"
            case .wpaPersonal, .wpaPersonalMixed: "WPA Personal"
            case .wpa2Personal: "WPA2 Personal"
            case .personal: "Personal"
            case .wpa3Personal: "WPA3 Personal"
            case .wpa3Transition: "WPA3 Transition"
            case .wpaEnterprise, .wpaEnterpriseMixed: "WPA Enterprise"
            case .wpa2Enterprise: "WPA2 Enterprise"
            case .enterprise: "Enterprise"
            case .wpa3Enterprise: "WPA3 Enterprise"
            default: nil
            }
        }()
        return WifiInfo(interfaceName: name, ssid: i.ssid(), rssi: rssi, noise: i.noiseMeasurement(),
                        txRateMbps: i.transmitRate(), channel: number, bandGHz: band, widthMHz: width,
                        phyMode: phy, security: security)
    }
}
