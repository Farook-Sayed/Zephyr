import AppKit

extension Notification.Name {
    /// Posted when the user reopens the app (Spotlight, Launchpad, Finder) while it is already running.
    static let openDashboard = Notification.Name("app.zephyr.openDashboard")
}

/// Zephyr lives in the menu bar (LSUIElement: no Dock icon, no app switcher entry). While a real window
/// is open it becomes a regular app so the window behaves normally and the Dock icon appears; when the
/// last window closes it goes back to being menu-bar-only.
@MainActor
enum AppPresence {
    /// Set just before the user (not the system) opens the dashboard; lets macOS 14 tell the two apart.
    static var dashboardRequested = false
    /// macOS 14 only: the one launch-time window that must be closed.
    static var suppressedInitialLaunch = false

    static func showInDock() {
        if NSApp.activationPolicy() != .regular { NSApp.setActivationPolicy(.regular) }
        NSApp.activate()
    }

    static func hideIfNoWindows() {
        // Let the closing window finish tearing down before we look.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            let hasWindow = NSApp.windows.contains { $0.isVisible && $0.canBecomeMain && !($0 is NSPanel) }
            if !hasWindow { NSApp.setActivationPolicy(.accessory) }
        }
    }
}
