import XCTest
@testable import HeadroomCore

final class UsageDecoderTests: XCTestCase {
    func testDecodesTypicalResponse() throws {
        let json = """
        {"five_hour": {"utilization": 59.0, "resets_at": "2026-09-22T16:00:00.412345+00:00"},
         "seven_day": {"utilization": 73, "resets_at": "2026-09-22T15:00:00Z"},
         "seven_day_oauth_apps": null,
         "seven_day_opus": null,
         "seven_day_sonnet": {"utilization": 12.5, "resets_at": "2026-09-25T15:00:00+00:00"},
         "extra_usage": {"is_enabled": false}}
        """
        let snapshot = try UsageDecoder.decode(Data(json.utf8))

        XCTAssertEqual(snapshot.session?.utilization, 59)
        XCTAssertEqual(snapshot.session?.resetsAt?.timeIntervalSince1970 ?? 0, 1_790_092_800 + 0.412345, accuracy: 0.001)
        XCTAssertEqual(snapshot.weekly?.utilization, 73)
        XCTAssertEqual(snapshot.weekly?.resetsAt, Date(timeIntervalSince1970: 1_790_089_200))
        XCTAssertNil(snapshot.window(.weeklyOpus))
        XCTAssertEqual(snapshot.extraWindows.map(\.kind), [.weeklySonnet])
    }

    func testNullPrimaryWindowMeansNoUsage() throws {
        let snapshot = try UsageDecoder.decode(Data(#"{"five_hour": null, "seven_day": {"utilization": 4}}"#.utf8))
        XCTAssertEqual(snapshot.session, UsageWindow(kind: .session, utilization: 0, resetsAt: nil))
        XCTAssertEqual(snapshot.weekly?.utilization, 4)
        XCTAssertNil(snapshot.weekly?.resetsAt)
    }

    func testRejectsUnexpectedBody() {
        XCTAssertThrowsError(try UsageDecoder.decode(Data(#"{"error": {"type": "x"}}"#.utf8)))
        XCTAssertThrowsError(try UsageDecoder.decode(Data("<html>".utf8)))
    }

    func testWindowClampsPercentages() {
        let over = UsageWindow(kind: .session, utilization: 112, resetsAt: nil)
        XCTAssertEqual(over.usedPercent, 100)
        XCTAssertEqual(over.remainingPercent, 0)
    }
}

final class CredentialsTests: XCTestCase {
    func testParsesClaudeCodeBlob() throws {
        let json = #"{"claudeAiOauth":{"accessToken":"sk-ant-oat01-abc","refreshToken":"r","expiresAt":1758553200000,"scopes":["user:inference"],"subscriptionType":"max"}}"#
        let credentials = try OAuthCredentials.parse(Data(json.utf8))
        XCTAssertEqual(credentials.accessToken, "sk-ant-oat01-abc")
        XCTAssertEqual(credentials.expiresAt, Date(timeIntervalSince1970: 1_758_553_200))
        XCTAssertEqual(credentials.subscriptionType, "max")
        XCTAssertTrue(credentials.isExpired(now: Date(timeIntervalSince1970: 1_758_553_201)))
        XCTAssertFalse(credentials.isExpired(now: Date(timeIntervalSince1970: 1_758_553_199)))
    }

    func testRejectsMissingToken() {
        XCTAssertThrowsError(try OAuthCredentials.parse(Data(#"{"claudeAiOauth":{"refreshToken":"secret"}}"#.utf8))) {
            XCTAssertEqual($0 as? CredentialsError, .malformed("claudeAiOauth has no accessToken (keys: refreshToken)"))
        }
        XCTAssertThrowsError(try OAuthCredentials.parse(Data("oops".utf8))) {
            XCTAssertEqual($0 as? CredentialsError, .malformed("not valid JSON (4 bytes, does not start with '{')"))
        }
    }

    func testMcpOnlyItemIsNotAClaudeLogin() {
        XCTAssertThrowsError(try OAuthCredentials.parse(Data(#"{"mcpOAuth":{"server|abc":{"accessToken":"x"}}}"#.utf8))) {
            XCTAssertEqual($0 as? CredentialsError, .noClaudeAccount(foundKeys: ["mcpOAuth"]))
            XCTAssertFalse($0.localizedDescription.contains("server|abc"))
        }
    }

    func testCompositeFallsThroughToFile() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent(".credentials.json")
        try Data(#"{"claudeAiOauth":{"accessToken":"tok"}}"#.utf8).write(to: file)

        let composite = CompositeCredentialsSource(sources: [
            FileCredentialsSource(url: dir.appendingPathComponent("missing.json")),
            FileCredentialsSource(url: file),
        ])
        XCTAssertEqual(try composite.loadRequired().accessToken, "tok")

        let empty = CompositeCredentialsSource(sources: [FileCredentialsSource(url: dir.appendingPathComponent("nope"))])
        XCTAssertThrowsError(try empty.loadRequired()) { error in
            XCTAssertEqual(error as? CredentialsError, .notFound)
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

final class APIClientTests: XCTestCase {
    func testRequestHeaders() {
        let request = UsageAPIClient().makeRequest(accessToken: "tok")
        XCTAssertEqual(request.url?.absoluteString, "https://api.anthropic.com/api/oauth/usage")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer tok")
        XCTAssertEqual(request.value(forHTTPHeaderField: "anthropic-beta"), "oauth-2025-04-20")
    }

    func testStatusMapping() {
        XCTAssertNoThrow(try UsageAPIClient.validate(status: 200, retryAfterHeader: nil))
        XCTAssertThrowsError(try UsageAPIClient.validate(status: 401, retryAfterHeader: nil)) {
            XCTAssertEqual($0 as? UsageAPIError, .unauthorized)
        }
        XCTAssertThrowsError(try UsageAPIClient.validate(status: 429, retryAfterHeader: "120")) {
            XCTAssertEqual($0 as? UsageAPIError, .rateLimited(retryAfter: 120))
        }
        XCTAssertThrowsError(try UsageAPIClient.validate(status: 500, retryAfterHeader: nil)) {
            XCTAssertEqual($0 as? UsageAPIError, .http(status: 500))
        }
    }
}

final class ThresholdTests: XCTestCase {
    private let reset1 = Date(timeIntervalSince1970: 1_000_000)
    private let reset2 = Date(timeIntervalSince1970: 1_000_000 + 5 * 3600)

    private func snapshot(_ utilization: Double, resetsAt: Date?) -> UsageSnapshot {
        UsageSnapshot(windows: [UsageWindow(kind: .session, utilization: utilization, resetsAt: resetsAt)], fetchedAt: Date())
    }

    func testFiresOncePerThreshold() {
        let evaluator = ThresholdEvaluator()
        var state = ThresholdState()
        let thresholds: [UsageWindowKind: [Int]] = [.session: [75, 90]]

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

    func testRearmsAfterWindowReset() {
        let evaluator = ThresholdEvaluator()
        var state = ThresholdState()
        let thresholds: [UsageWindowKind: [Int]] = [.session: [75]]

        XCTAssertEqual(evaluator.evaluate(snapshot: snapshot(80, resetsAt: reset1), thresholds: thresholds, state: &state).count, 1)
        // New window, but usage already high again by the next poll.
        XCTAssertEqual(evaluator.evaluate(snapshot: snapshot(78, resetsAt: reset2), thresholds: thresholds, state: &state).count, 1)
    }

    func testRearmsWithHysteresis() {
        let evaluator = ThresholdEvaluator()
        var state = ThresholdState()
        let thresholds: [UsageWindowKind: [Int]] = [.session: [75]]

        XCTAssertEqual(evaluator.evaluate(snapshot: snapshot(76, resetsAt: nil), thresholds: thresholds, state: &state).count, 1)
        XCTAssertTrue(evaluator.evaluate(snapshot: snapshot(72, resetsAt: nil), thresholds: thresholds, state: &state).isEmpty)
        XCTAssertTrue(evaluator.evaluate(snapshot: snapshot(76, resetsAt: nil), thresholds: thresholds, state: &state).isEmpty)
        XCTAssertTrue(evaluator.evaluate(snapshot: snapshot(10, resetsAt: nil), thresholds: thresholds, state: &state).isEmpty)
        XCTAssertEqual(evaluator.evaluate(snapshot: snapshot(76, resetsAt: nil), thresholds: thresholds, state: &state).count, 1)
    }

    func testSmallResetJitterDoesNotRearm() {
        let evaluator = ThresholdEvaluator()
        var state = ThresholdState()
        let thresholds: [UsageWindowKind: [Int]] = [.session: [75]]
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
