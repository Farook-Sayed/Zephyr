import Foundation

enum GeminiQuotaClient {
    enum Failure: LocalizedError {
        case unavailable, noQuota, timeout, disconnected

        var errorDescription: String? {
            switch self {
            case .unavailable: "Install Antigravity CLI (agy) to check this quota."
            case .noQuota: "Antigravity returned no Gemini quota. Check your plan and sign-in in Antigravity CLI."
            case .timeout: "Antigravity took too long to respond."
            case .disconnected: "Couldn't read quota from Antigravity CLI. Make sure agy is up to date and signed in."
            }
        }
    }

    private struct Response: Decodable {
        let status: String
        let command: Command?

        struct Command: Decodable {
            let data: Payload?
        }

        struct Payload: Decodable {
            let groups: [Group]
        }

        struct Group: Decodable {
            let name: String?
            let buckets: [Bucket]?
        }

        struct Bucket: Decodable {
            let id: String?
            let name: String?
            let window: String?
            let remaining_fraction: Double?
            let reset_time: String?

            var sortOrder: Int {
                switch window {
                case "5h": 0
                case "weekly": 1
                default: 2
                }
            }

            var title: String {
                switch window {
                case "5h": "5-hour limit"
                case "weekly": "Weekly"
                default: name ?? "Usage limit"
                }
            }
        }
    }

    static func read(executable: URL? = nil, timeout: Duration = .seconds(15)) async throws -> AIQuotaReading {
        guard let executable = executable ?? installedExecutable() else { throw Failure.unavailable }
        return try await withThrowingTaskGroup(of: AIQuotaReading.self) { group in
            group.addTask { try await request(executable) }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw Failure.timeout
            }
            defer { group.cancelAll() }
            guard let reading = try await group.next() else { throw Failure.disconnected }
            return reading
        }
    }

    private static func installedExecutable() -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let paths = ["/opt/homebrew/bin/agy", "/usr/local/bin/agy", home.appendingPathComponent(".local/bin/agy").path]
        return paths.first(where: FileManager.default.isExecutableFile(atPath:)).map { URL(fileURLWithPath: $0) }
    }

    private static func request(_ executable: URL) async throws -> AIQuotaReading {
        try Task.checkCancellation()
        let process = Process()
        let output = Pipe()
        process.executableURL = executable
        process.arguments = ["-p", "/usage", "--output-format", "json"]
        process.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", environment["PATH"]]
            .compactMap { $0 }.joined(separator: ":")
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice

        let handle = output.fileHandleForReading
        let (chunks, continuation) = AsyncStream<Data>.makeStream()
        handle.readabilityHandler = { reader in
            let chunk = reader.availableData
            if chunk.isEmpty {
                reader.readabilityHandler = nil
                continuation.finish()
            } else {
                continuation.yield(chunk)
            }
        }
        defer {
            handle.readabilityHandler = nil
            continuation.finish()
            if process.isRunning { process.terminate() }
        }

        do { try process.run() } catch { throw Failure.disconnected }
        var data = Data()
        for await chunk in chunks {
            try Task.checkCancellation()
            guard data.count + chunk.count <= 262_144 else { throw Failure.disconnected }
            data.append(chunk)
        }
        try Task.checkCancellation()
        guard let response = try? JSONDecoder().decode(Response.self, from: data),
              response.status == "SUCCESS", let groups = response.command?.data?.groups else {
            throw Failure.disconnected
        }
        // Antigravity also reports a Claude/GPT group. Never substitute it for the Gemini group.
        let group = groups.first { $0.name?.localizedCaseInsensitiveCompare("Gemini Models") == .orderedSame }
            ?? groups.first { $0.name?.localizedCaseInsensitiveContains("Gemini") == true }
        let windows = (group?.buckets ?? []).sorted { $0.sortOrder < $1.sortOrder }.enumerated().compactMap { index, bucket -> AIQuotaWindow? in
            guard let remaining = bucket.remaining_fraction, remaining.isFinite else { return nil }
            return AIQuotaWindow(id: bucket.id ?? "gemini-\(index)", title: bucket.title,
                                 usedPercent: (1 - min(max(remaining, 0), 1)) * 100,
                                 resetsAt: bucket.reset_time.flatMap(parseResetTime))
        }
        guard !windows.isEmpty else { throw Failure.noQuota }
        return AIQuotaReading(reportedAt: Date(), windows: windows)
    }

    private static func parseResetTime(_ value: String) -> Date? {
        (try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(value))
            ?? (try? Date.ISO8601FormatStyle().parse(value))
    }
}
