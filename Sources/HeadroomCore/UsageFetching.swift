import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum UsageAPIError: Error, LocalizedError, Equatable {
    /// The endpoint rejected the token. `tokenExpired` is true when the stored
    /// token's own expiry had already passed.
    case unauthorized(UsageProvider, tokenExpired: Bool)
    case rateLimited(UsageProvider, retryAfter: TimeInterval?)
    case http(UsageProvider, status: Int)
    case invalidResponse(UsageProvider)

    public var errorDescription: String? {
        switch self {
        case .unauthorized(.claude, let expired):
            return expired
                ? "Claude Code's sign-in token expired. Use Claude Code (or run `claude`) once to refresh it — this app picks it up automatically."
                : "Claude Code's sign-in has expired. Run `claude` in Terminal once to refresh it, then press Refresh."
        case .unauthorized(.codex, let expired):
            return expired
                ? "Codex's sign-in token expired. Use Codex (or run `codex`) once to refresh it — this app picks it up automatically."
                : "Codex's sign-in was rejected. Run `codex` in Terminal once (or `codex login` again), then press Refresh."
        case .rateLimited(let provider, _):
            return "The \(provider.displayName) usage endpoint is rate limiting requests."
        case .http(let provider, let status):
            return "The \(provider.displayName) usage endpoint returned HTTP \(status)."
        case .invalidResponse(let provider):
            return "The \(provider.displayName) usage endpoint returned an invalid response."
        }
    }
}

/// Loads a provider's credentials and fetches one usage snapshot.
public protocol UsageFetcher: Sendable {
    var provider: UsageProvider { get }
    func fetch() async throws -> UsageSnapshot
}

enum UsageHTTP {
    static let userAgent = "Headroom/0.3"

    /// Maps an HTTP status to the shared error cases.
    static func validate(status: Int, retryAfterHeader: String?, provider: UsageProvider, tokenExpired: Bool) throws {
        switch status {
        case 200..<300:
            return
        case 401, 403:
            throw UsageAPIError.unauthorized(provider, tokenExpired: tokenExpired)
        case 429:
            let retryAfter = retryAfterHeader.flatMap { TimeInterval($0.trimmingCharacters(in: .whitespaces)) }
            throw UsageAPIError.rateLimited(provider, retryAfter: retryAfter)
        default:
            throw UsageAPIError.http(provider, status: status)
        }
    }

    static func get(_ request: URLRequest, session: URLSession, provider: UsageProvider, tokenExpired: Bool) async throws -> Data {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw UsageAPIError.invalidResponse(provider) }
        try validate(status: http.statusCode, retryAfterHeader: http.value(forHTTPHeaderField: "Retry-After"),
                     provider: provider, tokenExpired: tokenExpired)
        return data
    }
}

/// Runs a blocking credentials read off the caller's actor: `security` can
/// wait on a Keychain prompt.
func loadOffMain<Credentials: Sendable>(_ loader: CredentialsLoader<Credentials>) async throws -> Credentials {
    try await Task.detached(priority: .utility) { try loader.load() }.value
}
