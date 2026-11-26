import Foundation

/// Identifiers shared by the app and its privileged helper.
public enum HelperConstants {
    public static let appBundleID = "app.zephyr.Zephyr"
    public static let machService = "app.zephyr.Zephyr.helper"
    public static let daemonPlist = "app.zephyr.Zephyr.helper.plist"
    public static let helperVersion = "1.0"
    /// If the app stops talking to the helper for this long while fans are overridden, the helper
    /// hands fan control back to macOS on its own.
    public static let clientTimeout: TimeInterval = 20
    /// Independent hardware over-temperature limit enforced inside the helper (°C).
    public static let criticalTemperature: Double = 95
    public static let criticalRelease: Double = 88
}

/// XPC surface exposed by the root helper. Only SMC fan registers can be written through it.
@objc(ZephyrHelperProtocol)
public protocol ZephyrHelperProtocol {
    func version(reply: @escaping (String) -> Void)
    /// Index-aligned fan targets in RPM. A negative value returns that fan to automatic control.
    func setFanTargets(_ rpms: [NSNumber], reply: @escaping (String?) -> Void)
    func restoreAutomatic(reply: @escaping (String?) -> Void)
    /// `override` (0/1), `failsafe` (0/1), `maxTemp` (°C).
    func status(reply: @escaping ([String: NSNumber]) -> Void)
}
