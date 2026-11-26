import Foundation

// Quota types and the Claude status-line recorder. Shared by the app and the tiny `ZephyrUsage` command-line
// helper that Claude Code launches, so this file must stay Foundation-only (fast process start-up).

struct AIQuotaWindow: Codable, Identifiable, Equatable {
    let id: String
    let title: String
    let usedPercent: Double
    let resetsAt: Date?

    var remainingPercent: Double { 100 - min(max(usedPercent, 0), 100) }

    func isCurrent(at date: Date) -> Bool { resetsAt.map { $0 > date } ?? true }
}

struct AIQuotaReading: Codable, Equatable {
    let reportedAt: Date
    let windows: [AIQuotaWindow]

    func remaining(at date: Date) -> Double? {
        // A missing or expired window can be the most restrictive one.
        guard windows.allSatisfy({ $0.isCurrent(at: date) }) else { return nil }
        return windows.map(\.remainingPercent).min()
    }
}

enum ClaudeUsageRecorder {
    static var snapshotURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/app.zephyr.Zephyr", isDirectory: true)
            .appendingPathComponent("claude-quota.json")
    }

    /// Reads Claude Code's status-line JSON from `input` and stores the rate-limit windows, if present.
    static func record(_ input: Data, to url: URL = snapshotURL, now: Date = Date()) throws {
        let payload = try JSONDecoder().decode(Payload.self, from: input)
        let windows = [
            ("five_hour", "5-hour limit", payload.rate_limits?.five_hour),
            ("seven_day", "Weekly", payload.rate_limits?.seven_day),
        ].compactMap { id, title, window -> AIQuotaWindow? in
            guard let window, let used = window.used_percentage, used.isFinite else { return nil }
            return AIQuotaWindow(id: id, title: title, usedPercent: used,
                                 resetsAt: window.resets_at.map { Date(timeIntervalSince1970: $0) })
        }
        guard !windows.isEmpty else { return }

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        let snapshot = try encoder.encode(AIQuotaReading(reportedAt: now, windows: windows))
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try snapshot.write(to: url, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private struct Payload: Decodable {
        struct Window: Decodable {
            let used_percentage: Double?
            let resets_at: Double?
        }

        struct Windows: Decodable {
            let five_hour: Window?
            let seven_day: Window?
        }

        let rate_limits: Windows?
    }
}
