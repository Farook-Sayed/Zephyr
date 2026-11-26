import Darwin
import Foundation

enum ClaudeStatusLine {
    /// Legacy collector flag: status lines configured by an earlier version run the whole app with this flag.
    /// It still works (slowly); copying the setup again switches to the fast `ZephyrUsage` helper.
    static let flag = "--record-claude-usage"

    static var snapshotURL: URL { ClaudeUsageRecorder.snapshotURL }

    /// Path of the lightweight recorder bundled next to the app executable.
    static var recorderPath: String? {
        Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("ZephyrUsage").path
    }

    /// True when the app lives somewhere stable. A path inside Xcode's DerivedData disappears on clean.
    static var isInstalledInApplications: Bool {
        let path = Bundle.main.bundleURL.path
        return path.hasPrefix("/Applications/") || path.hasPrefix(NSHomeDirectory() + "/Applications/")
    }

    /// Invoked by Claude Code (legacy path) before Zephyr starts any UI or hardware services.
    static func run() -> Never {
        let input = FileHandle.standardInput.readDataToEndOfFile()
        if UserDefaults.standard.bool(forKey: "claudeUsageEnabled") {
            try? ClaudeUsageRecorder.record(input)
        }
        exit(EXIT_SUCCESS)
    }

    private static let wrapperPrefix = "zephyr_input=$(/bin/cat);"
    private static let wrapperMarker = "\"$zephyr_input\" | (\n"

    private static func isZephyrCollector(_ command: String) -> Bool {
        command.contains(flag) || command.contains("ZephyrUsage")
    }

    /// The user's own status-line command with any earlier Zephyr collector (old flag or `ZephyrUsage`, bare or
    /// wrapped by a previous copy) removed, so re-copying the setup replaces Zephyr's entry instead of stacking it.
    static func userCommand(from existing: String?) -> String? {
        var current = (existing ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        while current.hasPrefix(wrapperPrefix) {
            guard let marker = current.range(of: wrapperMarker), current.hasSuffix("\n)") else { return current }
            current = String(current[marker.upperBound...].dropLast(2)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return current.isEmpty || isZephyrCollector(current) ? nil : current
    }

    static func command(for executable: String, preserving existing: String?) -> String {
        let collector = shellQuote(executable)
        guard let user = userCommand(from: existing) else { return collector }
        // Both commands receive the complete input. The user's command still controls stdout and exit status.
        return "\(wrapperPrefix) printf '%s' \"$zephyr_input\" | \(collector); printf '%s' \(wrapperMarker)\(user)\n)"
    }

    static func existingCommand() -> String? {
        let configDirectory = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"].flatMap { $0.isEmpty ? nil : $0 }
        let config = (configDirectory.map { URL(fileURLWithPath: $0) }
                      ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude"))
            .appendingPathComponent("settings.json")
        guard let data = try? Data(contentsOf: config),
              let settings = try? JSONDecoder().decode(Settings.self, from: data) else { return nil }
        return settings.statusLine?.command
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private struct Settings: Decodable {
        struct StatusLine: Decodable { let command: String? }
        let statusLine: StatusLine?
    }
}

/// Passive reader for Claude Code's cached `/usage` snapshot in `~/.claude.json` (`cachedUsageUtilization`).
/// Zero setup and zero network: only checks file mtime/size unless the file changed.
final class ClaudeConfigCache: @unchecked Sendable {
    private let configURL: URL
    private let lock = NSLock()
    private var signature = ""
    private var cached: AIQuotaReading?

    init() {
        let dir = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"].flatMap { $0.isEmpty ? nil : $0 }
        let base = dir.map { URL(fileURLWithPath: $0, isDirectory: true) } ?? FileManager.default.homeDirectoryForCurrentUser
        self.configURL = base.appendingPathComponent(".claude.json")
    }

    func latest() -> AIQuotaReading? {
        guard let values = try? configURL.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]),
              let mtime = values.contentModificationDate else {
            lock.lock(); signature = ""; cached = nil; lock.unlock()
            return nil
        }
        let sig = "\(mtime.timeIntervalSince1970)|\(values.fileSize ?? 0)"
        lock.lock()
        if sig == signature { defer { lock.unlock() }; return cached }
        lock.unlock()

        let reading = Self.parse(url: configURL, fallbackDate: mtime)
        lock.lock(); signature = sig; cached = reading; lock.unlock()
        return reading
    }

    private struct Document: Decodable {
        struct Account: Decodable { let accountUuid: String? }
        struct CachedUsage: Decodable {
            let fetchedAtMs: Double?
            let accountUuid: String?
            let utilization: Utilization?
        }
        struct Utilization: Decodable {
            let five_hour: Window?
            let seven_day: Window?
            let seven_day_opus: Window?
            let seven_day_sonnet: Window?
        }
        struct Window: Decodable {
            let utilization: Double?
            let resets_at: String?
        }

        let oauthAccount: Account?
        let cachedUsageUtilization: CachedUsage?
    }

    private static let isoWithFractional = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
    private static let isoStandard = Date.ISO8601FormatStyle(includingFractionalSeconds: false)

    private static func parse(url: URL, fallbackDate: Date) -> AIQuotaReading? {
        guard let data = try? Data(contentsOf: url),
              let doc = try? JSONDecoder().decode(Document.self, from: data),
              let cache = doc.cachedUsageUtilization,
              let util = cache.utilization else { return nil }
        if let active = doc.oauthAccount?.accountUuid, let cachedID = cache.accountUuid, active != cachedID {
            return nil
        }
        let entries: [(String, String, Document.Window?)] = [
            ("five_hour", "5-hour limit", util.five_hour),
            ("seven_day", "Weekly", util.seven_day),
            ("seven_day_opus", "Opus · Weekly", util.seven_day_opus),
            ("seven_day_sonnet", "Sonnet · Weekly", util.seven_day_sonnet),
        ]
        let windows = entries.compactMap { id, title, w -> AIQuotaWindow? in
            guard let w, let used = w.utilization, used.isFinite else { return nil }
            return AIQuotaWindow(id: id, title: title, usedPercent: used, resetsAt: parseDate(w.resets_at))
        }
        guard !windows.isEmpty else { return nil }
        let reportedAt = cache.fetchedAtMs.map { Date(timeIntervalSince1970: $0 / 1000) } ?? fallbackDate
        return AIQuotaReading(reportedAt: reportedAt, windows: windows)
    }

    private static func parseDate(_ text: String?) -> Date? {
        guard let text else { return nil }
        return (try? isoWithFractional.parse(text)) ?? (try? isoStandard.parse(text))
    }
}

/// On-demand live usage check via the installed `claude` CLI's `get_usage` control request.
/// Mirrors `CodexQuotaClient`: runs only when the user clicks "Check Claude Now", makes no model call,
/// and never reads OAuth tokens directly.
enum ClaudeQuotaClient {
    enum Failure: LocalizedError {
        case unavailable, noQuota, timeout, disconnected
        case message(String)

        var errorDescription: String? {
            switch self {
            case .unavailable: "Install Claude Code CLI to check Claude usage live."
            case .noQuota: "Claude didn't return a quota. Check that Claude Code is signed in with your Claude.ai account."
            case .timeout: "Claude took too long to respond."
            case .disconnected: "Couldn't read usage from Claude Code."
            case .message(let text): text
            }
        }
    }

    private struct Envelope: Decodable {
        let type: String?
        let response: ControlResponse?

        struct ControlResponse: Decodable {
            let subtype: String?
            let request_id: String?
            let error: String?
            let response: Body?
        }

        struct Body: Decodable {
            let rate_limits_available: Bool?
            let rate_limits: RateLimits?
        }

        struct RateLimits: Decodable {
            let five_hour: Window?
            let seven_day: Window?
            let seven_day_opus: Window?
            let seven_day_sonnet: Window?
            let model_scoped: [ScopedWindow]?
        }

        struct Window: Decodable {
            let utilization: Double?
            let resets_at: String?
        }

        struct ScopedWindow: Decodable {
            let display_name: String?
            let utilization: Double?
            let resets_at: String?
        }
    }

    private static let isoWithFractional = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
    private static let isoStandard = Date.ISO8601FormatStyle(includingFractionalSeconds: false)

    static func read(executable: URL? = nil) async throws -> AIQuotaReading {
        guard let executable = executable ?? installedExecutable() else { throw Failure.unavailable }
        return try await withThrowingTaskGroup(of: AIQuotaReading.self) { group in
            group.addTask { try await request(executable) }
            group.addTask {
                try await Task.sleep(for: .seconds(15))
                throw Failure.timeout
            }
            defer { group.cancelAll() }
            guard let reading = try await group.next() else { throw Failure.disconnected }
            return reading
        }
    }

    private static func installedExecutable() -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let paths = [
            home.appendingPathComponent(".local/bin/claude").path,
            home.appendingPathComponent(".claude/local/claude").path,
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude",
            home.appendingPathComponent(".npm-global/bin/claude").path,
        ]
        return paths.first(where: FileManager.default.isExecutableFile(atPath:)).map { URL(fileURLWithPath: $0) }
    }

    private static func request(_ executable: URL) async throws -> AIQuotaReading {
        let process = Process()
        let input = Pipe()
        let output = Pipe()
        process.executableURL = executable
        process.arguments = ["-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose", "--setting-sources", ""]
        process.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser

        var environment = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        environment["PATH"] = ["\(home)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", environment["PATH"]]
            .compactMap { $0 }.joined(separator: ":")
        if environment["USER"]?.isEmpty != false { environment["USER"] = NSUserName() }
        environment.removeValue(forKey: "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC")
        process.environment = environment
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice

        let outputHandle = output.fileHandleForReading
        let (lines, continuation) = AsyncStream<Data>.makeStream(bufferingPolicy: .bufferingNewest(64))
        let reader = LineReader()
        outputHandle.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                continuation.finish()
            } else {
                reader.append(data, to: continuation)
            }
        }

        let inputHandle = input.fileHandleForWriting
        _ = fcntl(inputHandle.fileDescriptor, F_SETNOSIGPIPE, 1)
        defer {
            outputHandle.readabilityHandler = nil
            if process.isRunning { process.terminate() }
            try? inputHandle.close()
        }
        try process.run()

        let initReq = #"{"type":"control_request","request_id":"i1","request":{"subtype":"initialize"}}"# + "\n"
        let usageReq = #"{"type":"control_request","request_id":"u1","request":{"subtype":"get_usage","skip_behaviors":true}}"# + "\n"
        try inputHandle.write(contentsOf: Data((initReq + usageReq).utf8))

        let decoder = JSONDecoder()
        for await line in lines {
            try Task.checkCancellation()
            guard let env = try? decoder.decode(Envelope.self, from: line),
                  env.type == "control_response",
                  let resp = env.response,
                  resp.request_id == "u1" else { continue }
            if resp.subtype == "error" {
                let msg = resp.error ?? ""
                if msg.contains("Unsupported control request subtype") {
                    throw Failure.message("Update Claude Code CLI to check usage live, or run /usage in Claude Code.")
                }
                throw Failure.message(msg.isEmpty ? Failure.disconnected.localizedDescription : msg)
            }
            guard let limits = resp.response?.rate_limits else { throw Failure.noQuota }
            return try buildReading(from: limits, at: Date())
        }
        try Task.checkCancellation()
        throw Failure.disconnected
    }

    private static func buildReading(from limits: Envelope.RateLimits, at date: Date) throws -> AIQuotaReading {
        let base: [(String, String, Envelope.Window?)] = [
            ("five_hour", "5-hour limit", limits.five_hour),
            ("seven_day", "Weekly", limits.seven_day),
            ("seven_day_opus", "Opus · Weekly", limits.seven_day_opus),
            ("seven_day_sonnet", "Sonnet · Weekly", limits.seven_day_sonnet),
        ]
        var windows = base.compactMap { id, title, w -> AIQuotaWindow? in
            guard let w, let used = w.utilization, used.isFinite else { return nil }
            return AIQuotaWindow(id: id, title: title, usedPercent: used, resetsAt: parseDate(w.resets_at))
        }
        if let scoped = limits.model_scoped {
            for (index, w) in scoped.enumerated() {
                guard let used = w.utilization, used.isFinite else { continue }
                let label = w.display_name.map { "\($0) · Weekly" } ?? "Model · Weekly"
                windows.append(AIQuotaWindow(id: "scoped-\(index)", title: label, usedPercent: used, resetsAt: parseDate(w.resets_at)))
            }
        }
        guard !windows.isEmpty else { throw Failure.noQuota }
        return AIQuotaReading(reportedAt: date, windows: windows)
    }

    private static func parseDate(_ text: String?) -> Date? {
        guard let text else { return nil }
        return (try? isoWithFractional.parse(text)) ?? (try? isoStandard.parse(text))
    }

    private final class LineReader: @unchecked Sendable {
        private var pending = Data()

        func append(_ data: Data, to continuation: AsyncStream<Data>.Continuation) {
            pending.append(data)
            while let end = pending.firstIndex(of: 10) {
                continuation.yield(Data(pending[..<end]))
                pending.removeSubrange(...end)
            }
            if pending.count > 2_000_000 { continuation.finish() }
        }
    }
}
