import SwiftUI

struct AIProviderMark: View {
    let provider: AIProvider
    let size: CGFloat

    var body: some View {
        // Neutral system symbols: product logos are their owners' trademarks and are not bundled.
        Image(systemName: symbol)
        .resizable()
        .scaledToFit()
        .foregroundStyle(.primary)
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    private var symbol: String {
        switch provider {
        case .codex: "terminal"
        case .claude: "text.bubble"
        case .gemini: "diamond"
        }
    }
}

struct AIUsageMenuLabel: View {
    @Environment(AIUsageStore.self) private var store
    let failsafeActive: Bool

    var body: some View {
        TimelineView(.periodic(from: .now, by: 15)) { timeline in
            HStack(spacing: 6) {
                if failsafeActive {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .accessibilityLabel("Fan failsafe active")
                }
                ForEach(AIProvider.allCases) { provider in
                    let reading = store.reading(for: provider)
                    let remaining = reading?.remaining(at: timeline.date)
                    let isOlder = reading.map { timeline.date.timeIntervalSince($0.reportedAt) > provider.freshness } ?? false
                    HStack(spacing: 3) {
                        Text(provider.rawValue).foregroundStyle(.secondary)
                        Text(remaining.map { $0.formatted(.number.precision(.fractionLength(0))) + "%" } ?? "—")
                            .monospacedDigit()
                            .foregroundStyle(remaining == nil || isOlder ? .secondary : .primary)
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(provider.displayName)
                    .accessibilityValue(remaining.map { "\(Int($0.rounded())) percent remaining" + (isOlder ? ", last known reading" : "") } ?? "No current reading")
                }
                Text("left").foregroundStyle(.secondary).accessibilityHidden(true)
            }
        }
        .onAppear { store.refreshIfNeeded() }
    }
}

struct AIUsagePage: View {
    @Environment(AIUsageStore.self) private var store
    private let columns = [GridItem(.adaptive(minimum: 310), spacing: 16, alignment: .top)]

    var body: some View {
        TimelineView(.periodic(from: .now, by: 15)) { timeline in
            LazyVGrid(columns: columns, alignment: .leading, spacing: 16) {
                ForEach(AIProvider.allCases) { provider in
                    providerCard(provider, now: timeline.date)
                }
            }
        }
        .onAppear { store.refreshIfNeeded() }
    }

    private func providerCard(_ provider: AIProvider, now: Date) -> some View {
        let enabled = store.isEnabled(provider)
        let reading = store.reading(for: provider)
        let refreshing = store.isRefreshing(provider)
        let error = store.error(for: provider)
        return Card {
            HStack(spacing: 8) {
                AIProviderMark(provider: provider, size: 24)
                Text(provider.displayName).font(.headline)
                Spacer(minLength: 8)
                Toggle("Track \(provider.displayName) usage", isOn: Binding(
                    get: { store.isEnabled(provider) },
                    set: { store.setEnabled($0, for: provider) }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .help("Track \(provider.displayName) usage")
            }

            if enabled {
                if let reading {
                    ForEach(reading.windows) { window in
                        quotaRow(window, now: now)
                    }
                    readingAge(reading, provider: provider, now: now)
                } else if refreshing {
                    detail("Checking \(provider.rawValue) usage…")
                } else {
                    detail(emptyMessage(for: provider))
                }
                if let error { detail(error) }
                Button("Check \(provider.rawValue) Now") { store.refresh(provider) }
                    .disabled(refreshing)
                    .help(refreshHelp(for: provider))
            } else {
                detail(disabledMessage(for: provider))
            }

            Link(provider == .gemini ? "Antigravity Usage Guide" : "Open \(provider.rawValue) Usage",
                 destination: usageURL(for: provider))
                .font(.callout)
        }
    }

    private func emptyMessage(for provider: AIProvider) -> String {
        switch provider {
        case .codex: "No Codex activity found yet. Use Codex once, or choose Check Codex Now."
        case .claude: "No Claude usage cached yet. Choose Check Claude Now, or run /usage in Claude Code."
        case .gemini: "No Gemini quota loaded yet. Choose Check Gemini Now."
        }
    }

    private func disabledMessage(for provider: AIProvider) -> String {
        switch provider {
        case .codex: "Reads the limits Codex records on your Mac. Nothing is launched or sent anywhere."
        case .claude: "Reads the limits Claude Code saves locally in ~/.claude.json. Nothing is launched or sent anywhere."
        case .gemini: "Checks your Antigravity Gemini quota every 10 minutes using the installed Antigravity CLI."
        }
    }

    private func refreshHelp(for provider: AIProvider) -> String {
        switch provider {
        case .codex: "Asks the installed Codex app for your current limits. Normally unnecessary: Zephyr reads them from Codex's own logs."
        case .claude: "Asks the installed Claude Code CLI for your current limits without sending a prompt."
        case .gemini: "Runs /usage in Antigravity CLI to get the remaining Gemini quota and reset times."
        }
    }

    private func usageURL(for provider: AIProvider) -> URL {
        switch provider {
        case .codex: URL(string: "https://chatgpt.com/codex/settings/usage")!
        case .claude: URL(string: "https://claude.ai/settings/usage")!
        case .gemini: URL(string: "https://antigravity.google/docs/cli/commands/usage")!
        }
    }

    private func quotaRow(_ window: AIQuotaWindow, now: Date) -> some View {
        let current = window.isCurrent(at: now)
        return VStack(alignment: .leading, spacing: 5) {
            StatRow(label: window.title, value: current ? "\(Int(window.remainingPercent.rounded()))% left" : "Waiting for update")
            if current {
                LinearGauge(value: window.remainingPercent / 100, tint: window.remainingPercent < 15 ? .orange : .accentColor)
                if let reset = window.resetsAt {
                    detail("Resets \(reset.formatted(.dateTime.weekday(.abbreviated).hour().minute()))")
                }
            }
        }
        .padding(.vertical, 3)
    }

    private func readingAge(_ reading: AIQuotaReading, provider: AIProvider, now: Date) -> some View {
        let stale = now.timeIntervalSince(reading.reportedAt) > provider.freshness
        return HStack(spacing: 5) {
            if stale { Image(systemName: "clock") }
            Text(stale ? "Last reported" : "Updated")
            Text(reading.reportedAt, style: .relative).monospacedDigit()
            Text("ago")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    private func detail(_ message: String) -> some View {
        Text(message).font(.caption).foregroundStyle(.secondary)
    }
}
