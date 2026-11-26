import Foundation
import IOKit

// The HID event system exposes the PMU die sensors on Apple Silicon. These symbols live in IOKit but
// are not in the public headers, so they are bound by name.
private typealias HIDRef = CFTypeRef

@_silgen_name("IOHIDEventSystemClientCreate")
private func IOHIDEventSystemClientCreate(_ allocator: CFAllocator?) -> Unmanaged<HIDRef>?
@_silgen_name("IOHIDEventSystemClientSetMatching")
private func IOHIDEventSystemClientSetMatching(_ client: HIDRef, _ matching: CFDictionary) -> Int32
@_silgen_name("IOHIDEventSystemClientCopyServices")
private func IOHIDEventSystemClientCopyServices(_ client: HIDRef) -> Unmanaged<CFArray>?
@_silgen_name("IOHIDServiceClientCopyProperty")
private func IOHIDServiceClientCopyProperty(_ service: HIDRef, _ key: CFString) -> Unmanaged<CFTypeRef>?
@_silgen_name("IOHIDServiceClientCopyEvent")
private func IOHIDServiceClientCopyEvent(_ service: HIDRef, _ type: Int64, _ matching: CFTypeRef?, _ options: UInt32) -> Unmanaged<HIDRef>?
@_silgen_name("IOHIDEventGetFloatValue")
private func IOHIDEventGetFloatValue(_ event: HIDRef, _ field: Int32) -> Double

/// Reads the `PMU tdie*` / `PMU tdev*` / gas-gauge temperature services.
final class HIDTemperatures {
    private let client: HIDRef
    private var services: [(name: String, ref: HIDRef)] = []

    private static let temperatureEventType: Int64 = 15
    private static let temperatureField: Int32 = 15 << 16

    init?() {
        guard let c = IOHIDEventSystemClientCreate(kCFAllocatorDefault)?.takeRetainedValue() else { return nil }
        client = c
        let matching: [String: Any] = ["PrimaryUsagePage": 0xFF00, "PrimaryUsage": 5]
        _ = IOHIDEventSystemClientSetMatching(client, matching as CFDictionary)
        guard let list = IOHIDEventSystemClientCopyServices(client)?.takeRetainedValue() as? [HIDRef] else { return nil }
        for s in list {
            if let name = IOHIDServiceClientCopyProperty(s, "Product" as CFString)?.takeRetainedValue() as? String {
                // Keep only the services read() uses; polling every matching sensor is wasted IPC.
                if name.hasPrefix("PMU tdie") || name.hasPrefix("PMU tdev") || name == "gas gauge battery" { services.append((name, s)) }
            }
        }
        if services.isEmpty { return nil }
    }

    func read() -> [TempReading] {
        var out: [TempReading] = []
        for (index, (name, ref)) in services.enumerated() {
            guard let event = IOHIDServiceClientCopyEvent(ref, Self.temperatureEventType, nil, 0)?.takeRetainedValue() else { continue }
            let c = IOHIDEventGetFloatValue(event, Self.temperatureField)
            guard c > 5, c < 150 else { continue }
            if name.hasPrefix("PMU tdie") {
                let n = name.replacingOccurrences(of: "PMU tdie", with: "")
                out.append(TempReading(id: "hid.\(name)", label: "CPU Die \(n)", group: .cpu, celsius: c))
            } else if name == "gas gauge battery" {
                out.append(TempReading(id: "hid.gauge.\(index)", label: "Battery Gauge", group: .battery, celsius: c))
            } else if name.hasPrefix("PMU tdev") {
                let n = name.replacingOccurrences(of: "PMU tdev", with: "")
                out.append(TempReading(id: "hid.\(name)", label: "Board \(n)", group: .other, celsius: c))
            }
        }
        return out
    }
}
