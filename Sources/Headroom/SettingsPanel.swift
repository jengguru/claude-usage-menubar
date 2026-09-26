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
    @AppStorage(SettingsKey.menuBarStyle) private var menuBarStyle = MenuBarStyle.combined.rawValue
    @AppStorage(SettingsKey.providerEnabled(.claude)) private var claudeEnabled = true
    @AppStorage(SettingsKey.providerEnabled(.codex)) private var codexEnabled = true
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var launchAtLoginError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            section("Services") {
                Toggle("Claude (Claude Code sign-in)", isOn: $claudeEnabled)
                    .onChange(of: claudeEnabled) { _ in store.applyEnabledProviders() }
                ClaudeAccountsEditor(store: store)
                    .padding(.leading, 20)
                    .disabled(!claudeEnabled)
                Toggle("Codex (Codex CLI sign-in)", isOn: $codexEnabled)
                    .onChange(of: codexEnabled) { _ in store.applyEnabledProviders() }
                Text("Codex shows Codex limits only; ChatGPT chat message limits aren't available.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            section("Refresh") {
                Picker("Check every", selection: $refreshMinutes) {
                    ForEach(AppSettings.refreshChoices, id: \.self) { Text("\($0) min").tag($0) }
                }
                .onChange(of: refreshMinutes) { _ in store.refreshAll() }
            }

            section("Notifications") {
                Toggle("Alert before hitting limits", isOn: $notificationsEnabled)
                thresholdField("Session at", text: $sessionThresholds)
                thresholdField("Weekly at", text: $weeklyThresholds)
                Button("Send test notification") { store.notifier.postTest() }
                    .disabled(!store.notifier.isAvailable)
            }

            section("Menu bar") {
                Picker("Icons", selection: $menuBarStyle) {
                    ForEach(MenuBarStyle.allCases) { Text($0.label).tag($0.rawValue) }
                }
                Picker("Show", selection: $menuBarText) {
                    ForEach(MenuBarTextMode.allCases) { Text($0.label).tag($0.rawValue) }
                }
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { enabled in setLaunchAtLogin(enabled) }
                if let launchAtLoginError {
                    Text(launchAtLoginError).font(.caption).foregroundStyle(.orange)
                }
            }

            Text("Reads Claude Code's and Codex's existing sign-ins (never refreshes or changes them) and asks the same usage endpoints their /usage and /status commands use. Nothing leaves your Mac except those requests to api.anthropic.com and chatgpt.com.")
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

/// Tracks several Claude accounts (e.g. a personal and a work sign-in) as
/// separate rows, each with its own label and optional credentials directory.
private struct ClaudeAccountsEditor: View {
    @ObservedObject var store: UsageStore
    @State private var accounts: [ClaudeAccountConfig] = AppSettings.claudeAccounts

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach($accounts) { $account in
                HStack(spacing: 6) {
                    TextField("Label", text: $account.label, onEditingChanged: commitIfDone)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 90)
                    TextField("Config dir (optional, e.g. ~/.claude-work)", text: $account.configDir, onEditingChanged: commitIfDone)
                        .textFieldStyle(.roundedBorder)
                    Button {
                        remove(account)
                    } label: {
                        Image(systemName: "minus.circle").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .disabled(accounts.count == 1)
                    .help("Remove this account")
                }
            }
            Button {
                accounts.append(ClaudeAccountConfig(label: "Account \(accounts.count + 1)"))
                commit()
            } label: {
                Label("Add Claude account", systemImage: "plus.circle")
            }
            .buttonStyle(.plain)
            .font(.caption)

            Text("An extra account needs its own sign-in — run `CLAUDE_CONFIG_DIR=<dir> claude` and /login there — so switching accounts never needs a logout. Leave Config dir blank for the account already signed in via `claude` / Keychain.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func commitIfDone(_ isEditing: Bool) {
        guard !isEditing else { return }
        commit()
    }

    private func commit() {
        store.updateClaudeAccounts(accounts)
    }

    private func remove(_ account: ClaudeAccountConfig) {
        accounts.removeAll { $0.id == account.id }
        commit()
    }
}
