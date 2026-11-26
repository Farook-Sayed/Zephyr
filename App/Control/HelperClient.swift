import Foundation
import ServiceManagement

enum HelperState: Equatable {
    case notInstalled
    case requiresApproval
    case ready
    case unreachable(String)
    case notFound

    var isReady: Bool { self == .ready }
}

/// App-side end of the privileged helper: registration (SMAppService) and XPC.
@MainActor
final class HelperClient {
    private let daemon = SMAppService.daemon(plistName: HelperConstants.daemonPlist)
    private var connection: NSXPCConnection?

    var registrationState: HelperState {
        switch daemon.status {
        case .notRegistered: .notInstalled
        case .requiresApproval: .requiresApproval
        case .enabled: .ready
        case .notFound: .notFound
        @unknown default: .notFound
        }
    }

    /// Registers the daemon. macOS then asks the user to approve it once in System Settings → Login Items.
    func register() throws {
        try daemon.register()
    }

    func unregister() async throws {
        try await daemon.unregister()
        connection?.invalidate()
        connection = nil
    }

    func openApprovalSettings() { SMAppService.openSystemSettingsLoginItems() }

    // MARK: XPC

    private func makeConnection() -> NSXPCConnection {
        if let connection { return connection }
        let c = NSXPCConnection(machServiceName: HelperConstants.machService, options: .privileged)
        c.remoteObjectInterface = NSXPCInterface(with: ZephyrHelperProtocol.self)
        // Only clear the stored connection if it is still this one; a newer connection must survive a late callback.
        c.invalidationHandler = { [weak self, weak c] in Task { @MainActor in if self?.connection === c { self?.connection = nil } } }
        c.interruptionHandler = { [weak self, weak c] in
            Task { @MainActor in
                if self?.connection === c { self?.connection = nil }
                c?.invalidate()
            }
        }
        c.resume()
        connection = c
        return c
    }

    private func perform<T>(_ body: @escaping (ZephyrHelperProtocol, @escaping (T) -> Void) -> Void,
                            onFailure: @escaping (Error) -> T) async -> T {
        let c = makeConnection()
        return await withCheckedContinuation { (cont: CheckedContinuation<T, Never>) in
            let gate = OnceGate()
            let proxy = c.remoteObjectProxyWithErrorHandler { error in
                if gate.claim() { cont.resume(returning: onFailure(error)) }
            } as? ZephyrHelperProtocol
            guard let proxy else {
                if gate.claim() { cont.resume(returning: onFailure(CocoaError(.xpcConnectionInvalid))) }
                return
            }
            body(proxy) { value in
                if gate.claim() { cont.resume(returning: value) }
            }
        }
    }

    /// Returns an error description, or nil on success.
    func setFanTargets(_ rpms: [Double]) async -> String? {
        let numbers = rpms.map { NSNumber(value: $0) }
        return await perform({ proxy, reply in proxy.setFanTargets(numbers, reply: reply) },
                             onFailure: { "\($0.localizedDescription)" })
    }

    func restoreAutomatic() async -> String? {
        await perform({ proxy, reply in proxy.restoreAutomatic(reply: reply) },
                      onFailure: { "\($0.localizedDescription)" })
    }

    func ping() async -> String? {
        await perform({ proxy, reply in proxy.version { reply($0) } }, onFailure: { _ in nil })
    }
}

private final class OnceGate: @unchecked Sendable {
    private let lock = NSLock()
    private var used = false
    func claim() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if used { return false }
        used = true
        return true
    }
}
