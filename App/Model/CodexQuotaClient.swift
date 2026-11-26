import Darwin
import Foundation

enum CodexQuotaClient {
    enum Failure: LocalizedError {
        case unavailable, noQuota, timeout, disconnected

        var errorDescription: String? {
            switch self {
            case .unavailable: "Install ChatGPT or the Codex CLI to read Codex usage."
            case .noQuota: "Codex didn't return a quota. Check that Codex is signed in with your ChatGPT account."
            case .timeout: "Codex took too long to respond."
            case .disconnected: "Couldn't read usage from Codex."
            }
        }
    }

    private struct Window: Decodable {
        let usedPercent: Double
        let windowDurationMins: Int?
        let resetsAt: Double?

        var title: String { CodexQuotaClient.title(forMinutes: windowDurationMins) }
    }

    /// Human title for a limit window length, shared with the session-log reader.
    static func title(forMinutes minutes: Int?) -> String {
        guard let minutes, minutes > 0 else { return "Usage limit" }
        if minutes == 10_080 { return "Weekly" }
        if minutes.isMultiple(of: 1_440) { return "\(minutes / 1_440)-day limit" }
        if minutes.isMultiple(of: 60) { return "\(minutes / 60)-hour limit" }
        return "\(minutes)-minute limit"
    }

    private struct Bucket: Decodable {
        let limitName: String?
        let primary: Window?
        let secondary: Window?
    }

    private struct Response: Decodable {
        let id: Int?
        let result: Limits?

        struct Limits: Decodable {
            let rateLimits: Bucket?
            let rateLimitsByLimitId: [String: Bucket]?

            func reading(at date: Date) throws -> AIQuotaReading {
                let buckets = rateLimitsByLimitId?.isEmpty == false
                    ? rateLimitsByLimitId ?? [:]
                    : rateLimits.map { ["codex": $0] } ?? [:]
                let windows = buckets.keys.sorted().flatMap { key -> [AIQuotaWindow] in
                    guard let bucket = buckets[key] else { return [] }
                    let name = key == "codex" ? nil : bucket.limitName ?? key
                    return [bucket.primary, bucket.secondary].enumerated().compactMap { index, window in
                        guard let window, window.usedPercent.isFinite else { return nil }
                        return AIQuotaWindow(
                            id: "\(key)-\(index)",
                            title: name.map { "\($0) · \(window.title)" } ?? window.title,
                            usedPercent: window.usedPercent,
                            resetsAt: window.resetsAt.map { Date(timeIntervalSince1970: $0) }
                        )
                    }
                }
                guard !windows.isEmpty else { throw Failure.noQuota }
                return AIQuotaReading(reportedAt: date, windows: windows)
            }
        }
    }

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
        let appURLs = [URL(fileURLWithPath: "/Applications"), FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications")]
        let bundled = appURLs.flatMap { directory in
            ["ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex",
             "ChatGPT.app/Contents/Resources/codex",
             "Codex.app/Contents/Resources/codex"].map { directory.appendingPathComponent($0).path }
        }
        let paths = bundled + ["/opt/homebrew/bin/codex", "/usr/local/bin/codex"]
        return paths.first(where: FileManager.default.isExecutableFile(atPath:)).map { URL(fileURLWithPath: $0) }
    }

    private static func request(_ executable: URL) async throws -> AIQuotaReading {
        let process = Process()
        let input = Pipe()
        let output = Pipe()
        process.executableURL = executable
        process.arguments = ["app-server"]
        process.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
        // Menu bar apps start with a minimal PATH; node-based installs of `codex` need the usual tool locations.
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", environment["PATH"]].compactMap { $0 }.joined(separator: ":")
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
        try inputHandle.write(contentsOf: Data(
            #"{"id":1,"method":"initialize","params":{"clientInfo":{"name":"zephyr","version":"1.0"}}}"#.utf8
        ) + Data([10]))

        let decoder = JSONDecoder()
        for await line in lines {
            try Task.checkCancellation()
            guard let response = try? decoder.decode(Response.self, from: line) else { continue }
            switch response.id {
            case 1:
                let request = """
                    {"method":"initialized"}
                    {"id":2,"method":"account/rateLimits/read"}
                    """ + "\n"
                try inputHandle.write(contentsOf: Data(request.utf8))
            case 2:
                guard let result = response.result else { throw Failure.noQuota }
                return try result.reading(at: Date())
            default:
                continue
            }
        }
        try Task.checkCancellation()
        throw Failure.disconnected
    }

    /// The pipe's readability handler is serial and owns this buffer until it is removed.
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
