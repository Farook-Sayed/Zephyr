import Foundation
import Observation

enum AIProvider: String, CaseIterable, Identifiable {
    case codex = "Codex"
    case claude = "Claude"
    case gemini = "Gemini"

    var id: String { rawValue }
    var displayName: String { self == .gemini ? "Gemini (Antigravity)" : rawValue }
    var freshness: TimeInterval { self == .claude ? 5 * 60 : 10 * 60 }
}

@MainActor
@Observable
final class AIUsageStore {
    static let shared = AIUsageStore()
    private(set) var codexEnabled = UserDefaults.standard.bool(forKey: "codexUsageEnabled")
    private(set) var claudeEnabled = UserDefaults.standard.bool(forKey: "claudeUsageEnabled")
    private(set) var geminiEnabled = UserDefaults.standard.bool(forKey: "geminiUsageEnabled")
    private(set) var codex: AIQuotaReading?
    private(set) var claude: AIQuotaReading?
    private(set) var gemini: AIQuotaReading?
    private(set) var codexError: String?
    private(set) var codexRefreshing = false
    private(set) var claudeError: String?
    private(set) var claudeRefreshing = false
    private(set) var geminiError: String?
    private(set) var geminiRefreshing = false

    @ObservationIgnored private var codexPolling: Task<Void, Never>?
    @ObservationIgnored private var codexRequest: Task<Void, Never>?
    @ObservationIgnored private var claudePolling: Task<Void, Never>?
    @ObservationIgnored private var claudeRequest: Task<Void, Never>?
    @ObservationIgnored private var geminiPolling: Task<Void, Never>?
    @ObservationIgnored private var geminiRequest: Task<Void, Never>?
    @ObservationIgnored private var lastGeminiAttempt: ContinuousClock.Instant?
    @ObservationIgnored private let codexLog = CodexSessionLog()
    @ObservationIgnored private let claudeCache = ClaudeConfigCache()
    @ObservationIgnored private var triedLiveCodex = false
    @ObservationIgnored private var claudeFileSignature = ""
    @ObservationIgnored private var claudeSnapshot: AIQuotaReading?
    private static let geminiRefreshInterval = Duration.seconds(600)

    func start() {
        if codexEnabled, codexPolling == nil {
            codexPolling = Task { [weak self] in
                // Passive: read Codex's own session logs. Cheap (a directory check unless a log changed).
                while !Task.isCancelled {
                    await self?.scanCodexLog()
                    try? await Task.sleep(for: .seconds(30))
                }
            }
        }
        if claudeEnabled, claudePolling == nil {
            claudePolling = Task { [weak self] in
                while !Task.isCancelled {
                    await self?.readClaude()
                    try? await Task.sleep(for: .seconds(15))
                }
            }
        }
        if geminiEnabled, geminiPolling == nil {
            geminiPolling = Task { [weak self] in
                while !Task.isCancelled {
                    self?.refreshGeminiIfDue()
                    let next = self?.lastGeminiAttempt?.advanced(by: Self.geminiRefreshInterval)
                        ?? ContinuousClock.now.advanced(by: Self.geminiRefreshInterval)
                    try? await Task.sleep(until: next)
                }
            }
        }
    }

    func isEnabled(_ provider: AIProvider) -> Bool {
        switch provider {
        case .codex: codexEnabled
        case .claude: claudeEnabled
        case .gemini: geminiEnabled
        }
    }

    func reading(for provider: AIProvider) -> AIQuotaReading? {
        switch provider {
        case .codex: codex
        case .claude: claude
        case .gemini: gemini
        }
    }

    func isRefreshing(_ provider: AIProvider) -> Bool {
        switch provider {
        case .codex: codexRefreshing
        case .claude: claudeRefreshing
        case .gemini: geminiRefreshing
        }
    }

    func error(for provider: AIProvider) -> String? {
        switch provider {
        case .codex: codexError
        case .claude: claudeError
        case .gemini: geminiError
        }
    }

    func refresh(_ provider: AIProvider) {
        switch provider {
        case .codex: refreshCodex()
        case .claude: refreshClaude()
        case .gemini: refreshGemini()
        }
    }

    func setEnabled(_ enabled: Bool, for provider: AIProvider) {
        switch provider {
        case .codex:
            codexEnabled = enabled
            UserDefaults.standard.set(enabled, forKey: "codexUsageEnabled")
            if !enabled {
                codexPolling?.cancel()
                codexPolling = nil
                codexRequest?.cancel()
                codexRequest = nil
                codexRefreshing = false
                codex = nil
                codexError = nil
                triedLiveCodex = false
            }
        case .claude:
            claudeEnabled = enabled
            UserDefaults.standard.set(enabled, forKey: "claudeUsageEnabled")
            if !enabled {
                claudePolling?.cancel()
                claudePolling = nil
                claudeRequest?.cancel()
                claudeRequest = nil
                claudeRefreshing = false
                claude = nil
                claudeError = nil
                claudeSnapshot = nil
                claudeFileSignature = ""
                try? FileManager.default.removeItem(at: ClaudeStatusLine.snapshotURL) // don't leave usage data behind
            }
        case .gemini:
            geminiEnabled = enabled
            UserDefaults.standard.set(enabled, forKey: "geminiUsageEnabled")
            if !enabled {
                geminiPolling?.cancel()
                geminiPolling = nil
                geminiRequest?.cancel()
                geminiRequest = nil
                geminiRefreshing = false
                gemini = nil
                geminiError = nil
                lastGeminiAttempt = nil
            }
        }
        start()
    }

    func refreshIfNeeded() {
        if codexEnabled {
            Task { await scanCodexLog() }
            // Only when Codex has left no usable record at all: one live query to get a first value.
            if codex == nil, !triedLiveCodex { refreshCodex() }
        }
        if claudeEnabled { Task { await readClaude() } }
        refreshGeminiIfDue()
    }

    private func scanCodexLog() async {
        guard codexEnabled else { return }
        let log = codexLog
        let reading = await Task.detached(priority: .utility) { log.latest() }.value
        if let reading { adoptCodex(reading) }
    }

    /// Keeps whichever reading is newer, so a stale log can never overwrite a fresh live check.
    private func adoptCodex(_ reading: AIQuotaReading) {
        guard codexEnabled else { return }
        if let current = codex, current.reportedAt > reading.reportedAt { return }
        if codex != reading { codex = reading }
        codexError = nil
    }

    /// Live check: launches Codex's own app server once. Used for "Check now" and as a first-value fallback.
    func refreshCodex() {
        guard codexEnabled, codexRequest == nil else { return }
        triedLiveCodex = true
        codexRefreshing = true
        codexRequest = Task {
            do {
                let reading = try await CodexQuotaClient.read()
                guard !Task.isCancelled else { return }
                adoptCodex(reading)
            } catch {
                guard !Task.isCancelled else { return }
                codexError = error.localizedDescription
            }
            codexRefreshing = false
            codexRequest = nil
        }
    }

    /// Keeps whichever Claude reading is newer, so a stale file can never overwrite a fresh live check.
    private func adoptClaude(_ reading: AIQuotaReading) {
        guard claudeEnabled else { return }
        if let current = claude, current.reportedAt > reading.reportedAt { return }
        if claude != reading { claude = reading }
        claudeError = nil
    }

    /// Live check: asks the installed Claude Code CLI once for current limits (mirroring `refreshCodex`).
    func refreshClaude() {
        guard claudeEnabled, claudeRequest == nil else { return }
        claudeRefreshing = true
        claudeError = nil
        claudeRequest = Task {
            do {
                let reading = try await ClaudeQuotaClient.read()
                guard !Task.isCancelled else { return }
                adoptClaude(reading)
            } catch {
                guard !Task.isCancelled else { return }
                await readClaude()
                claudeError = error.localizedDescription
            }
            claudeRefreshing = false
            claudeRequest = nil
        }
    }

    private func refreshGeminiIfDue() {
        if let lastGeminiAttempt, lastGeminiAttempt.duration(to: .now) < Self.geminiRefreshInterval { return }
        refreshGemini()
    }

    private func refreshGemini() {
        guard geminiEnabled, geminiRequest == nil else { return }
        lastGeminiAttempt = .now
        geminiRefreshing = true
        geminiError = nil
        geminiRequest = Task {
            do {
                let reading = try await GeminiQuotaClient.read()
                guard !Task.isCancelled else { return }
                gemini = reading
            } catch {
                guard !Task.isCancelled else { return }
                geminiError = error.localizedDescription
            }
            geminiRefreshing = false
            geminiRequest = nil
        }
    }

    private func readClaude() async {
        guard claudeEnabled else { return }
        let url = ClaudeStatusLine.snapshotURL
        let previousSig = claudeFileSignature
        let previousSnap = claudeSnapshot
        let cache = claudeCache
        let result: (sig: String, snap: AIQuotaReading?, cached: AIQuotaReading?) = await Task.detached(priority: .utility) {
            var sig = previousSig
            var snap = previousSnap
            if let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]),
               let mtime = values.contentModificationDate {
                let nextSig = "\(mtime.timeIntervalSince1970)|\(values.fileSize ?? 0)"
                if nextSig != previousSig {
                    let decoder = JSONDecoder()
                    decoder.dateDecodingStrategy = .secondsSince1970
                    snap = (try? Data(contentsOf: url)).flatMap { try? decoder.decode(AIQuotaReading.self, from: $0) }
                    sig = nextSig
                }
            } else if previousSig != "" {
                sig = ""
                snap = nil
            }
            let cached = cache.latest()
            return (sig, snap, cached)
        }.value
        guard claudeEnabled else { return }
        claudeFileSignature = result.sig
        claudeSnapshot = result.snap
        let best: AIQuotaReading?
        switch (result.snap, result.cached) {
        case let (a?, b?): best = a.reportedAt >= b.reportedAt ? a : b
        case let (a?, nil): best = a
        case let (nil, b?): best = b
        case (nil, nil): best = nil
        }
        if let best { adoptClaude(best) }
    }
}
