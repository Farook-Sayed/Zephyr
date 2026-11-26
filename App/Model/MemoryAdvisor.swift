import Foundation

struct MemoryTip: Identifiable, Equatable {
    enum Severity: Int { case good, info, warning }
    var id: String
    var symbol: String
    var title: String
    var detail: String
    var severity: Severity
    /// App the user can quit to act on this tip.
    var quitName: String?
    var quitPath: String?
}

/// Turns raw memory numbers into advice. Only suggests things that actually help on macOS:
/// there is no "free up RAM" button because spare memory is used as file cache and costs nothing.
enum MemoryAdvisor {
    private static let gb = 1_073_741_824.0

    static func tips(for m: MemoryInfo) -> [MemoryTip] {
        guard m.totalBytes > 0 else { return [] }
        var tips: [MemoryTip] = []
        let total = Double(m.totalBytes)
        let heavy = m.topProcesses.filter { $0.appPath != nil }

        if m.pressureLevel >= 4 {
            tips.append(MemoryTip(id: "pressure", symbol: "exclamationmark.triangle.fill",
                                  title: "Memory pressure is critical",
                                  detail: "macOS is compressing and swapping aggressively, which slows everything down. Quit apps you aren't using now, starting with the largest below.",
                                  severity: .warning))
        } else if m.pressureLevel == 2 {
            tips.append(MemoryTip(id: "pressure", symbol: "exclamationmark.circle.fill",
                                  title: "Memory pressure is elevated",
                                  detail: "The system is starting to compress memory to cope. Closing a few large apps will bring it back to normal.",
                                  severity: .warning))
        }

        if Double(m.swapUsedBytes) > 1 * gb {
            tips.append(MemoryTip(id: "swap", symbol: "arrow.left.arrow.right.circle",
                                  title: String(format: "%.1f GB is swapped to the SSD", Double(m.swapUsedBytes) / gb),
                                  detail: "Swapping makes apps feel sluggish and adds SSD writes. It usually means your working set is larger than \(Int((total / gb).rounded())) GB — close heavy apps or restart long-running ones.",
                                  severity: m.pressureLevel > 1 ? .warning : .info))
        }

        if Double(m.compressedBytes) / total > 0.22 {
            tips.append(MemoryTip(id: "compressed", symbol: "arrow.down.right.and.arrow.up.left",
                                  title: String(format: "%.1f GB is compressed", Double(m.compressedBytes) / gb),
                                  detail: "Compression is saving RAM but costs CPU time. If the Mac feels warm or slow, reducing what's open helps both memory and heat.",
                                  severity: .info))
        }

        for p in heavy.prefix(3) where Double(p.bytes) / total > 0.15 {
            tips.append(tip(for: p, total: total))
        }

        if Double(m.wiredBytes) / total > 0.35 {
            tips.append(MemoryTip(id: "wired", symbol: "lock.fill",
                                  title: String(format: "%.1f GB is wired", Double(m.wiredBytes) / gb),
                                  detail: "Wired memory belongs to the kernel, drivers and virtual machines and can't be compressed or swapped. If you run VMs or containers, reduce their memory allocation.",
                                  severity: .info))
        }

        if tips.isEmpty {
            tips.append(MemoryTip(id: "healthy", symbol: "checkmark.seal.fill",
                                  title: "Memory is healthy",
                                  detail: String(format: "%.0f%% in use with normal pressure and little swap. Free RAM isn't wasted RAM: macOS uses spare memory (%.1f GB cached right now) to make apps open faster and gives it back instantly.",
                                                 m.usedFraction * 100, Double(m.cachedBytes) / gb),
                                  severity: .good))
        } else if m.pressureLevel > 1 || Double(m.swapUsedBytes) > 1 * gb {
            tips.append(MemoryTip(id: "restart", symbol: "arrow.clockwise.circle",
                                  title: "Restart apps that have run for days",
                                  detail: "Browsers, chat apps and IDEs gradually accumulate memory. Quitting and reopening them is the most effective fix, and a restart clears everything.",
                                  severity: .info))
        }
        return tips
    }

    private static func tip(for p: ProcessMemory, total: Double) -> MemoryTip {
        let n = p.name.lowercased()
        let size = String(format: "%.1f GB (%.0f%% of RAM)", Double(p.bytes) / gb, Double(p.bytes) / total * 100)
        let advice: String
        if ["chrome", "safari", "firefox", "arc", "edge", "brave", "opera", "vivaldi"].contains(where: n.contains) {
            advice = "Close tabs you aren't using and turn on the browser's memory-saving mode (Chrome and Edge: Memory Saver; Arc and Safari suspend background tabs automatically). Check the browser's own task manager for single heavy tabs."
        } else if ["slack", "discord", "teams", "notion", "spotify", "whatsapp", "visual studio code", "code", "cursor", "figma", "obsidian"].contains(where: n.contains) {
            advice = "This app embeds a full browser engine, so memory grows with use. Quitting and reopening it resets that, and the web version in a tab you close is lighter if you only use it occasionally."
        } else if ["xcode", "simulator", "android studio", "intellij", "docker", "utm", "parallels", "vmware", "virtualbox"].contains(where: n.contains) {
            advice = "Development tools and virtual machines reserve a lot. Quit simulators and unused projects, and lower the VM or container memory limit if you don't need it."
        } else {
            advice = "If you aren't actively using it, quit it. If it keeps growing while idle, check for an update — that pattern is usually a memory leak."
        }
        return MemoryTip(id: "app-\(p.name)", symbol: "app.badge", title: "\(p.name) is using \(size)",
                         detail: advice, severity: Double(p.bytes) / total > 0.25 ? .warning : .info,
                         quitName: p.name, quitPath: p.appPath)
    }
}
