import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// MARK: - Credentials

/// The OAuth token Claude Code stores after `claude /login`.
public struct ClaudeCredentials: Equatable, Sendable {
    public let accessToken: String
    public let expiresAt: Date?
    /// e.g. "pro", "max". Informational only.
    public let subscriptionType: String?

    public init(accessToken: String, expiresAt: Date?, subscriptionType: String?) {
        self.accessToken = accessToken
        self.expiresAt = expiresAt
        self.subscriptionType = subscriptionType
    }

    public func isExpired(now: Date = Date()) -> Bool {
        guard let expiresAt else { return false }
        return expiresAt <= now
    }

    /// Parses Claude Code's credentials blob:
    ///
    ///     {"claudeAiOauth": {"accessToken": "...", "refreshToken": "...",
    ///                        "expiresAt": 1758553200000, "scopes": [...], "subscriptionType": "max"}}
    ///
    /// Error details name JSON keys only, never values, so they are safe to show.
    public static func parse(_ data: Data) throws -> ClaudeCredentials {
        let root = try CredentialsJSON.object(data, malformed: { ClaudeCredentialsError.malformed($0) })
        // The same item also holds MCP server tokens ("mcpOAuth"); without
        // "claudeAiOauth" Claude Code isn't signed in with a Claude account.
        let oauth: [String: Any]
        if let nested = root["claudeAiOauth"] as? [String: Any] {
            oauth = nested
        } else if root["accessToken"] != nil {
            oauth = root
        } else {
            throw ClaudeCredentialsError.noClaudeAccount(foundKeys: root.keys.sorted())
        }
        guard let token = oauth["accessToken"] as? String, !token.isEmpty else {
            throw ClaudeCredentialsError.malformed("claudeAiOauth has no accessToken (keys: \(oauth.keys.sorted().joined(separator: ", ")))")
        }
        let expiresAt = JSONValue.number(oauth["expiresAt"]).map { value in
            // Claude Code stores milliseconds since the epoch.
            Date(timeIntervalSince1970: value > 1e12 ? value / 1000 : value)
        }
        return ClaudeCredentials(
            accessToken: token,
            expiresAt: expiresAt,
            subscriptionType: oauth["subscriptionType"] as? String
        )
    }

    public static let keychainService = "Claude Code-credentials"

    /// `~/.claude/.credentials.json` (Linux, older macOS installs), or under `CLAUDE_CONFIG_DIR`.
    public static func fileLocations(environment: [String: String] = ProcessInfo.processInfo.environment) -> [FileCredentialsSource] {
        var dirs: [URL] = []
        if let configDir = environment["CLAUDE_CONFIG_DIR"], !configDir.isEmpty {
            dirs.append(URL(fileURLWithPath: (configDir as NSString).expandingTildeInPath))
        }
        dirs.append(FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude"))
        return dirs.map { FileCredentialsSource(url: $0.appendingPathComponent(".credentials.json")) }
    }

    /// Keychain item "Claude Code-credentials" first, then the credentials files.
    public static func loader(sources: [CredentialsDataSource]? = nil) -> CredentialsLoader<ClaudeCredentials> {
        var standard: [CredentialsDataSource] = []
        #if os(macOS)
        standard.append(KeychainCLICredentialsSource(service: keychainService))
        #endif
        standard.append(contentsOf: fileLocations() as [CredentialsDataSource])
        return CredentialsLoader(sources: sources ?? standard, parse: { try ClaudeCredentials.parse($0) }, notFound: { ClaudeCredentialsError.notFound })
    }
}

public enum ClaudeCredentialsError: Error, LocalizedError, Equatable {
    case notFound
    case noClaudeAccount(foundKeys: [String])
    case malformed(String)

    public var errorDescription: String? {
        switch self {
        case .notFound:
            return "No Claude Code sign-in found. Install Claude Code and run `claude` → /login, then press Refresh."
        case .noClaudeAccount(let keys):
            let found = keys.isEmpty ? "nothing" : keys.joined(separator: ", ")
            return "Claude Code isn't signed in with a Claude.ai account (its credentials contain only: \(found)). In Terminal run `claude`, then /login and choose your Claude Pro/Max account."
        case .malformed(let detail):
            return "Claude Code's stored credentials couldn't be read: \(detail). Try `claude` → /login again."
        }
    }
}

// MARK: - Response

/// The usage windows reported by the Claude OAuth usage endpoint.
public enum ClaudeWindowKind: String, CaseIterable, Sendable {
    case session        // five_hour
    case weekly         // seven_day
    case weeklyOpus     // seven_day_opus
    case weeklySonnet   // seven_day_sonnet

    /// Key in the JSON returned by `/api/oauth/usage`.
    public var apiKey: String {
        switch self {
        case .session: return "five_hour"
        case .weekly: return "seven_day"
        case .weeklyOpus: return "seven_day_opus"
        case .weeklySonnet: return "seven_day_sonnet"
        }
    }

    public var title: String {
        switch self {
        case .session: return "Current Session"
        case .weekly: return "Weekly Limit"
        case .weeklyOpus: return "Weekly · Opus"
        case .weeklySonnet: return "Weekly · Sonnet"
        }
    }

    /// Short name used in notifications ("Claude session usage at 90%").
    public var shortName: String {
        switch self {
        case .session: return "session"
        case .weekly: return "weekly"
        case .weeklyOpus: return "weekly Opus"
        case .weeklySonnet: return "weekly Sonnet"
        }
    }

    /// Windows that are always shown, even when the API reports `null` (no usage yet).
    public var isPrimary: Bool { self == .session || self == .weekly }

    public var category: UsageWindowCategory { self == .session ? .session : .weekly }

    /// The window ID is the raw value, which also keyed threshold state before
    /// providers existed, so already-fired alerts carry over.
    public func window(utilization: Double, resetsAt: Date?) -> UsageWindow {
        UsageWindow(id: rawValue, title: title, shortName: shortName, category: category,
                    isPrimary: isPrimary, utilization: utilization, resetsAt: resetsAt)
    }
}

public enum ClaudeUsageDecoder {
    /// Decodes the `/api/oauth/usage` response. Parsing is deliberately lenient:
    /// the endpoint is undocumented, so unknown keys are ignored and missing
    /// optional windows are skipped.
    ///
    ///     {"five_hour": {"utilization": 59.0, "resets_at": "2026-09-22T16:00:00.123456+00:00"},
    ///      "seven_day": {"utilization": 73.0, "resets_at": "..."},
    ///      "seven_day_opus": null, ...}
    public static func decode(_ data: Data, plan: String? = nil, fetchedAt: Date = Date()) throws -> UsageSnapshot {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              root.keys.contains(ClaudeWindowKind.session.apiKey)
                || root.keys.contains(ClaudeWindowKind.weekly.apiKey)
        else {
            throw UsageDecodingError.unexpectedFormat(provider: .claude, snippet: JSONValue.snippet(data))
        }

        var windows: [UsageWindow] = []
        for kind in ClaudeWindowKind.allCases {
            guard let raw = root[kind.apiKey] else { continue }
            if let object = raw as? [String: Any], let utilization = JSONValue.number(object["utilization"]) {
                windows.append(kind.window(utilization: utilization, resetsAt: JSONValue.date(object["resets_at"])))
            } else if kind.isPrimary {
                // `null` means the window hasn't started: nothing used yet.
                windows.append(kind.window(utilization: 0, resetsAt: nil))
            }
        }
        return UsageSnapshot(provider: .claude, windows: windows, plan: plan, fetchedAt: fetchedAt)
    }
}

// MARK: - Client

/// Client for `GET https://api.anthropic.com/api/oauth/usage`, the endpoint
/// behind Claude Code's `/usage` command. It reports subscription (Pro/Max)
/// limits shared by claude.ai and Claude Code. Undocumented, so treat it as
/// best-effort and poll gently.
public struct ClaudeUsageClient: UsageFetcher {
    public static let defaultEndpoint = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    public static let betaHeader = "oauth-2025-04-20"

    public var provider: UsageProvider { .claude }
    private let endpoint: URL
    private let session: URLSession
    private let credentials: CredentialsLoader<ClaudeCredentials>

    public init(
        credentials: CredentialsLoader<ClaudeCredentials> = ClaudeCredentials.loader(),
        endpoint: URL = ClaudeUsageClient.defaultEndpoint,
        session: URLSession = .shared
    ) {
        self.credentials = credentials
        self.endpoint = endpoint
        self.session = session
    }

    public func makeRequest(accessToken: String) -> URLRequest {
        var request = URLRequest(url: endpoint, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.httpMethod = "GET"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(Self.betaHeader, forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(UsageHTTP.userAgent, forHTTPHeaderField: "User-Agent")
        return request
    }

    public func fetch() async throws -> UsageSnapshot {
        let creds = try await loadOffMain(credentials)
        let data = try await UsageHTTP.get(makeRequest(accessToken: creds.accessToken), session: session,
                                           provider: .claude, tokenExpired: creds.isExpired())
        return try ClaudeUsageDecoder.decode(data, plan: creds.subscriptionType)
    }
}
