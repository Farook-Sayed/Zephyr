import Foundation

/// Reads Codex's own usage record. Codex writes the account's rate-limit windows into every session log
/// (`~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl`, in `token_count` events), so the latest value can be read with
/// a file check: nothing is launched, nothing touches the network, and no sign-in data is read.
/// It is exactly as current as your last Codex activity — like the Claude status-line feed.
final class CodexSessionLog: @unchecked Sendable {
    private let root: URL
    private let lock = NSLock()
    private var signature = ""
    private var cached: AIQuotaReading?

    init(root: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/sessions", isDirectory: true)) {
        self.root = root
    }

    /// Most recent reading, or nil when Codex has no session logs with limits. Cheap when nothing changed.
    func latest() -> AIQuotaReading? {
        let files = recentFiles(limit: 4)
        guard let newest = files.first else { return nil }
        let sig = "\(newest.url.path)|\(newest.date.timeIntervalSince1970)|\(newest.size)"
        lock.lock()
        if sig == signature { defer { lock.unlock() }; return cached }
        lock.unlock()

        var reading: AIQuotaReading?
        for file in files {
            if let r = Self.readTail(of: file.url) { reading = r; break }
        }
        lock.lock(); signature = sig; cached = reading; lock.unlock()
        return reading
    }

    // MARK: Files

    private struct LogFile { let url: URL; let date: Date; let size: Int }

    /// Newest rollout files. Directories are date-named, so only the latest two non-empty days are listed.
    private func recentFiles(limit: Int) -> [LogFile] {
        let fm = FileManager.default
        func children(_ url: URL, keys: [URLResourceKey] = []) -> [URL] {
            ((try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: keys, options: .skipsHiddenFiles)) ?? [])
                .sorted { $0.lastPathComponent > $1.lastPathComponent }
        }
        var files: [LogFile] = []
        var daysWithFiles = 0
        outer: for year in children(root) {
            for month in children(year) {
                for day in children(month) {
                    let found = children(day, keys: [.contentModificationDateKey, .fileSizeKey]).compactMap { url -> LogFile? in
                        guard url.lastPathComponent.hasPrefix("rollout-"), url.pathExtension == "jsonl",
                              let v = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]),
                              let date = v.contentModificationDate else { return nil }
                        return LogFile(url: url, date: date, size: v.fileSize ?? 0)
                    }
                    if !found.isEmpty { files += found; daysWithFiles += 1 }
                    if daysWithFiles >= 2 { break outer }
                }
            }
        }
        return files.sorted { $0.date > $1.date }.prefix(limit).map { $0 }
    }

    // MARK: Parsing

    private struct Line: Decodable {
        struct Payload: Decodable { let rate_limits: Limits? }
        struct Limits: Decodable {
            let limit_id: String?
            let limit_name: String?
            let primary: Window?
            let secondary: Window?
        }
        struct Window: Decodable {
            let used_percent: Double?
            let window_minutes: Int?
            let resets_at: Double?
        }
        let timestamp: String?
        let payload: Payload?
    }

    private static let marker = Data("\"rate_limits\"".utf8)

    /// Scans the last part of a log (newest events last) and keeps the latest event for each limit bucket.
    private static func readTail(of url: URL, bytes: Int = 600_000) -> AIQuotaReading? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return nil }
        let start = size > UInt64(bytes) ? size - UInt64(bytes) : 0
        guard (try? handle.seek(toOffset: start)) != nil, let data = try? handle.readToEnd() else { return nil }

        var lines = data.split(separator: 10, omittingEmptySubsequences: true)
        if start > 0, !lines.isEmpty { lines.removeFirst() } // first line is probably cut off

        let decoder = JSONDecoder()
        var perBucket: [String: (limits: Line.Limits, date: Date)] = [:]
        for raw in lines.reversed() where raw.range(of: marker) != nil {
            guard let line = try? decoder.decode(Line.self, from: Data(raw)),
                  let limits = line.payload?.rate_limits, limits.primary != nil || limits.secondary != nil else { continue }
            let key = limits.limit_id ?? "codex"
            if perBucket[key] == nil { perBucket[key] = (limits, parse(line.timestamp) ?? Date()) }
        }
        guard !perBucket.isEmpty else { return nil }

        let windows = perBucket.keys.sorted().flatMap { key -> [AIQuotaWindow] in
            guard let (limits, _) = perBucket[key] else { return [] }
            let name = key == "codex" ? nil : limits.limit_name ?? key
            return [limits.primary, limits.secondary].enumerated().compactMap { index, window in
                guard let window, let used = window.used_percent, used.isFinite else { return nil }
                let base = CodexQuotaClient.title(forMinutes: window.window_minutes)
                return AIQuotaWindow(id: "\(key)-\(index)", title: name.map { "\($0) · \(base)" } ?? base,
                                     usedPercent: used, resetsAt: window.resets_at.map { Date(timeIntervalSince1970: $0) })
            }
        }
        guard !windows.isEmpty, let reported = perBucket.values.map(\.date).max() else { return nil }
        return AIQuotaReading(reportedAt: reported, windows: windows)
    }

    private static let isoWithFractional = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
    private static let isoStandard = Date.ISO8601FormatStyle(includingFractionalSeconds: false)

    private static func parse(_ text: String?) -> Date? {
        guard let text else { return nil }
        return (try? isoWithFractional.parse(text)) ?? (try? isoStandard.parse(text))
    }
}
