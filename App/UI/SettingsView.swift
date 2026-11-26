import SwiftUI

struct SettingsView: View {
    @Environment(TelemetryStore.self) private var store
    @AppStorage("pillCPU") private var showCPU = true
    @AppStorage("pillFan") private var showFan = true
    @AppStorage("pillPower") private var showPower = true
    @AppStorage("pillRAM") private var showRAM = false
    @AppStorage("pillNet") private var showNet = false
    @State private var launchAtLogin = LoginItem.isEnabled
    @State private var loginError: String?

    var body: some View {
        @Bindable var store = store
        TabView {
            Form {
                Section {
                    Toggle("Launch at login", isOn: Binding(get: { launchAtLogin }, set: { setLogin($0) }))
                    if let loginError { Text(loginError).font(.caption).foregroundStyle(.red) }
                }
                Section("Menu bar") {
                    Toggle("CPU temperature", isOn: $showCPU)
                    Toggle("Fan speed", isOn: $showFan)
                    Toggle("System power", isOn: $showPower)
                    Toggle("Memory in use", isOn: $showRAM)
                    Toggle("Network speed", isOn: $showNet)
                }
                Section("Refresh rate") {
                    Picker("Dashboard or popover open", selection: $store.foregroundInterval) {
                        Text("0.5 s").tag(0.5); Text("1 s").tag(1.0); Text("2 s").tag(2.0)
                    }
                    Picker("Menu bar only", selection: $store.backgroundInterval) {
                        Text("2 s").tag(2.0); Text("3 s").tag(3.0); Text("5 s").tag(5.0); Text("10 s").tag(10.0)
                    }
                }
                Section("Keyboard shortcuts") {
                    LabeledContent("Cycle fan mode", value: "⌃⌥⌘F")
                    LabeledContent("Back to Automatic", value: "⌃⌥⌘A")
                    LabeledContent("Full Blast", value: "⌃⌥⌘B")
                }
            }
            .formStyle(.grouped)
            .tabItem { Label("General", systemImage: "gearshape") }

            Form {
                Section("Fan helper") {
                    LabeledContent("Status", value: statusText(store.controller.helperState))
                    HStack {
                        Button("Enable Fan Control…") { store.controller.installHelper() }
                            .disabled(store.controller.helperState.isReady)
                        Button("Remove Helper") { store.controller.uninstallHelper() }
                            .disabled(store.controller.helperState == .notInstalled)
                    }
                    Text("Changing fan speed writes to the System Management Controller, which needs administrator rights. Zephyr uses a small background helper that does nothing else, accepts connections only from this app, and hands the fans back to macOS if the app quits, crashes, or goes quiet. It also enforces a \(Int(HelperConstants.criticalTemperature)) °C safety limit on its own.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .tabItem { Label("Fan Control", systemImage: "fan") }
        }
        .frame(width: 520, height: 430)
        .onAppear { store.controller.refreshHelperState(); AppPresence.showInDock() }
        .onDisappear { AppPresence.hideIfNoWindows() }
    }

    private func statusText(_ s: HelperState) -> String {
        switch s {
        case .ready: "Enabled"
        case .notInstalled: "Not installed"
        case .requiresApproval: "Waiting for approval in System Settings"
        case .notFound: "Not registered (see README)"
        case .unreachable(let m): m
        }
    }

    private func setLogin(_ on: Bool) {
        do { try LoginItem.set(on); loginError = nil } catch { loginError = error.localizedDescription }
        launchAtLogin = LoginItem.isEnabled
    }
}
