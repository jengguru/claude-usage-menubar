import Foundation

/// The OAuth token Claude Code stores after `claude /login`.
public struct OAuthCredentials: Equatable, Sendable {
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
    public static func parse(_ data: Data) throws -> OAuthCredentials {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw CredentialsError.malformed
        }
        let oauth = root["claudeAiOauth"] as? [String: Any] ?? root
        guard let token = oauth["accessToken"] as? String, !token.isEmpty else {
            throw CredentialsError.malformed
        }
        let expiresAt = UsageDecoder.number(oauth["expiresAt"]).map { value in
            // Claude Code stores milliseconds since the epoch.
            Date(timeIntervalSince1970: value > 1e12 ? value / 1000 : value)
        }
        return OAuthCredentials(
            accessToken: token,
            expiresAt: expiresAt,
            subscriptionType: oauth["subscriptionType"] as? String
        )
    }
}

public enum CredentialsError: Error, LocalizedError, Equatable {
    case notFound
    case malformed
    case accessDenied(String)

    public var errorDescription: String? {
        switch self {
        case .notFound:
            return "No Claude Code sign-in found. Install Claude Code and run `claude` → /login, then press Refresh."
        case .malformed:
            return "Claude Code's stored credentials couldn't be read. Try signing in again with `claude` → /login."
        case .accessDenied(let detail):
            return "Keychain access was denied (\(detail)). Press Refresh and choose “Always Allow”."
        }
    }
}

public protocol CredentialsSource: Sendable {
    /// Returns `nil` when this source has no credentials, throws when it has
    /// them but they can't be read.
    func load() throws -> OAuthCredentials?
}

/// `~/.claude/.credentials.json` (Linux, older macOS installs, or `CLAUDE_CONFIG_DIR`).
public struct FileCredentialsSource: CredentialsSource {
    public let url: URL

    public init(url: URL) { self.url = url }

    public func load() throws -> OAuthCredentials? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try OAuthCredentials.parse(data)
    }

    public static func defaultLocations(environment: [String: String] = ProcessInfo.processInfo.environment) -> [FileCredentialsSource] {
        var dirs: [URL] = []
        if let configDir = environment["CLAUDE_CONFIG_DIR"], !configDir.isEmpty {
            dirs.append(URL(fileURLWithPath: (configDir as NSString).expandingTildeInPath))
        }
        dirs.append(FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude"))
        return dirs.map { FileCredentialsSource(url: $0.appendingPathComponent(".credentials.json")) }
    }
}

#if os(macOS)
/// Reads the macOS Keychain item Claude Code writes ("Claude Code-credentials").
///
/// Goes through `/usr/bin/security` rather than `SecItemCopyMatching`: the item
/// belongs to Claude Code, so macOS asks the user once. Granting “Always Allow”
/// to Apple's signed `security` tool survives rebuilds of this app, whereas a
/// grant to an ad-hoc-signed app is invalidated every time it is rebuilt.
public struct KeychainCLICredentialsSource: CredentialsSource {
    public static let defaultService = "Claude Code-credentials"
    public let service: String

    public init(service: String = KeychainCLICredentialsSource.defaultService) {
        self.service = service
    }

    public func load() throws -> OAuthCredentials? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["find-generic-password", "-s", service, "-w"]
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        let output = stdout.fileHandleForReading.readDataToEndOfFile()
        let errorOutput = stderr.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        switch process.terminationStatus {
        case 0:
            return try OAuthCredentials.parse(Self.decodePassword(output))
        case 44: // errSecItemNotFound
            return nil
        default:
            let message = String(decoding: errorOutput, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw CredentialsError.accessDenied(message.isEmpty ? "status \(process.terminationStatus)" : message)
        }
    }

    /// `security -w` prints the password as-is, or hex-encoded if it contains
    /// non-printable bytes.
    static func decodePassword(_ output: Data) -> Data {
        let text = String(decoding: output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("{") { return Data(text.utf8) }
        guard text.count.isMultiple(of: 2), text.allSatisfy(\.isHexDigit) else { return Data(text.utf8) }
        var bytes = Data(capacity: text.count / 2)
        var index = text.startIndex
        while index < text.endIndex {
            let next = text.index(index, offsetBy: 2)
            guard let byte = UInt8(text[index..<next], radix: 16) else { return Data(text.utf8) }
            bytes.append(byte)
            index = next
        }
        return bytes
    }
}
#endif

/// Tries each source in order and returns the first credentials found.
public struct CompositeCredentialsSource: CredentialsSource {
    public let sources: [CredentialsSource]

    public init(sources: [CredentialsSource]) { self.sources = sources }

    public static var standard: CompositeCredentialsSource {
        var sources: [CredentialsSource] = []
        #if os(macOS)
        sources.append(KeychainCLICredentialsSource())
        #endif
        sources.append(contentsOf: FileCredentialsSource.defaultLocations() as [CredentialsSource])
        return CompositeCredentialsSource(sources: sources)
    }

    /// Unlike the protocol requirement, never returns `nil`: throws `.notFound` instead.
    public func load() throws -> OAuthCredentials? {
        try loadRequired()
    }

    public func loadRequired() throws -> OAuthCredentials {
        var firstError: Error?
        for source in sources {
            do {
                if let credentials = try source.load() { return credentials }
            } catch {
                firstError = firstError ?? error
            }
        }
        throw firstError ?? CredentialsError.notFound
    }
}
