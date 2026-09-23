import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(CryptoKit)
import CryptoKit
#endif

// MARK: - Credentials

/// The ChatGPT sign-in Codex CLI stores after `codex login`.
public struct CodexCredentials: Equatable, Sendable {
    public let accessToken: String
    /// ChatGPT workspace, sent as `ChatGPT-Account-Id` like Codex does.
    public let accountID: String?
    /// From the access token's `exp` claim.
    public let expiresAt: Date?

    public init(accessToken: String, accountID: String?, expiresAt: Date?) {
        self.accessToken = accessToken
        self.accountID = accountID
        self.expiresAt = expiresAt
    }

    public func isExpired(now: Date = Date()) -> Bool {
        guard let expiresAt else { return false }
        return expiresAt <= now
    }

    /// Parses `$CODEX_HOME/auth.json`:
    ///
    ///     {"auth_mode": "chatgpt", "OPENAI_API_KEY": null,
    ///      "tokens": {"id_token": "<jwt>", "access_token": "<jwt>",
    ///                 "refresh_token": "...", "account_id": "..."},
    ///      "last_refresh": "2026-09-20T08:00:00Z"}
    ///
    /// Error details name JSON keys only, never values, so they are safe to show.
    public static func parse(_ data: Data) throws -> CodexCredentials {
        let root = try CredentialsJSON.object(data, malformed: { CodexCredentialsError.malformed($0) })
        guard let tokens = root["tokens"] as? [String: Any] else {
            if let apiKey = root["OPENAI_API_KEY"] as? String, !apiKey.isEmpty {
                throw CodexCredentialsError.apiKeyOnly
            }
            throw CodexCredentialsError.noChatGPTAccount(foundKeys: root.keys.sorted())
        }
        guard let token = tokens["access_token"] as? String, !token.isEmpty else {
            throw CodexCredentialsError.malformed("tokens has no access_token (keys: \(tokens.keys.sorted().joined(separator: ", ")))")
        }
        let accountID = (tokens["account_id"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            ?? (tokens["id_token"] as? String).flatMap(idTokenAccountID)
        let expiresAt = JWT.claims(token).flatMap { JSONValue.number($0["exp"]) }.map { Date(timeIntervalSince1970: $0) }
        return CodexCredentials(accessToken: token, accountID: accountID, expiresAt: expiresAt)
    }

    /// The `chatgpt_account_id` claim in the ID token, used when auth.json has no `account_id`.
    static func idTokenAccountID(_ idToken: String) -> String? {
        let auth = JWT.claims(idToken)?["https://api.openai.com/auth"] as? [String: Any]
        return (auth?["chatgpt_account_id"] as? String).flatMap { $0.isEmpty ? nil : $0 }
    }

    public static let keychainService = "Codex Auth"

    /// `$CODEX_HOME`, else `~/.codex`.
    public static func home(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        if let home = environment["CODEX_HOME"], !home.isEmpty {
            return URL(fileURLWithPath: (home as NSString).expandingTildeInPath)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
    }

    /// The Keychain account Codex uses when `cli_auth_credentials_store` is
    /// `keyring`: "cli|" + the first 16 hex digits of SHA-256 of the canonical
    /// `CODEX_HOME` path.
    public static func keychainAccount(codexHome: URL) -> String? {
        #if canImport(CryptoKit)
        let path = codexHome.resolvingSymlinksInPath().standardizedFileURL.path
        let hex = SHA256.hash(data: Data(path.utf8)).map { String(format: "%02x", $0) }.joined()
        return "cli|" + String(hex.prefix(16))
        #else
        return nil
        #endif
    }

    /// `auth.json` first (Codex's default), then the Keychain item Codex writes
    /// when configured to store credentials in the keyring.
    public static func loader(sources: [CredentialsDataSource]? = nil) -> CredentialsLoader<CodexCredentials> {
        let codexHome = home()
        var standard: [CredentialsDataSource] = [FileCredentialsSource(url: codexHome.appendingPathComponent("auth.json"))]
        #if os(macOS)
        if let account = keychainAccount(codexHome: codexHome) {
            standard.append(KeychainCLICredentialsSource(service: keychainService, account: account))
        }
        #endif
        return CredentialsLoader(sources: sources ?? standard, parse: { try CodexCredentials.parse($0) },
                                 notFound: { CodexCredentialsError.notFound })
    }
}

public enum CodexCredentialsError: Error, LocalizedError, Equatable {
    case notFound
    case apiKeyOnly
    case noChatGPTAccount(foundKeys: [String])
    case malformed(String)

    public var errorDescription: String? {
        switch self {
        case .notFound:
            return "No Codex sign-in found. Install Codex CLI and run `codex login` with your ChatGPT account, then press Refresh."
        case .apiKeyOnly:
            return "Codex is signed in with an API key. Usage limits only exist for ChatGPT sign-in: run `codex login` and choose “Sign in with ChatGPT”."
        case .noChatGPTAccount(let keys):
            let found = keys.isEmpty ? "nothing" : keys.joined(separator: ", ")
            return "Codex isn't signed in with a ChatGPT account (auth.json contains only: \(found)). Run `codex login` and choose “Sign in with ChatGPT”."
        case .malformed(let detail):
            return "Codex's stored credentials couldn't be read: \(detail). Try `codex login` again."
        }
    }
}

/// Reads JWT claims without verifying the signature. Only used to learn the
/// token's own expiry and account, never to trust it.
enum JWT {
    static func claims(_ token: String) -> [String: Any]? {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }
        var base64 = parts[1].replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        guard let data = Data(base64Encoded: base64) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}

// MARK: - Response

public enum CodexUsageDecoder {
    /// Decodes `GET /backend-api/wham/usage`, the endpoint behind Codex's `/status`:
    ///
    ///     {"plan_type": "plus",
    ///      "rate_limit": {"allowed": true, "limit_reached": false,
    ///                     "primary_window": {"used_percent": 42, "limit_window_seconds": 18000,
    ///                                        "reset_after_seconds": 3600, "reset_at": 1790092800},
    ///                     "secondary_window": {...}},
    ///      "credits": {...},
    ///      "additional_rate_limits": [{"limit_name": "...", "metered_feature": "...",
    ///                                  "rate_limit": {"primary_window": {...}, ...}}]}
    ///
    /// Lenient like the Claude decoder: unknown keys are ignored, missing windows skipped.
    public static func decode(_ data: Data, fetchedAt: Date = Date()) throws -> UsageSnapshot {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              root.keys.contains("rate_limit") || root.keys.contains("plan_type")
        else {
            throw UsageDecodingError.unexpectedFormat(provider: .codex, snippet: JSONValue.snippet(data))
        }

        var windows = limitWindows(root["rate_limit"], idPrefix: "", namePrefix: nil, isPrimary: true, fetchedAt: fetchedAt)
        for extra in root["additional_rate_limits"] as? [[String: Any]] ?? [] {
            let name = (extra["limit_name"] as? String) ?? (extra["metered_feature"] as? String) ?? "Additional"
            let key = (extra["metered_feature"] as? String) ?? name
            windows += limitWindows(extra["rate_limit"], idPrefix: "\(key).", namePrefix: name, isPrimary: false, fetchedAt: fetchedAt)
        }
        return UsageSnapshot(provider: .codex, windows: windows, plan: root["plan_type"] as? String, fetchedAt: fetchedAt)
    }

    private static func limitWindows(
        _ raw: Any?, idPrefix: String, namePrefix: String?, isPrimary: Bool, fetchedAt: Date
    ) -> [UsageWindow] {
        guard let limit = raw as? [String: Any] else { return [] }
        return [("primary", UsageWindowCategory.session), ("secondary", .weekly)].compactMap { entry -> UsageWindow? in
            let (slot, fallback) = entry
            guard let object = limit["\(slot)_window"] as? [String: Any],
                  let used = JSONValue.number(object["used_percent"]) else { return nil }
            let seconds = JSONValue.number(object["limit_window_seconds"]).flatMap { $0 > 0 ? $0 : nil }
            let label = seconds.map { durationLabel(seconds: $0) } ?? slot
            let resetsAt = JSONValue.date(object["reset_at"])
                ?? JSONValue.number(object["reset_after_seconds"]).map { fetchedAt.addingTimeInterval($0) }
            let title = namePrefix.map { "\($0) · \(label.capitalizedFirst)" } ?? "\(label.capitalizedFirst) Limit"
            return UsageWindow(
                id: idPrefix + slot,
                title: title,
                shortName: namePrefix.map { "\($0) \(label)" } ?? label,
                category: seconds.map(UsageWindowCategory.init(duration:)) ?? fallback,
                isPrimary: isPrimary,
                utilization: used,
                resetsAt: resetsAt
            )
        }
    }

    /// The label Codex's own `/status` uses: "5h", "daily", "weekly", "monthly",
    /// "annual" (each within 5%), otherwise a plain duration such as "3h" or "10-day".
    static func durationLabel(seconds: Double) -> String {
        let minutes = seconds / 60
        let named: [(String, Double)] = [("5h", 300), ("daily", 1440), ("weekly", 10_080),
                                         ("monthly", 43_200), ("annual", 525_600)]
        if let match = named.first(where: { minutes >= $0.1 * 0.95 && minutes <= $0.1 * 1.05 }) {
            return match.0
        }
        let rounded = Int(minutes.rounded())
        if rounded >= 1440 { return "\(Int((minutes / 1440).rounded()))-day" }
        if rounded >= 60 { return "\(Int((minutes / 60).rounded()))h" }
        return "\(max(rounded, 1))m"
    }
}

private extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + String(dropFirst()) }
}

// MARK: - Client

/// Client for `GET https://chatgpt.com/backend-api/wham/usage`, the endpoint
/// Codex CLI's `/status` uses for the ChatGPT plan's Codex limits. It does not
/// cover ChatGPT chat/message limits, which no endpoint exposes. Undocumented,
/// so treat it as best-effort and poll gently.
public struct CodexUsageClient: UsageFetcher {
    public static let defaultEndpoint = URL(string: "https://chatgpt.com/backend-api/wham/usage")!

    public var provider: UsageProvider { .codex }
    private let endpoint: URL
    private let session: URLSession
    private let credentials: CredentialsLoader<CodexCredentials>

    public init(
        credentials: CredentialsLoader<CodexCredentials> = CodexCredentials.loader(),
        endpoint: URL = CodexUsageClient.defaultEndpoint,
        session: URLSession = .shared
    ) {
        self.credentials = credentials
        self.endpoint = endpoint
        self.session = session
    }

    public func makeRequest(credentials: CodexCredentials) -> URLRequest {
        var request = URLRequest(url: endpoint, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.httpMethod = "GET"
        request.setValue("Bearer \(credentials.accessToken)", forHTTPHeaderField: "Authorization")
        if let accountID = credentials.accountID {
            request.setValue(accountID, forHTTPHeaderField: "ChatGPT-Account-Id")
        }
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(UsageHTTP.userAgent, forHTTPHeaderField: "User-Agent")
        return request
    }

    public func fetch() async throws -> UsageSnapshot {
        let creds = try await loadOffMain(credentials)
        let data = try await UsageHTTP.get(makeRequest(credentials: creds), session: session,
                                           provider: .codex, tokenExpired: creds.isExpired())
        return try CodexUsageDecoder.decode(data)
    }
}
