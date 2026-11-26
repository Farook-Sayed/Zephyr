import Foundation
import IOKit

// MARK: - Wire format (matches the AppleSMC user client's 80-byte parameter block)

private struct SMCVers { var major: UInt8 = 0, minor: UInt8 = 0, build: UInt8 = 0, reserved: UInt8 = 0, release: UInt16 = 0 }
private struct SMCPLimit { var version: UInt16 = 0, length: UInt16 = 0, cpu: UInt32 = 0, gpu: UInt32 = 0, mem: UInt32 = 0 }
private struct SMCKeyInfoData { var dataSize: UInt32 = 0, dataType: UInt32 = 0, dataAttributes: UInt8 = 0 }

private typealias SMCBytes = (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                              UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                              UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                              UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8)

private struct SMCParam {
    var key: UInt32 = 0
    var vers = SMCVers()
    var pLimit = SMCPLimit()
    var keyInfo = SMCKeyInfoData()
    var padding: UInt16 = 0
    var result: UInt8 = 0
    var status: UInt8 = 0
    var data8: UInt8 = 0
    var data32: UInt32 = 0
    var bytes: SMCBytes = (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
                           0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
}

private enum SMCCommand: UInt8 {
    case readKey = 5, writeKey = 6, keyAtIndex = 8, keyInfo = 9
}

private func fourCC(_ s: String) -> UInt32 {
    var v: UInt32 = 0
    for b in s.utf8.prefix(4) { v = (v << 8) | UInt32(b) }
    return v
}

private func fourCCString(_ v: UInt32) -> String {
    String(decoding: [UInt8(v >> 24), UInt8((v >> 16) & 0xFF), UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)], as: UTF8.self)
}

// MARK: - Public value type

public struct SMCValue: Sendable {
    public let key: String
    public let type: String
    public let bytes: [UInt8]

    /// Numeric interpretation for the SMC data types we care about.
    public var number: Double? {
        switch type {
        case "flt " where bytes.count == 4:
            return Double(Float(bitPattern: bytes.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }))
        case "ui8 " where bytes.count == 1:
            return Double(bytes[0])
        case "ui16" where bytes.count == 2:
            return Double(UInt16(bytes[0]) << 8 | UInt16(bytes[1]))
        case "ui32" where bytes.count == 4:
            return Double(bytes.reduce(UInt32(0)) { $0 << 8 | UInt32($1) })
        case "si16" where bytes.count == 2:
            return Double(Int16(bitPattern: UInt16(bytes[0]) << 8 | UInt16(bytes[1])))
        case "sp78" where bytes.count == 2:
            return Double(Int16(bitPattern: UInt16(bytes[0]) << 8 | UInt16(bytes[1]))) / 256
        case "fpe2" where bytes.count == 2:
            return Double(UInt16(bytes[0]) << 8 | UInt16(bytes[1])) / 4
        default:
            return nil
        }
    }
}

public enum SMCError: Error, CustomStringConvertible {
    case notFound(String)
    case notPermitted(String)
    case failed(String, UInt8)

    public var description: String {
        switch self {
        case .notFound(let k): return "SMC key \(k) not found"
        case .notPermitted(let k): return "SMC refused write to \(k) (privileges)"
        case .failed(let k, let r): return "SMC write to \(k) failed (0x\(String(r, radix: 16)))"
        }
    }
}

// MARK: - Connection

/// Thin, thread-safe wrapper around the AppleSMC IOKit user client. Reading needs no privileges;
/// writing fan registers requires root (the privileged helper).
public final class SMC: @unchecked Sendable {
    private var connection: io_connect_t = 0
    private let lock = NSLock()
    private var infoCache: [UInt32: SMCKeyInfoData] = [:]

    public init?() {
        guard MemoryLayout<SMCParam>.stride == 80 else { return nil }
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        guard IOServiceOpen(service, mach_task_self_, 0, &connection) == KERN_SUCCESS else { return nil }
    }

    deinit { if connection != 0 { IOServiceClose(connection) } }

    private func call(_ param: inout SMCParam) -> Bool {
        var output = SMCParam()
        var size = MemoryLayout<SMCParam>.stride
        let kr = IOConnectCallStructMethod(connection, 2, &param, MemoryLayout<SMCParam>.stride, &output, &size)
        param = output
        return kr == KERN_SUCCESS
    }

    private func info(for key: UInt32) -> SMCKeyInfoData? {
        if let cached = infoCache[key] { return cached }
        var p = SMCParam()
        p.key = key
        p.data8 = SMCCommand.keyInfo.rawValue
        guard call(&p), p.result == 0 else { return nil }
        infoCache[key] = p.keyInfo
        return p.keyInfo
    }

    public func read(_ name: String) -> SMCValue? {
        lock.lock(); defer { lock.unlock() }
        return readLocked(name)
    }

    private func readLocked(_ name: String) -> SMCValue? {
        let key = fourCC(name)
        guard let ki = info(for: key) else { return nil }
        var p = SMCParam()
        p.key = key
        p.keyInfo.dataSize = ki.dataSize
        p.data8 = SMCCommand.readKey.rawValue
        guard call(&p), p.result == 0 else { return nil }
        let size = min(Int(ki.dataSize), 32)
        let bytes = withUnsafeBytes(of: p.bytes) { Array($0.prefix(size)) }
        return SMCValue(key: name, type: fourCCString(ki.dataType), bytes: bytes)
    }

    public func number(_ name: String) -> Double? { read(name)?.number }

    public func exists(_ name: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return info(for: fourCC(name)) != nil
    }

    public func write(_ name: String, bytes: [UInt8]) throws {
        lock.lock(); defer { lock.unlock() }
        let key = fourCC(name)
        guard let ki = info(for: key) else { throw SMCError.notFound(name) }
        var p = SMCParam()
        p.key = key
        p.keyInfo.dataSize = ki.dataSize
        p.data8 = SMCCommand.writeKey.rawValue
        let count = min(Int(ki.dataSize), 32, bytes.count)
        withUnsafeMutableBytes(of: &p.bytes) { raw in
            for i in 0..<count { raw[i] = bytes[i] }
        }
        guard call(&p) else { throw SMCError.failed(name, 0xFF) }
        if p.result == 0x82 { throw SMCError.notPermitted(name) }
        if p.result != 0 { throw SMCError.failed(name, p.result) }
    }

    public func writeFloat(_ name: String, _ value: Float) throws {
        let bits = value.bitPattern
        try write(name, bytes: [UInt8(bits & 0xFF), UInt8((bits >> 8) & 0xFF), UInt8((bits >> 16) & 0xFF), UInt8(bits >> 24)])
    }

    /// Writes a number using the key's own data type (Apple Silicon uses `flt `, Intel Macs use `fpe2`).
    public func writeNumber(_ name: String, _ value: Double) throws {
        guard let current = read(name) else { throw SMCError.notFound(name) }
        switch current.type {
        case "fpe2":
            let raw = UInt16(min(max(value * 4, 0), 65535))
            try write(name, bytes: [UInt8(raw >> 8), UInt8(raw & 0xFF)])
        case "ui16":
            let raw = UInt16(min(max(value, 0), 65535))
            try write(name, bytes: [UInt8(raw >> 8), UInt8(raw & 0xFF)])
        case "flt ":
            try writeFloat(name, Float(value))
        default:
            throw SMCError.failed(name, 0xFE) // unknown register type: refuse rather than write garbage
        }
    }

    public func writeByte(_ name: String, _ value: UInt8) throws { try write(name, bytes: [value]) }

    /// Every key name published by the SMC (a few thousand on Apple Silicon).
    public func allKeys() -> [String] {
        lock.lock(); defer { lock.unlock() }
        guard let count = readLocked("#KEY")?.number else { return [] }
        var names: [String] = []
        names.reserveCapacity(Int(count))
        for i in 0..<Int(count) {
            var p = SMCParam()
            p.data8 = SMCCommand.keyAtIndex.rawValue
            p.data32 = UInt32(i)
            if call(&p), p.result == 0 { names.append(fourCCString(p.key)) }
        }
        return names
    }
}

// MARK: - Fan register helpers shared by app (read) and helper (write)

public struct FanLimits: Sendable {
    public let index: Int
    public let minRPM: Double
    public let maxRPM: Double
}

public extension SMC {
    var fanCount: Int { Int(number("FNum") ?? 0) }

    func fanLimits() -> [FanLimits] {
        (0..<fanCount).compactMap { i in
            guard let mn = number("F\(i)Mn"), let mx = number("F\(i)Mx"), mx > 0 else { return nil }
            return FanLimits(index: i, minRPM: mn, maxRPM: mx)
        }
    }
}
