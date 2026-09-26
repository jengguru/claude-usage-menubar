import Foundation

/// One Claude Code sign-in Headroom tracks. The default account reads the
/// same Keychain item / `~/.claude` location it always has; additional
/// accounts point at a `CLAUDE_CONFIG_DIR`-style directory of their own, so
/// e.g. a personal and a work login can both be watched without switching
/// with `claude` → `/login`.
public struct ClaudeAccountConfig: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    /// Shown in the UI and in notifications: "Personal", "Acme Corp".
    public var label: String
    /// Directory holding this account's `.credentials.json`. Empty means the
    /// default location (`$CLAUDE_CONFIG_DIR` or `~/.claude`).
    public var configDir: String

    public init(id: String = UUID().uuidString, label: String, configDir: String = "") {
        self.id = id
        self.label = label
        self.configDir = configDir
    }

    /// The account every install starts with: same source as before this
    /// feature existed, so its id keeps the pre-multi-account threshold-state key.
    public static let `default` = ClaudeAccountConfig(id: "default", label: "Claude", configDir: "")
}
