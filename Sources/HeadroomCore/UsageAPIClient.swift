import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum UsageAPIError: Error, LocalizedError, Equatable {
    case unauthorized
    case rateLimited(retryAfter: TimeInterval?)
    case http(status: Int)
    case invalidResponse

    public var errorDescription: String? {
        switch self {
        case .unauthorized:
            return "Claude Code's sign-in has expired. Run `claude` in Terminal once to refresh it, then press Refresh."
        case .rateLimited:
            return "The usage endpoint is rate limiting requests."
        case .http(let status):
            return "The usage endpoint returned HTTP \(status)."
        case .invalidResponse:
            return "The usage endpoint returned an invalid response."
        }
    }
}

/// Client for `GET https://api.anthropic.com/api/oauth/usage`, the endpoint
/// behind Claude Code's `/usage` command. It reports subscription (Pro/Max)
/// limits shared by claude.ai and Claude Code. Undocumented, so treat it as
/// best-effort and poll gently.
public final class UsageAPIClient: @unchecked Sendable {
    public static let defaultEndpoint = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    public static let betaHeader = "oauth-2025-04-20"

    private let endpoint: URL
    private let session: URLSession

    public init(endpoint: URL = UsageAPIClient.defaultEndpoint, session: URLSession = .shared) {
        self.endpoint = endpoint
        self.session = session
    }

    public func makeRequest(accessToken: String) -> URLRequest {
        var request = URLRequest(url: endpoint, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.httpMethod = "GET"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(Self.betaHeader, forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Headroom/0.2", forHTTPHeaderField: "User-Agent")
        return request
    }

    public func fetch(accessToken: String) async throws -> UsageSnapshot {
        let (data, response) = try await session.data(for: makeRequest(accessToken: accessToken))
        guard let http = response as? HTTPURLResponse else { throw UsageAPIError.invalidResponse }
        try Self.validate(status: http.statusCode, retryAfterHeader: http.value(forHTTPHeaderField: "Retry-After"))
        return try UsageDecoder.decode(data)
    }

    static func validate(status: Int, retryAfterHeader: String?) throws {
        switch status {
        case 200..<300:
            return
        case 401, 403:
            throw UsageAPIError.unauthorized
        case 429:
            throw UsageAPIError.rateLimited(retryAfter: retryAfterHeader.flatMap { TimeInterval($0.trimmingCharacters(in: .whitespaces)) })
        default:
            throw UsageAPIError.http(status: status)
        }
    }
}
