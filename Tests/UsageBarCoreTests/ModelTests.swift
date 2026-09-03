import Foundation
import XCTest
@testable import UsageBarCore

final class ModelTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_788_000_000)

    // MARK: Format

    func testCountdown() {
        XCTAssertEqual(Format.countdown(to: now.addingTimeInterval(-5), from: now), "now")
        XCTAssertEqual(Format.countdown(to: now.addingTimeInterval(90), from: now), "1m")
        XCTAssertEqual(Format.countdown(to: now.addingTimeInterval(2 * 3_600 + 10 * 60), from: now), "2h 10m")
        XCTAssertEqual(Format.countdown(to: now.addingTimeInterval(3 * 3_600), from: now), "3h")
        XCTAssertEqual(Format.countdown(to: now.addingTimeInterval(4 * 86_400 + 3 * 3_600 + 59 * 60), from: now), "4d 3h")
        XCTAssertEqual(Format.countdown(to: now.addingTimeInterval(2 * 86_400), from: now), "2d")
    }

    func testMoneyAndPlan() {
        XCTAssertEqual(Format.money(83.2, currency: "CNY"), "¥83.20")
        XCTAssertEqual(Format.money(5, currency: "USD"), "$5.00")
        XCTAssertEqual(Format.money(1.5, currency: "CHF"), "CHF 1.50")
        XCTAssertEqual(Format.planTitle("max"), "Max")
        XCTAssertEqual(Format.planTitle("team_plus"), "Team plus")
    }

    func testAge() {
        XCTAssertEqual(Format.age(of: now.addingTimeInterval(-10), now: now), "just now")
        XCTAssertEqual(Format.age(of: now.addingTimeInterval(-130), now: now), "2 min ago")
        XCTAssertEqual(Format.age(of: now.addingTimeInterval(-7_300), now: now), "2 h ago")
    }

    // MARK: Meter

    func testMeterValueAndDetail() {
        let quota = Meter(id: "s", label: "Session", percentUsed: 142, resetsAt: now.addingTimeInterval(3_600))
        XCTAssertEqual(quota.percentUsed, 100, "clamped")
        XCTAssertEqual(quota.value(), "100%")
        XCTAssertEqual(quota.detail(now: now), "resets 1h")

        let balance = Meter(id: "b", label: "Balance", percentUsed: 24.4, amount: 83.2, currency: "CNY")
        XCTAssertTrue(balance.isBalance)
        XCTAssertEqual(balance.value(), "¥83.20")
        XCTAssertEqual(balance.detail(now: now), "24% of 30d peak spent")

        let unknown = Meter(id: "u", label: "Balance", percentUsed: nil, amount: 10, currency: "USD")
        XCTAssertNil(unknown.detail(now: now))
        XCTAssertEqual(Meter(id: "n", label: "x", percentUsed: nil).value(), "—")
    }

    // MARK: Snapshot

    func testHeadlineStates() {
        XCTAssertEqual(UsageSnapshot.pending.headline.health, .unknown)

        let ok = UsageSnapshot(readings: [
            ProviderReading(provider: .claude, state: .ok, readAt: now),
            ProviderReading(provider: .deepseek, state: .ok, readAt: now),
        ], readAt: now)
        XCTAssertEqual(ok.headline.health, .ok)
        XCTAssertTrue(ok.headline.text.hasPrefix("2 sources"))

        let partial = UsageSnapshot(readings: [
            ProviderReading(provider: .claude, state: .ok, readAt: now),
            ProviderReading(provider: .codex, state: .signIn("Sign in to Codex"), readAt: now),
        ], readAt: now)
        XCTAssertEqual(partial.headline.health, .failing)
        XCTAssertTrue(partial.headline.text.contains("Codex not read"), partial.headline.text)

        let none = UsageSnapshot(readings: [
            ProviderReading(provider: .claude, state: .error("timeout"), readAt: now),
        ], readAt: now)
        XCTAssertTrue(none.headline.text.hasPrefix("No source readable"))
    }

    func testTrailingAndExhausted() {
        let claude = ProviderReading(provider: .claude, state: .ok, plan: "max", meters: [
            Meter(id: "s", label: "Session", percentUsed: 100),
        ], readAt: now)
        XCTAssertEqual(claude.trailing, "Max")
        let deepseek = ProviderReading(provider: .deepseek, state: .ok, meters: [
            Meter(id: "b", label: "Balance", percentUsed: nil, amount: 83.2, currency: "CNY"),
        ], readAt: now)
        XCTAssertEqual(deepseek.trailing, "¥83.20")
        XCTAssertEqual(ProviderReading(provider: .codex, state: .signIn("Sign in to Codex")).trailing, "Sign in to Codex")

        let snapshot = UsageSnapshot(readings: [claude, deepseek], readAt: now)
        XCTAssertTrue(snapshot.anyWindowExhausted)
        XCTAssertFalse(UsageSnapshot(readings: [deepseek], readAt: now).anyWindowExhausted)
    }

    // MARK: Samples

    func testSampleStorePercentSpentSincePeak() {
        var store = SampleStore()
        XCTAssertNil(store.record(100, for: "k", at: now), "no spend yet")
        XCTAssertEqual(store.record(75, for: "k", at: now.addingTimeInterval(3_600))!, 25, accuracy: 0.001)
        // A top-up above the peak resets the bar.
        XCTAssertNil(store.record(200, for: "k", at: now.addingTimeInterval(7_200)))
        // Unchanged and recent: not a new sample.
        _ = store.record(200, for: "k", at: now.addingTimeInterval(7_260))
        XCTAssertEqual(store.samples["k"]?.count, 3)
        // Samples older than the window fall out, so the peak moves.
        _ = store.record(50, for: "k", at: now.addingTimeInterval(SampleStore.window + 10_000))
        XCTAssertEqual(store.samples["k"]?.count, 1)
    }

    func testSampleStoreRoundTrip() throws {
        let path = NSTemporaryDirectory() + "usage-bar-tests-\(UUID().uuidString)/samples.json"
        var store = SampleStore()
        _ = store.record(100, for: "deepseek:CNY", at: now)
        _ = store.record(80, for: "deepseek:CNY", at: now.addingTimeInterval(3_600))
        try store.save(to: path)
        let loaded = SampleStore.load(from: path)
        XCTAssertEqual(loaded.samples["deepseek:CNY"]?.count, 2)
        XCTAssertEqual(loaded.percentSpent(80, for: "deepseek:CNY")!, 20, accuracy: 0.001)
        XCTAssertEqual(SampleStore.load(from: path + ".missing"), SampleStore())
    }

    // MARK: Credentials

    func testClaudeCredentialBlob() {
        let blob = #"{"claudeAiOauth":{"accessToken":"sk-ant-oat01-abc","expiresAt":9999999999999,"subscriptionType":"max"}}"#
        let credential = ClaudeCredential.parse(blob)
        XCTAssertEqual(credential?.token, "sk-ant-oat01-abc")
        XCTAssertEqual(credential?.plan, "max")
        XCTAssertEqual(credential?.isExpired(), false)
        XCTAssertNil(ClaudeCredential.parse(#"{"mcpOAuth":{}}"#))
        let expired = ClaudeCredential.parse(#"{"claudeAiOauth":{"accessToken":"x","expiresAt":1000}}"#)
        XCTAssertEqual(expired?.isExpired(), true)
    }

    func testCodexAuthFile() {
        // A JWT whose claims segment is {"https://api.openai.com/auth":{"chatgpt_plan_type":"plus","chatgpt_account_id":"acct_1"}}
        let claims = #"{"https://api.openai.com/auth":{"chatgpt_plan_type":"plus","chatgpt_account_id":"acct_1"}}"#
        let segment = Data(claims.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        let jwt = "eyJhbGciOiJSUzI1NiJ9.\(segment).sig"
        let file = #"{"tokens":{"access_token":"\#(jwt)","id_token":"\#(jwt)"},"last_refresh":"2026-08-29T02:37:00Z"}"#
        let credential = CodexCredential.parse(Data(file.utf8))
        XCTAssertEqual(credential?.token, jwt)
        XCTAssertEqual(credential?.plan, "plus")
        XCTAssertEqual(credential?.accountID, "acct_1")

        let apiKey = CodexCredential.parse(Data(#"{"OPENAI_API_KEY":"sk-x"}"#.utf8))
        XCTAssertEqual(apiKey?.token, "sk-x")
        XCTAssertNil(CodexCredential.parse(Data(#"{"tokens":{}}"#.utf8)))
    }

    func testAPIKeyFirstLineOnly() {
        XCTAssertEqual(APIKey.usable("sk-abc\nsecond line\n"), "sk-abc")
        XCTAssertNil(APIKey.usable("  \n"))
        XCTAssertNil(APIKey.usable(nil))
    }

    func testEnvFileAndSpendMeter() throws {
        let path = NSTemporaryDirectory() + "usage-bar-env-\(UUID().uuidString)"
        try "# note\nexport A=\"one two\"\nB='x'\nC=plain\nbad line\n".write(toFile: path, atomically: true, encoding: .utf8)
        let values = APIKey.parseEnvFile(path)
        XCTAssertEqual(values, ["A": "one two", "B": "x", "C": "plain"])
        XCTAssertEqual(APIKey.parseEnvFile(path + ".missing"), [:])

        let spend = Meter(id: "s", label: "Spent · 30d", percentUsed: nil, amount: 12.3456, currency: "USD", spent: true)
        XCTAssertFalse(spend.isBalance)
        XCTAssertEqual(spend.value(), "$12.35")
        XCTAssertEqual(spend.detail(now: now), "spent in the last 30 days")
        let reading = ProviderReading(provider: .soniox, state: .ok, meters: [spend], readAt: now)
        XCTAssertEqual(reading.trailing, "$12.35 spent")
    }
}
