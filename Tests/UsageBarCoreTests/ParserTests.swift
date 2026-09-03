import Foundation
import XCTest
@testable import UsageBarCore

/// The parsers, against payloads in the shape each endpoint answers with.
/// The fixtures were written to the shapes Baby Menu's provider code
/// documents against the live endpoints (2026-09), not captured from an
/// account, so they carry no identity; a live check is `usage-bar --doctor`.
final class ParserTests: XCTestCase {

    private func fixture(_ name: String) throws -> Data {
        let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"))
        return try Data(contentsOf: url)
    }

    // MARK: Claude

    func testClaudeWindowsAndScopedLimits() throws {
        let meters = try XCTUnwrap(ClaudeUsage.parse(fixture("claude-usage")))
        XCTAssertEqual(meters.map(\.id), ["session", "weekly", "weekly-opus", "weekly-scoped-sonnet"])
        XCTAssertEqual(meters[0].percentUsed, 42.5)
        XCTAssertEqual(meters[0].label, "Session")
        XCTAssertNotNil(meters[0].resetsAt, "fractional-second ISO instant must decode")
        XCTAssertEqual(meters[2].percentUsed, 31.2)
        XCTAssertEqual(meters[3].label, "Weekly · Sonnet")
        XCTAssertTrue(meters[3].active)
        // A null window is absent, not a fabricated zero.
        XCTAssertFalse(meters.contains { $0.id == "weekly-sonnet" })
    }

    func testClaudeUnreadableBodyIsNil() {
        XCTAssertNil(ClaudeUsage.parse(Data("{}".utf8)))
        XCTAssertNil(ClaudeUsage.parse(Data("not json".utf8)))
    }

    // MARK: Codex

    func testCodexWindowsPlanAndHiddenSpark() throws {
        let parsed = try XCTUnwrap(CodexUsage.parse(fixture("codex-usage")))
        XCTAssertEqual(parsed.plan, "plus")
        XCTAssertEqual(parsed.meters.map(\.label), [
            "Session", "Weekly", "GPT-5 Pro · weekly", "Code review · weekly",
        ])
        XCTAssertEqual(parsed.meters[0].percentUsed, 7)
        XCTAssertEqual(parsed.meters[0].resetsAt, Date(timeIntervalSince1970: 1_788_019_200), "reset_at is epoch seconds")
        XCTAssertEqual(parsed.meters[1].percentUsed, 63.4)
        XCTAssertNotNil(parsed.meters[1].resetsAt, "reset_after_seconds becomes an instant")
        XCTAssertFalse(parsed.meters.contains { $0.label.lowercased().contains("spark") })
    }

    // MARK: Antigravity

    func testAntigravityBucketsBecomePercentUsed() throws {
        let meters = try XCTUnwrap(AntigravityUsage.parse(fixture("antigravity-usage")))
        XCTAssertEqual(meters.map(\.id), ["gemini-5h", "gemini-weekly", "claude-weekly"])
        XCTAssertEqual(meters[0].label, "Gemini · session")
        XCTAssertEqual(meters[0].percentUsed!, 12, accuracy: 0.001)
        XCTAssertEqual(meters[1].label, "Gemini · weekly")
        XCTAssertEqual(meters[2].percentUsed, 100)
        XCTAssertEqual(meters[2].resetsAt, ISO8601DateFormatter().date(from: "2026-09-05T00:00:00Z"))
    }

    func testAntigravityWrongCommandIsNil() {
        XCTAssertNil(AntigravityUsage.parse(Data(#"{"command":{"name":"help","data":{}}}"#.utf8)))
    }

    // MARK: Balances

    func testDeepSeekDecimalStrings() throws {
        let balances = try XCTUnwrap(DeepSeekBalance.parse(fixture("deepseek-balance")))
        XCTAssertEqual(balances.count, 1)
        XCTAssertEqual(balances[0].currency, "CNY")
        XCTAssertEqual(balances[0].total, 83.2)
        XCTAssertEqual(balances[0].toppedUp, 83.2)
    }

    func testMoonshotCodeGate() throws {
        let balance = try XCTUnwrap(MoonshotBalance.parse(fixture("moonshot-balance")))
        XCTAssertEqual(balance.available, 120)
        XCTAssertEqual(balance.voucher, 20)
        XCTAssertNil(MoonshotBalance.parse(Data(#"{"code":401,"data":{"available_balance":1}}"#.utf8)))
        XCTAssertEqual(MoonshotBalance.currency(forHost: "api.moonshot.cn"), "CNY")
        XCTAssertEqual(MoonshotBalance.currency(forHost: "api.moonshot.ai"), "USD")
    }

    func testSonioxSpend() throws {
        XCTAssertEqual(try XCTUnwrap(SonioxUsage.parse(fixture("soniox-usage"))), 12.3456, accuracy: 0.0001)
        XCTAssertNil(SonioxUsage.parse(Data("{}".utf8)))
    }
}
