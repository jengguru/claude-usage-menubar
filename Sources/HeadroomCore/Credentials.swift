import Foundation

/// Where a provider's sign-in blob might be stored. Sources only return raw
/// bytes; each provider parses them.
public protocol CredentialsDataSource: Sendable {
    /// Returns `nil` when this source has nothing, throws when it has something
    /// that can't be read.
    func loadData() throws -> Data?
}

/// A JSON file such as `~/.claude/.credentials.json` or `~/.codex/auth.json`.
public struct FileCredentialsSource: CredentialsDataSource {
    public let url: URL

    public init(url: URL) { self.url = url }

    public func loadData() throws -> Data? {
        try? Data(contentsOf: url)
    }
}

/// Keychain access failed for a reason other than "no such item".
public struct KeychainAccessError: Error, LocalizedError, Equatable {
    public let detail: String

    public init(detail: String) { self.detail = detail }

    public var errorDescription: String? {
        "Keychain access was denied (\(detail)). Press Refresh and choose “Always Allow”."
    }
}

#if os(macOS)
/// Reads a generic-password Keychain item written by a CLI (Claude Code, Codex).
///
/// Goes through `/usr/bin/security` rather than `SecItemCopyMatching`: the item
/// belongs to the CLI, so macOS asks the user once. Granting “Always Allow”
/// to Apple's signed `security` tool survives rebuilds of this app, whereas a
/// grant to an ad-hoc-signed app is invalidated every time it is rebuilt.
public struct KeychainCLICredentialsSource: CredentialsDataSource {
    public let service: String
    public let account: String?

    public init(service: String, account: String? = nil) {
        self.service = service
        self.account = account
    }

    public func loadData() throws -> Data? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        var arguments = ["find-generic-password", "-s", service]
        if let account { arguments += ["-a", account] }
        process.arguments = arguments + ["-w"]
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
            return Self.decodePassword(output)
        case 44: // errSecItemNotFound
            return nil
        default:
            let message = String(decoding: errorOutput, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw KeychainAccessError(detail: message.isEmpty ? "status \(process.terminationStatus)" : message)
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

/// Tries each source in order and returns the first credentials that parse.
/// If none do, throws the first error seen, or `notFound` when every source was empty.
public struct CredentialsLoader<Credentials: Sendable>: Sendable {
    public let sources: [CredentialsDataSource]
    private let parse: @Sendable (Data) throws -> Credentials
    private let notFound: @Sendable () -> Error

    public init(
        sources: [CredentialsDataSource],
        parse: @escaping @Sendable (Data) throws -> Credentials,
        notFound: @escaping @Sendable () -> Error
    ) {
        self.sources = sources
        self.parse = parse
        self.notFound = notFound
    }

    public func load() throws -> Credentials {
        var firstError: Error?
        for source in sources {
            do {
                if let data = try source.loadData() { return try parse(data) }
            } catch {
                firstError = firstError ?? error
            }
        }
        throw firstError ?? notFound()
    }
}

enum CredentialsJSON {
    /// Parses a credentials blob into a dictionary. The error describes the
    /// shape of the data, never its contents.
    static func object(_ data: Data, malformed: (String) -> Error) throws -> [String: Any] {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            let start = data.first.map { $0 == UInt8(ascii: "{") ? "starts with '{'" : "does not start with '{'" } ?? "empty"
            throw malformed("not valid JSON (\(data.count) bytes, \(start))")
        }
        return root
    }
}
