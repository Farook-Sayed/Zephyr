import AppKit
import Observation

@MainActor
@Observable
final class MenuBarPages {
    static let shared = MenuBarPages()
    var showsAIUsage = false

    @ObservationIgnored private var monitors: [Any] = []
    @ObservationIgnored private var trackingGesture = false
    @ObservationIgnored private var deltaX: CGFloat = 0
    @ObservationIgnored private var deltaY: CGFloat = 0

    private init() {}

    func start() {
        guard monitors.isEmpty else { return }
        // SwiftUI renders the status label separately from the popover. Observe only pointer scrolls
        // and use the app's own status windows, including when macOS routes the event to Control Center.
        let local = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            self?.observe(event)
            return event
        }
        let global = NSEvent.addGlobalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            MainActor.assumeIsolated { self?.observe(event) }
        }
        monitors = [local, global].compactMap { $0 }
    }

    private func observe(_ event: NSEvent) {
        guard event.hasPreciseScrollingDeltas, event.momentumPhase.isEmpty else { return }
        if event.phase.contains(.ended) || event.phase.contains(.cancelled) {
            trackingGesture = false
            return
        }
        if event.phase.contains(.began) {
            trackingGesture = pointerIsOverStatusItem(event)
            deltaX = 0
            deltaY = 0
        }
        guard trackingGesture else { return }
        deltaX += event.scrollingDeltaX
        deltaY += abs(event.scrollingDeltaY)
        guard abs(deltaX) >= 25, abs(deltaX) > deltaY * 1.5 else { return }
        trackingGesture = false
        if pointerIsOverStatusItem(event) { showsAIUsage.toggle() }
    }

    private func pointerIsOverStatusItem(_ event: NSEvent) -> Bool {
        let point = event.window?.convertPoint(toScreen: event.locationInWindow) ?? event.locationInWindow
        return NSApp.windows.contains { window in
            // macOS can expose a separate status window on each display.
            guard window.isVisible,
                  window.level == .statusBar || window.className.contains("NSStatusBarWindow") else { return false }
            let frame = window.frame
            return point.x >= frame.minX && point.x < frame.maxX && point.y > frame.minY && point.y <= frame.maxY
        }
    }
}
