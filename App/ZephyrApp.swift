import SwiftUI
import Carbon.HIToolbox

@main
struct ZephyrApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    init() {
        if CommandLine.arguments.dropFirst().first == ClaudeStatusLine.flag { ClaudeStatusLine.run() }
        if CommandLine.arguments.contains("--selftest") { SelfTest.run() }
        TelemetryStore.shared.start()
    }

    var body: some Scene {
        let store = TelemetryStore.shared
        let usage = AIUsageStore.shared
        @Bindable var pages = MenuBarPages.shared
        MenuBarExtra {
            MenuBarContent(showAIUsage: $pages.showsAIUsage).environment(store)
        } label: {
            MenuBarLabel(showAIUsage: $pages.showsAIUsage)
                .environment(store)
                .environment(usage)
        }
        .menuBarExtraStyle(.window)

        Window("Zephyr", id: "dashboard") {
            DashboardView().environment(store).environment(usage)
        }
        .defaultSize(width: 1020, height: 720)
        .suppressedAtLaunch()

        Settings {
            SettingsView().environment(store)
        }
    }
}

extension Scene {
    /// macOS 15+ can keep the window from opening at launch; macOS 14 is handled in DashboardView.
    func suppressedAtLaunch() -> some Scene {
        if #available(macOS 15.0, *) { return self.defaultLaunchBehavior(.suppressed) }
        return self
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    @MainActor
    func applicationDidFinishLaunching(_ notification: Notification) {
        AIUsageStore.shared.start()
        MenuBarPages.shared.start()
        let mods = cmdKey | optionKey | controlKey
        let controller = TelemetryStore.shared.controller
        HotKeyCenter.shared.register(keyCode: kVK_ANSI_F, modifiers: mods, id: 1) { controller.cycleMode() }
        HotKeyCenter.shared.register(keyCode: kVK_ANSI_A, modifiers: mods, id: 2) { controller.setMode(.automatic) }
        HotKeyCenter.shared.register(keyCode: kVK_ANSI_B, modifiers: mods, id: 3) { controller.setMode(.fullBlast) }
    }

    /// Opening Zephyr again from Spotlight/Launchpad/Finder shows the dashboard.
    @MainActor
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { NotificationCenter.default.post(name: .openDashboard, object: nil) }
        return true
    }

    /// Give the fans back to macOS before we exit. The helper also does this if we vanish.
    @MainActor
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        Task { @MainActor in
            await TelemetryStore.shared.controller.restoreForQuit()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
