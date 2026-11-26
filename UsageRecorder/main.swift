import Foundation

// ZephyrUsage: launched by Claude Code's status line. Does one thing — store the usage windows — and exits.
// It links only Foundation, so it starts in a few milliseconds (the full app takes ~0.4 s).
let input = FileHandle.standardInput.readDataToEndOfFile()
if UserDefaults(suiteName: "app.zephyr.Zephyr")?.bool(forKey: "claudeUsageEnabled") == true {
    try? ClaudeUsageRecorder.record(input)
}
exit(EXIT_SUCCESS)
