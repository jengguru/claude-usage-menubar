import ServiceManagement
import SwiftUI
import HeadroomCore

struct SettingsPanel: View {
    let done: () -> Void

    @EnvironmentObject private var store: UsageStore
    @AppStorage(SettingsKey.refreshMinutes) private var refreshMinutes = 5
    @AppStorage(SettingsKey.notificationsEnabled) private var notificationsEnabled = true
    @AppStorage(SettingsKey.sessionThresholds) private var sessionThresholds = "75, 90"
    @AppStorage(SettingsKey.weeklyThresholds) private var weeklyThresholds = "75, 90"
    @AppStorage(SettingsKey.menuBarText) private var menuBarText = MenuBarTextMode.sessionUsed.rawValue
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var launchAtLoginError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            section("Refresh") {
                Picker("Check every", selection: $refreshMinutes) {
                    ForEach(AppSettings.refreshChoices, id: \.self) { Text("\($0) min").tag($0) }
                }
                .onChange(of: refreshMinutes) { _ in store.refreshNow() }
            }

            section("Notifications") {
                Toggle("Alert before hitting limits", isOn: $notificationsEnabled)
                thresholdField("Session at", text: $sessionThresholds)
                thresholdField("Weekly at", text: $weeklyThresholds)
                Button("Send test notification") { store.notifier.postTest() }
                    .disabled(!store.notifier.isAvailable)
            }

            section("Menu bar") {
                Picker("Show", selection: $menuBarText) {
                    ForEach(MenuBarTextMode.allCases) { Text($0.label).tag($0.rawValue) }
                }
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { enabled in setLaunchAtLogin(enabled) }
                if let launchAtLoginError {
                    Text(launchAtLoginError).font(.caption).foregroundStyle(.orange)
                }
            }

            Text("Reads Claude Code's sign-in from your Keychain and queries the same usage endpoint as Claude Code's /usage command. Nothing leaves your Mac except that request to api.anthropic.com.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Spacer()
                Button("Done", action: done).keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary).textCase(.uppercase)
            content()
        }
    }

    private func thresholdField(_ label: String, text: Binding<String>) -> some View {
        HStack {
            Text(label)
            TextField("75, 90", text: text)
                .textFieldStyle(.roundedBorder)
                .frame(width: 110)
            Text("%").foregroundStyle(.secondary)
            Spacer()
        }
        .disabled(!notificationsEnabled)
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        // Also stops the onChange loop when the catch below resets the toggle.
        let status = SMAppService.mainApp.status
        guard enabled != (status == .enabled || status == .requiresApproval) else { return }
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            launchAtLoginError = nil
        } catch {
            launchAtLoginError = "Couldn't change login item: \(error.localizedDescription)"
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }
}
