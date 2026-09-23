import XCTest
@testable import HeadroomCore

final class ClaudeDecoderTests: XCTestCase {
    func testDecodesTypicalResponse() throws {
        let json = """
        {"five_hour": {"utilization": 59.0, "resets_at": "2026-09-22T16:00:00.412345+00:00"},
         "seven_day": {"utilization": 73, "resets_at": "2026-09-22T15:00:00Z"},
         "seven_day_oauth_apps": null,
         "seven_day_opus": null,
         "seven_day_sonnet": {"utilization": 12.5, "resets_at": "2026-09-25T15:00:00+00:00"},
         "extra_usage": {"is_enabled": false}}
        """
        let snapshot = try ClaudeUsageDecoder.decode(Data(json.utf8), plan: "max")

        XCTAssertEqual(snapshot.provider, .claude)
        XCTAssertEqual(snapshot.plan, "max")
        XCTAssertEqual(snapshot.session?.utilization, 59)
        XCTAssertEqual(snapshot.session?.resetsAt?.timeIntervalSince1970 ?? 0, 1_790_092_800 + 0.412345, accuracy: 0.001)
        XCTAssertEqual(snapshot.weekly?.utilization, 73)
        XCTAssertEqual(snapshot.weekly?.resetsAt, Date(timeIntervalSince1970: 1_790_089_200))
        XCTAssertNil(snapshot.window(id: "weeklyOpus"))
        XCTAssertEqual(snapshot.extraWindows.map(\.id), ["weeklySonnet"])
        XCTAssertEqual(snapshot.extraWindows.first?.category, .weekly)
        XCTAssertEqual(snapshot.peakUtilization, 73)
    }

    func testWindowIDsMatchPreProviderThresholdKeys() {
        // Persisted threshold state from v0.2 is keyed by these strings.
        XCTAssertEqual(ClaudeWindowKind.allCases.map(\.rawValue), ["session", "weekly", "weeklyOpus", "weeklySonnet"])
    }

    func testNullPrimaryWindowMeansNoUsage() throws {
        let snapshot = try ClaudeUsageDecoder.decode(Data(#"{"five_hour": null, "seven_day": {"utilization": 4}}"#.utf8))
        XCTAssertEqual(snapshot.session, ClaudeWindowKind.session.window(utilization: 0, resetsAt: nil))
        XCTAssertEqual(snapshot.weekly?.utilization, 4)
        XCTAssertNil(snapshot.weekly?.resetsAt)
    }

    func testRejectsUnexpectedBody() {
        XCTAssertThrowsError(try ClaudeUsageDecoder.decode(Data(#"{"error": {"type": "x"}}"#.utf8)))
        XCTAssertThrowsError(try ClaudeUsageDecoder.decode(Data("<html>".utf8)))
    }

    func testWindowClampsPercentages() {
        let over = ClaudeWindowKind.session.window(utilization: 112, resetsAt: nil)
        XCTAssertEqual(over.usedPercent, 100)
        XCTAssertEqual(over.remainingPercent, 0)
    }
}

final class CodexDecoderTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_790_080_380)

    func testDecodesTypicalResponse() throws {
        let json = """
        {"plan_type": "plus", "user_id": "user-x", "account_id": "acct-x",
         "rate_limit": {"allowed": true, "limit_reached": false,
           "primary_window": {"used_percent": 42, "limit_window_seconds": 18000, "reset_after_seconds": 3600, "reset_at": 1790083980},
           "secondary_window": {"used_percent": 81, "limit_window_seconds": 604800, "reset_after_seconds": 400000, "reset_at": 1790480380}},
         "credits": {"has_credits": false, "unlimited": false, "balance": null},
         "additional_rate_limits": [
           {"limit_name": "GPT-5-Codex-Spark", "metered_feature": "codex_spark",
            "rate_limit": {"allowed": true, "limit_reached": false,
              "primary_window": {"used_percent": 7, "limit_window_seconds": 18000, "reset_after_seconds": 60, "reset_at": 1790080440},
              "secondary_window": null}}]}
        """
        let snapshot = try CodexUsageDecoder.decode(Data(json.utf8), fetchedAt: now)

        XCTAssertEqual(snapshot.provider, .codex)
        XCTAssertEqual(snapshot.plan, "plus")
        XCTAssertEqual(snapshot.session, UsageWindow(id: "primary", title: "5h Limit", shortName: "5h", category: .session,
                                                     isPrimary: true, utilization: 42, resetsAt: Date(timeIntervalSince1970: 1_790_083_980)))
        XCTAssertEqual(snapshot.weekly?.id, "secondary")
        XCTAssertEqual(snapshot.weekly?.title, "Weekly Limit")
        XCTAssertEqual(snapshot.weekly?.shortName, "weekly")
        XCTAssertEqual(snapshot.weekly?.utilization, 81)
        XCTAssertEqual(snapshot.extraWindows.map(\.id), ["codex_spark.primary"])
        XCTAssertEqual(snapshot.extraWindows.first?.title, "GPT-5-Codex-Spark · 5h")
        XCTAssertEqual(snapshot.extraWindows.first?.shortName, "GPT-5-Codex-Spark 5h")
        XCTAssertEqual(snapshot.peakUtilization, 81)
    }

    func testResetAfterSecondsFallbackAndUnknownLength() throws {
        let json = #"{"rate_limit": {"primary_window": {"used_percent": 3, "reset_after_seconds": 600}}}"#
        let snapshot = try CodexUsageDecoder.decode(Data(json.utf8), fetchedAt: now)
        XCTAssertEqual(snapshot.session?.resetsAt, now.addingTimeInterval(600))
        XCTAssertEqual(snapshot.session?.title, "Primary Limit")
        XCTAssertNil(snapshot.weekly)
        XCTAssertNil(snapshot.plan)
    }

    func testPlanWithoutRateLimitHasNoWindows() throws {
        let snapshot = try CodexUsageDecoder.decode(Data(#"{"plan_type": "enterprise", "rate_limit": null}"#.utf8), fetchedAt: now)
        XCTAssertTrue(snapshot.windows.isEmpty)
        XCTAssertEqual(snapshot.plan, "enterprise")
        XCTAssertNil(snapshot.peakUtilization)
    }

    func testRejectsUnexpectedBody() {
        XCTAssertThrowsError(try CodexUsageDecoder.decode(Data(#"{"detail": "Unauthorized"}"#.utf8))) {
            XCTAssertEqual($0 as? UsageDecodingError, .unexpectedFormat(provider: .codex, snippet: #"{"detail": "Unauthorized"}"#))
        }
        XCTAssertThrowsError(try CodexUsageDecoder.decode(Data("<html>".utf8)))
    }

    func testDurationLabels() {
        XCTAssertEqual(CodexUsageDecoder.durationLabel(seconds: 18_000), "5h")
        XCTAssertEqual(CodexUsageDecoder.durationLabel(seconds: 17_900), "5h")
        XCTAssertEqual(CodexUsageDecoder.durationLabel(seconds: 86_400), "daily")
        XCTAssertEqual(CodexUsageDecoder.durationLabel(seconds: 604_800), "weekly")
        XCTAssertEqual(CodexUsageDecoder.durationLabel(seconds: 2_592_000), "monthly")
        XCTAssertEqual(CodexUsageDecoder.durationLabel(seconds: 10_800), "3h")
        XCTAssertEqual(CodexUsageDecoder.durationLabel(seconds: 864_000), "10-day")
        XCTAssertEqual(CodexUsageDecoder.durationLabel(seconds: 900), "15m")
    }

    func testCategoryFollowsWindowLength() {
        XCTAssertEqual(UsageWindowCategory(duration: 18_000), .session)
        XCTAssertEqual(UsageWindowCategory(duration: 86_400), .session)
        XCTAssertEqual(UsageWindowCategory(duration: 604_800), .weekly)
    }
}

final class ProviderSelectionTests: XCTestCase {
    private func snapshot(_ provider: UsageProvider, _ values: [Double], extra: Double? = nil) -> UsageSnapshot {
        var windows = values.enumerated().map { index, value in
            UsageWindow(id: "w\(index)", title: "", shortName: "", category: .session, isPrimary: true, utilization: value, resetsAt: nil)
        }
        if let extra {
            windows.append(UsageWindow(id: "x", title: "", shortName: "", category: .weekly, isPrimary: false, utilization: extra, resetsAt: nil))
        }
        return UsageSnapshot(provider: provider, windows: windows, fetchedAt: Date())
    }

    func testPicksProviderClosestToALimit() {
        XCTAssertEqual([snapshot(.claude, [40, 60]), snapshot(.codex, [10, 85])].mostConstrained()?.provider, .codex)
        XCTAssertEqual([snapshot(.claude, [95, 60]), snapshot(.codex, [10, 85])].mostConstrained()?.provider, .claude)
    }

    func testTieKeepsFirstAndModelWindowsDontCount() {
        XCTAssertEqual([snapshot(.claude, [50]), snapshot(.codex, [50])].mostConstrained()?.provider, .claude)
        XCTAssertEqual([snapshot(.claude, [30], extra: 100), snapshot(.codex, [50])].mostConstrained()?.provider, .codex)
    }

    func testSnapshotsWithoutWindowsAreSkipped() {
        XCTAssertEqual([snapshot(.claude, []), snapshot(.codex, [5])].mostConstrained()?.provider, .codex)
        XCTAssertNil([snapshot(.claude, [])].mostConstrained())
    }
}

final class ClaudeCredentialsTests: XCTestCase {
    func testParsesClaudeCodeBlob() throws {
        let json = #"{"claudeAiOauth":{"accessToken":"sk-ant-oat01-abc","refreshToken":"r","expiresAt":1758553200000,"scopes":["user:inference"],"subscriptionType":"max"}}"#
        let credentials = try ClaudeCredentials.parse(Data(json.utf8))
        XCTAssertEqual(credentials.accessToken, "sk-ant-oat01-abc")
        XCTAssertEqual(credentials.expiresAt, Date(timeIntervalSince1970: 1_758_553_200))
        XCTAssertEqual(credentials.subscriptionType, "max")
        XCTAssertTrue(credentials.isExpired(now: Date(timeIntervalSince1970: 1_758_553_201)))
        XCTAssertFalse(credentials.isExpired(now: Date(timeIntervalSince1970: 1_758_553_199)))
    }

    func testRejectsMissingToken() {
        XCTAssertThrowsError(try ClaudeCredentials.parse(Data(#"{"claudeAiOauth":{"refreshToken":"secret"}}"#.utf8))) {
            XCTAssertEqual($0 as? ClaudeCredentialsError, .malformed("claudeAiOauth has no accessToken (keys: refreshToken)"))
            XCTAssertFalse($0.localizedDescription.contains("secret"))
        }
        XCTAssertThrowsError(try ClaudeCredentials.parse(Data("oops".utf8))) {
            XCTAssertEqual($0 as? ClaudeCredentialsError, .malformed("not valid JSON (4 bytes, does not start with '{')"))
        }
    }

    func testMcpOnlyItemIsNotAClaudeLogin() {
        XCTAssertThrowsError(try ClaudeCredentials.parse(Data(#"{"mcpOAuth":{"server|abc":{"accessToken":"x"}}}"#.utf8))) {
            XCTAssertEqual($0 as? ClaudeCredentialsError, .noClaudeAccount(foundKeys: ["mcpOAuth"]))
            XCTAssertFalse($0.localizedDescription.contains("server|abc"))
        }
    }

    func testLoaderFallsThroughToFile() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent(".credentials.json")
        try Data(#"{"claudeAiOauth":{"accessToken":"tok"}}"#.utf8).write(to: file)

        let loader = ClaudeCredentials.loader(sources: [
            FileCredentialsSource(url: dir.appendingPathComponent("missing.json")),
            FileCredentialsSource(url: file),
        ])
        XCTAssertEqual(try loader.load().accessToken, "tok")

        let empty = ClaudeCredentials.loader(sources: [FileCredentialsSource(url: dir.appendingPathComponent("nope"))])
        XCTAssertThrowsError(try empty.load()) { error in
            XCTAssertEqual(error as? ClaudeCredentialsError, .notFound)
        }
    }

    #if os(macOS)
    func testDecodesHexKeychainOutput() {
        let hex = Data("7b2261223a317d".utf8) // {"a":1}
        XCTAssertEqual(String(decoding: KeychainCLICredentialsSource.decodePassword(hex), as: UTF8.self), #"{"a":1}"#)
        XCTAssertEqual(KeychainCLICredentialsSource.decodePassword(Data("{\"a\":1}\n".utf8)), Data(#"{"a":1}"#.utf8))
    }
    #endif
}

final class CodexCredentialsTests: XCTestCase {
    // Payloads: {"exp":1790092800,"sub":"u?>"} (base64url with '_') and
    // {"https://api.openai.com/auth":{"chatgpt_account_id":"acct-from-jwt","chatgpt_plan_type":"plus"}}
    private let accessToken = "eyJhbGciOiJSUzI1NiJ9.eyJleHAiOjE3OTAwOTI4MDAsInN1YiI6InU_PiJ9.c2ln"
    private let idToken = "eyJhbGciOiJSUzI1NiJ9.eyJodHRwczovL2FwaS5vcGVuYWkuY29tL2F1dGgiOnsiY2hhdGdwdF9hY2NvdW50X2lkIjoiYWNjdC1mcm9tLWp3dCIsImNoYXRncHRfcGxhbl90eXBlIjoicGx1cyJ9fQ.c2ln"

    func testParsesAuthJSON() throws {
        let json = """
        {"auth_mode": "chatgpt", "OPENAI_API_KEY": null,
         "tokens": {"id_token": "\(idToken)", "access_token": "\(accessToken)", "refresh_token": "refresh-secret", "account_id": "acct-1"},
         "last_refresh": "2026-09-20T08:00:00Z"}
        """
        let credentials = try CodexCredentials.parse(Data(json.utf8))
        XCTAssertEqual(credentials.accessToken, accessToken)
        XCTAssertEqual(credentials.accountID, "acct-1")
        XCTAssertEqual(credentials.expiresAt, Date(timeIntervalSince1970: 1_790_092_800))
        XCTAssertTrue(credentials.isExpired(now: Date(timeIntervalSince1970: 1_790_092_801)))
    }

    func testAccountIDFallsBackToIDTokenAndOpaqueTokensWork() throws {
        let json = #"{"tokens": {"id_token": "\#(idToken)", "access_token": "opaque", "refresh_token": "r", "account_id": null}}"#
        let credentials = try CodexCredentials.parse(Data(json.utf8))
        XCTAssertEqual(credentials.accountID, "acct-from-jwt")
        XCTAssertNil(credentials.expiresAt)
        XCTAssertFalse(credentials.isExpired())
    }

    func testAPIKeyLoginHasNoLimits() {
        XCTAssertThrowsError(try CodexCredentials.parse(Data(#"{"auth_mode": "apikey", "OPENAI_API_KEY": "sk-proj-secret"}"#.utf8))) {
            XCTAssertEqual($0 as? CodexCredentialsError, .apiKeyOnly)
            XCTAssertFalse($0.localizedDescription.contains("sk-proj-secret"))
        }
    }

    func testErrorsNeverContainTokenValues() {
        XCTAssertThrowsError(try CodexCredentials.parse(Data(#"{"tokens": {"refresh_token": "refresh-secret"}}"#.utf8))) {
            XCTAssertEqual($0 as? CodexCredentialsError, .malformed("tokens has no access_token (keys: refresh_token)"))
            XCTAssertFalse($0.localizedDescription.contains("refresh-secret"))
        }
        XCTAssertThrowsError(try CodexCredentials.parse(Data(#"{"OPENAI_API_KEY": null, "personal_access_token": "pat-secret"}"#.utf8))) {
            XCTAssertEqual($0 as? CodexCredentialsError, .noChatGPTAccount(foundKeys: ["OPENAI_API_KEY", "personal_access_token"]))
            XCTAssertFalse($0.localizedDescription.contains("pat-secret"))
        }
        XCTAssertThrowsError(try CodexCredentials.parse(Data("not json".utf8))) {
            XCTAssertEqual($0 as? CodexCredentialsError, .malformed("not valid JSON (8 bytes, does not start with '{')"))
        }
    }

    func testLoaderReportsNotFound() {
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("auth.json")
        XCTAssertThrowsError(try CodexCredentials.loader(sources: [FileCredentialsSource(url: missing)]).load()) {
            XCTAssertEqual($0 as? CodexCredentialsError, .notFound)
        }
    }

    func testHomeHonoursCodexHome() {
        XCTAssertEqual(CodexCredentials.home(environment: ["CODEX_HOME": "/opt/codex"]).path, "/opt/codex")
        XCTAssertTrue(CodexCredentials.home(environment: [:]).path.hasSuffix("/.codex"))
    }

    #if canImport(CryptoKit)
    func testKeychainAccountMatchesCodexKeyringKey() {
        // Codex: "cli|" + first 16 hex of sha256(canonical CODEX_HOME).
        XCTAssertEqual(CodexCredentials.keychainAccount(codexHome: URL(fileURLWithPath: "/nonexistent-headroom/.codex")),
                       "cli|e604480dc9287667")
    }
    #endif
}

final class APIClientTests: XCTestCase {
    func testClaudeRequestHeaders() {
        let request = ClaudeUsageClient().makeRequest(accessToken: "tok")
        XCTAssertEqual(request.url?.absoluteString, "https://api.anthropic.com/api/oauth/usage")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer tok")
        XCTAssertEqual(request.value(forHTTPHeaderField: "anthropic-beta"), "oauth-2025-04-20")
    }

    func testCodexRequestHeaders() {
        let client = CodexUsageClient()
        let request = client.makeRequest(credentials: CodexCredentials(accessToken: "tok", accountID: "acct-1", expiresAt: nil))
        XCTAssertEqual(request.url?.absoluteString, "https://chatgpt.com/backend-api/wham/usage")
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer tok")
        XCTAssertEqual(request.value(forHTTPHeaderField: "ChatGPT-Account-Id"), "acct-1")

        let noAccount = client.makeRequest(credentials: CodexCredentials(accessToken: "tok", accountID: nil, expiresAt: nil))
        XCTAssertNil(noAccount.value(forHTTPHeaderField: "ChatGPT-Account-Id"))
    }

    func testStatusMapping() {
        XCTAssertNoThrow(try UsageHTTP.validate(status: 200, retryAfterHeader: nil, provider: .claude, tokenExpired: false))
        XCTAssertThrowsError(try UsageHTTP.validate(status: 401, retryAfterHeader: nil, provider: .codex, tokenExpired: true)) {
            XCTAssertEqual($0 as? UsageAPIError, .unauthorized(.codex, tokenExpired: true))
            XCTAssertTrue($0.localizedDescription.contains("Codex"))
        }
        XCTAssertThrowsError(try UsageHTTP.validate(status: 429, retryAfterHeader: "120", provider: .codex, tokenExpired: false)) {
            XCTAssertEqual($0 as? UsageAPIError, .rateLimited(.codex, retryAfter: 120))
        }
        XCTAssertThrowsError(try UsageHTTP.validate(status: 500, retryAfterHeader: nil, provider: .claude, tokenExpired: false)) {
            XCTAssertEqual($0 as? UsageAPIError, .http(.claude, status: 500))
        }
    }
}

final class ThresholdTests: XCTestCase {
    private let reset1 = Date(timeIntervalSince1970: 1_000_000)
    private let reset2 = Date(timeIntervalSince1970: 1_000_000 + 5 * 3600)

    private func snapshot(_ utilization: Double, resetsAt: Date?) -> UsageSnapshot {
        UsageSnapshot(provider: .claude, windows: [ClaudeWindowKind.session.window(utilization: utilization, resetsAt: resetsAt)], fetchedAt: Date())
    }

    func testFiresOncePerThreshold() {
        let evaluator = ThresholdEvaluator()
        var state = ThresholdState()
        let thresholds: [UsageWindowCategory: [Int]] = [.session: [75, 90]]

        XCTAssertTrue(evaluator.evaluate(snapshot: snapshot(50, resetsAt: reset1), thresholds: thresholds, state: &state).isEmpty)
        XCTAssertEqual(evaluator.evaluate(snapshot: snapshot(76, resetsAt: reset1), thresholds: thresholds, state: &state).map(\.threshold), [75])
        XCTAssertTrue(evaluator.evaluate(snapshot: snapshot(80, resetsAt: reset1), thresholds: thresholds, state: &state).isEmpty)
        XCTAssertEqual(evaluator.evaluate(snapshot: snapshot(95, resetsAt: reset1), thresholds: thresholds, state: &state).map(\.threshold), [90])
        XCTAssertTrue(evaluator.evaluate(snapshot: snapshot(99, resetsAt: reset1), thresholds: thresholds, state: &state).isEmpty)
    }

    func testJumpingPastSeveralThresholdsSendsOnlyHighest() {
        var state = ThresholdState()
        let alerts = ThresholdEvaluator().evaluate(snapshot: snapshot(92, resetsAt: reset1), thresholds: [.session: [50, 75, 90]], state: &state)
        XCTAssertEqual(alerts.map(\.threshold), [90])
        XCTAssertEqual(state.fired["session"], [50, 75, 90])
    }

    func testAlertNamesProviderAndWindow() throws {
        let json = #"{"rate_limit": {"secondary_window": {"used_percent": 91, "limit_window_seconds": 604800, "reset_at": 1790480380}}}"#
        let codex = try CodexUsageDecoder.decode(Data(json.utf8))
        var state = ThresholdState()
        let alerts = ThresholdEvaluator().evaluate(snapshot: codex, thresholds: [.session: [50], .weekly: [75, 90]], state: &state)
        XCTAssertEqual(alerts.count, 1)
        XCTAssertEqual(alerts.first?.provider, .codex)
        XCTAssertEqual(alerts.first?.windowID, "secondary")
        XCTAssertEqual(alerts.first?.windowName, "weekly")
        XCTAssertEqual(alerts.first?.threshold, 90)
    }

    func testRearmsAfterWindowReset() {
        let evaluator = ThresholdEvaluator()
        var state = ThresholdState()
        let thresholds: [UsageWindowCategory: [Int]] = [.session: [75]]

        XCTAssertEqual(evaluator.evaluate(snapshot: snapshot(80, resetsAt: reset1), thresholds: thresholds, state: &state).count, 1)
        // New window, but usage already high again by the next poll.
        XCTAssertEqual(evaluator.evaluate(snapshot: snapshot(78, resetsAt: reset2), thresholds: thresholds, state: &state).count, 1)
    }

    func testRearmsWithHysteresis() {
        let evaluator = ThresholdEvaluator()
        var state = ThresholdState()
        let thresholds: [UsageWindowCategory: [Int]] = [.session: [75]]

        XCTAssertEqual(evaluator.evaluate(snapshot: snapshot(76, resetsAt: nil), thresholds: thresholds, state: &state).count, 1)
        XCTAssertTrue(evaluator.evaluate(snapshot: snapshot(72, resetsAt: nil), thresholds: thresholds, state: &state).isEmpty)
        XCTAssertTrue(evaluator.evaluate(snapshot: snapshot(76, resetsAt: nil), thresholds: thresholds, state: &state).isEmpty)
        XCTAssertTrue(evaluator.evaluate(snapshot: snapshot(10, resetsAt: nil), thresholds: thresholds, state: &state).isEmpty)
        XCTAssertEqual(evaluator.evaluate(snapshot: snapshot(76, resetsAt: nil), thresholds: thresholds, state: &state).count, 1)
    }

    func testSmallResetJitterDoesNotRearm() {
        let evaluator = ThresholdEvaluator()
        var state = ThresholdState()
        let thresholds: [UsageWindowCategory: [Int]] = [.session: [75]]
        XCTAssertEqual(evaluator.evaluate(snapshot: snapshot(80, resetsAt: reset1), thresholds: thresholds, state: &state).count, 1)
        XCTAssertTrue(evaluator.evaluate(snapshot: snapshot(80, resetsAt: reset1.addingTimeInterval(2)), thresholds: thresholds, state: &state).isEmpty)
    }

    func testParser() {
        XCTAssertEqual(ThresholdParser.parse("90, 75,75 ; 0 150 abc 50%"), [50, 75, 90])
        XCTAssertEqual(ThresholdParser.parse(""), [])
        XCTAssertEqual(ThresholdParser.format([75, 90]), "75, 90")
    }
}

final class FormattingTests: XCTestCase {
    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()
    private let locale = Locale(identifier: "en_GB")
    // Tuesday 2026-09-22 12:33 UTC
    private let now = Date(timeIntervalSince1970: 1_790_080_380)

    func testCountdown() {
        XCTAssertEqual(UsageFormatting.countdown(to: now.addingTimeInterval(3 * 3600 + 27 * 60 + 30), now: now), "3h 27m")
        XCTAssertEqual(UsageFormatting.countdown(to: now.addingTimeInterval(2 * 86_400 + 4 * 3600), now: now), "2d 4h")
        XCTAssertEqual(UsageFormatting.countdown(to: now.addingTimeInterval(12 * 60), now: now), "12m")
        XCTAssertEqual(UsageFormatting.countdown(to: now.addingTimeInterval(20), now: now), "<1m")
        XCTAssertEqual(UsageFormatting.countdown(to: now.addingTimeInterval(-5), now: now), "now")
    }

    func testResetDescription() {
        func describe(_ offset: TimeInterval) -> String {
            UsageFormatting.resetDescription(now.addingTimeInterval(offset), now: now, calendar: calendar, locale: locale)
        }
        XCTAssertEqual(describe(3 * 3600 + 27 * 60), "Today at 16:00")
        XCTAssertEqual(describe(24 * 3600 - 33 * 60), "Tomorrow at 12:00")
        XCTAssertEqual(describe(2 * 86_400), "Thu at 12:33")
        XCTAssertEqual(describe(10 * 86_400), "2 Oct at 12:33")
    }

    func testPercentAndLevel() {
        XCTAssertEqual(UsageFormatting.percent(59.4), "59")
        XCTAssertEqual(UsageFormatting.percent(-3), "0")
        XCTAssertEqual(UsageLevel(utilization: 59), .normal)
        XCTAssertEqual(UsageLevel(utilization: 73), .warning)
        XCTAssertEqual(UsageLevel(utilization: 90), .critical)
    }

    func testRelativeAge() {
        XCTAssertEqual(UsageFormatting.relativeAge(of: now.addingTimeInterval(-10), now: now), "just now")
        XCTAssertEqual(UsageFormatting.relativeAge(of: now.addingTimeInterval(-180), now: now), "3m ago")
        XCTAssertEqual(UsageFormatting.relativeAge(of: now.addingTimeInterval(-7300), now: now), "2h ago")
    }
}
