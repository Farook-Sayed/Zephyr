import Foundation

/// Per-domain SoC power (CPU / GPU / ANE / DRAM) from IOReport's "Energy Model" group.
/// IOReport is a private framework; it is loaded dynamically so the app degrades gracefully if it moves.
final class IOReportEnergy {
    private typealias CopyChannels = @convention(c) (CFString, CFString?, UInt64, UInt64, UInt64) -> Unmanaged<CFMutableDictionary>?
    private typealias CreateSubscription = @convention(c) (UnsafeRawPointer?, CFMutableDictionary, UnsafeMutablePointer<Unmanaged<CFMutableDictionary>?>?, UInt64, CFTypeRef?) -> UnsafeRawPointer?
    private typealias CreateSamples = @convention(c) (UnsafeRawPointer, CFMutableDictionary?, CFTypeRef?) -> Unmanaged<CFDictionary>?
    private typealias CreateDelta = @convention(c) (CFDictionary, CFDictionary, CFTypeRef?) -> Unmanaged<CFDictionary>?
    private typealias ChannelName = @convention(c) (CFDictionary) -> Unmanaged<CFString>?
    private typealias UnitLabel = @convention(c) (CFDictionary) -> Unmanaged<CFString>?
    private typealias IntValue = @convention(c) (CFDictionary, Int32) -> Int64

    private let subscription: UnsafeRawPointer
    private let subscribed: CFMutableDictionary
    private let createSamples: CreateSamples
    private let createDelta: CreateDelta
    private let channelName: ChannelName
    private let unitLabel: UnitLabel
    private let intValue: IntValue

    private var previous: CFDictionary?
    private var previousTime: Date?

    struct Watts { var cpu = 0.0, gpu = 0.0, ane = 0.0, dram = 0.0 }

    init?() {
        guard let handle = dlopen("/usr/lib/libIOReport.dylib", RTLD_NOW) else { return nil }
        func sym<T>(_ name: String, as _: T.Type) -> T? {
            guard let p = dlsym(handle, name) else { return nil }
            return unsafeBitCast(p, to: T.self)
        }
        guard let copyChannels = sym("IOReportCopyChannelsInGroup", as: CopyChannels.self),
              let subscribe = sym("IOReportCreateSubscription", as: CreateSubscription.self),
              let samples = sym("IOReportCreateSamples", as: CreateSamples.self),
              let delta = sym("IOReportCreateSamplesDelta", as: CreateDelta.self),
              let name = sym("IOReportChannelGetChannelName", as: ChannelName.self),
              let unit = sym("IOReportChannelGetUnitLabel", as: UnitLabel.self),
              let value = sym("IOReportSimpleGetIntegerValue", as: IntValue.self),
              let channels = copyChannels("Energy Model" as CFString, nil, 0, 0, 0)?.takeRetainedValue()
        else { return nil }

        var subbed: Unmanaged<CFMutableDictionary>?
        guard let sub = subscribe(nil, channels, &subbed, 0, nil), let subscribedChannels = subbed?.takeRetainedValue() else { return nil }
        subscription = sub
        subscribed = subscribedChannels
        createSamples = samples
        createDelta = delta
        channelName = name
        unitLabel = unit
        intValue = value
        previous = samples(sub, subscribedChannels, nil)?.takeRetainedValue()
        previousTime = Date()
    }

    /// Average power since the previous call.
    func read() -> Watts? {
        guard let current = createSamples(subscription, subscribed, nil)?.takeRetainedValue(),
              let previous, let previousTime else { return nil }
        let now = Date()
        defer { self.previous = current; self.previousTime = now }
        let dt = now.timeIntervalSince(previousTime)
        guard dt > 0.05, let diff = createDelta(previous, current, nil)?.takeRetainedValue(),
              let channels = (diff as NSDictionary)["IOReportChannels"] as? [CFDictionary] else { return nil }

        var w = Watts()
        for ch in channels {
            guard let name = channelName(ch)?.takeUnretainedValue() as String? else { continue }
            let unit = (unitLabel(ch)?.takeUnretainedValue() as String?) ?? ""
            let scale: Double
            switch unit.trimmingCharacters(in: .whitespaces) {
            case "mJ": scale = 1e-3
            case "uJ", "µJ": scale = 1e-6
            case "nJ": scale = 1e-9
            default: continue
            }
            let watts = Double(intValue(ch, 0)) * scale / dt
            let upper = name.uppercased()
            // The model publishes both per-cluster channels and "... Energy" aggregates; use aggregates only.
            if upper == "CPU ENERGY" { w.cpu = watts }
            else if upper == "GPU ENERGY" { w.gpu = watts }
            else if upper.hasPrefix("ANE") { w.ane += watts }
            else if upper.hasPrefix("DRAM") { w.dram += watts }
        }
        return w
    }

    /// Diagnostic: channels with a non-zero delta over one second, for `--selftest --channels`.
    func debugDeltas() -> [String] {
        guard let a = createSamples(subscription, subscribed, nil)?.takeRetainedValue() else { return [] }
        Thread.sleep(forTimeInterval: 1)
        guard let b = createSamples(subscription, subscribed, nil)?.takeRetainedValue(),
              let diff = createDelta(a, b, nil)?.takeRetainedValue(),
              let channels = (diff as NSDictionary)["IOReportChannels"] as? [CFDictionary] else { return [] }
        return channels.compactMap { ch in
            guard let n = channelName(ch)?.takeUnretainedValue() as String?, !n.contains("DTL"), !n.contains("SRAM") else { return nil }
            let v = intValue(ch, 0)
            return v == 0 ? nil : "\(n)=\(v) \((unitLabel(ch)?.takeUnretainedValue() as String?) ?? "?")"
        }
    }

    /// Diagnostic listing for `--selftest`.
    func debugChannels() -> [String] {
        guard let sample = createSamples(subscription, subscribed, nil)?.takeRetainedValue(),
              let channels = (sample as NSDictionary)["IOReportChannels"] as? [CFDictionary] else { return [] }
        return channels.compactMap { ch in
            guard let n = channelName(ch)?.takeUnretainedValue() as String? else { return nil }
            return "\(n) [\((unitLabel(ch)?.takeUnretainedValue() as String?) ?? "?")]"
        }
    }
}
