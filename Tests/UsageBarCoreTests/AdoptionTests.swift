import Foundation
import XCTest
@testable import UsageBarCore

/// The 2026-09-25 adoption fixes: a source that is not set up is not a
/// failure, an expired Claude token keeps the last numbers instead of
/// blanking them, and the app says when it started and stopped.
final class AdoptionTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_788_000_000)

    private func ok(_ provider: ProviderID, percent: Double = 42) -> ProviderReading {
        ProviderReading(
            provider: provider, state: .ok, plan: "max",
            meters: [Meter(id: "session", label: "Session", percentUsed: percent)],
            readAt: now, attemptedAt: now
        )
    }

    // MARK: - Not set up

    func testANotSetUpSourceIsNotAFailureAndNotARow() {
        let snapshot = UsageSnapshot(readings: [
            ok(.claude), ok(.codex),
            ProviderReading(provider: .antigravity, state: .notSetUp("agy not installed"), attemptedAt: now),
        ], readAt: now)
        let headline = snapshot.headline(now: now)
        XCTAssertEqual(headline.health, .ok, "a missing tool must not turn the dot red: \(headline.text)")
        XCTAssertTrue(headline.text.hasPrefix("2 sources"), headline.text)
        XCTAssertEqual(snapshot.readings(in: .subscription).map(\.provider), [.claude, .codex])
        XCTAssertEqual(snapshot.shown.count, 2)
        XCTAssertEqual(snapshot.readings.count, 3, "the doctor still sees it")
    }

    func testASourceThatStopsBeingSetUpDropsItsNumbers() {
        let base = UsageSnapshot(readings: [ok(.deepseek)], readAt: now)
        let gone = base.applying([ProviderReading(provider: .deepseek, state: .notSetUp("No DeepSeek key"), attemptedAt: now)])
        XCTAssertEqual(gone.reading(.deepseek)?.meters, [])
        var store = ReadingStore(readings: [ok(.deepseek)])
        store.record(gone)
        XCTAssertTrue(store.readings.isEmpty, "a removed key is not archived as last good")
    }

    func testNotSetUpRoundTripsThroughCodable() throws {
        let reading = ProviderReading(provider: .soniox, state: .notSetUp("No Soniox key"), attemptedAt: now)
        let data = try JSONEncoder().encode(reading)
        XCTAssertEqual(try JSONDecoder().decode(ProviderReading.self, from: data).state, .notSetUp("No Soniox key"))
    }

    // MARK: - Expired Claude token

    /// A fake `security`: prints item metadata without `-w`, and the blob
    /// with `-w`. The blob carries a made-up token, never a real one.
    private func fakeSecurity(blob: String) throws -> ToolPaths {
        let dir = NSTemporaryDirectory() + "usage-fake-security-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let blobPath = dir + "/blob.json"
        try blob.write(toFile: blobPath, atomically: true, encoding: .utf8)
        let script = dir + "/security"
        try """
        #!/bin/sh
        for a in "$@"; do [ "$a" = "-w" ] && exec cat "\(blobPath)"; done
        echo 'keychain: "login.keychain-db"'
        echo '    "mdat"<timedate>="20260925000000Z"'
        """.write(toFile: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script)
        return ToolPaths(security: script, agy: dir + "/agy", home: dir)
    }

    func testAnExpiredTokenIsExpiredNotSignedOut() throws {
        ClaudeCredential.resetCache()
        defer { ClaudeCredential.resetCache() }
        let expiresAt = Int((now.timeIntervalSince1970 - 60) * 1000)
        let tools = try fakeSecurity(blob: #"{"claudeAiOauth":{"accessToken":"fake","expiresAt":\#(expiresAt),"subscriptionType":"max"}}"#)
        XCTAssertEqual(ClaudeCredential.lookup(tools: tools, user: "someone", now: now), .expired)
        XCTAssertNil(ClaudeCredential.read(tools: tools, user: "someone"))
    }

    func testAValidTokenIsValid() throws {
        ClaudeCredential.resetCache()
        defer { ClaudeCredential.resetCache() }
        let expiresAt = Int((now.timeIntervalSince1970 + 3_600) * 1000)
        let tools = try fakeSecurity(blob: #"{"claudeAiOauth":{"accessToken":"fake","expiresAt":\#(expiresAt)}}"#)
        guard case let .valid(credential) = ClaudeCredential.lookup(tools: tools, user: "someone", now: now) else {
            return XCTFail("a token an hour from expiry is valid")
        }
        XCTAssertEqual(credential.token, "fake")
    }

    func testNoKeychainItemIsMissing() {
        ClaudeCredential.resetCache()
        defer { ClaudeCredential.resetCache() }
        let tools = ToolPaths(security: "/usr/bin/false", agy: "/nonexistent", home: NSTemporaryDirectory())
        XCTAssertEqual(ClaudeCredential.lookup(tools: tools, user: "someone", now: now), .missing)
    }

    func testAnExpiredClaudeTokenKeepsTheLastNumbersStale() throws {
        ClaudeCredential.resetCache()
        defer { ClaudeCredential.resetCache() }
        // Expired relative to the read's own clock, so no request is sent.
        let expiresAt = Int((now.timeIntervalSince1970 - 60) * 1000)
        let tools = try fakeSecurity(blob: #"{"claudeAiOauth":{"accessToken":"fake","expiresAt":\#(expiresAt)}}"#)
        let attempt = ProviderReader.claude(tools: tools, now: now.addingTimeInterval(600))
        XCTAssertEqual(attempt.state, .error(ProviderReader.expiredReason))

        let base = UsageSnapshot(readings: [ok(.claude)], readAt: now)
        let merged = base.applying([attempt])
        let claude = try XCTUnwrap(merged.reading(.claude))
        XCTAssertEqual(claude.meters.first?.percentUsed, 42, "an expired token must not blank the last numbers")
        XCTAssertEqual(claude.readAt, now, "the numbers keep their real age")
        XCTAssertEqual(claude.staleNote(now: now.addingTimeInterval(600)), "stale 10 min ago")

        var store = ReadingStore()
        store.record(merged)
        XCTAssertEqual(store.readings.first?.provider, .claude, "the last good Claude numbers survive a relaunch")
    }

    // MARK: - Tool lookup

    func testAgyIsLookedForWhereBabyMenuLooks() {
        let home = NSTemporaryDirectory() + "usage-agy-\(UUID().uuidString)"
        XCTAssertEqual(ToolPaths.findAgy(home: home).hasSuffix("/.local/bin/agy"), true,
                       "with nothing installed the default user location is named")
    }

    // MARK: - One more ask after a connection failure

    /// Port 9 on loopback refuses the connection at once: a network failure
    /// with no answer, which is asked a second time after the pause.
    func testAConnectionFailureIsAskedTwice() {
        let start = Date()
        let result = HTTP.get(URL(string: "http://127.0.0.1:9/")!, headers: [:], timeout: 3, retryPause: 0.4)
        guard case .failure(.network) = result else { return XCTFail("a refused connection is a network failure: \(result)") }
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(start), 0.4, "the second ask waits for the pause")
    }

    // MARK: - Event log

    func testTheEventLogKeepsTheNewestLines() throws {
        let path = NSTemporaryDirectory() + "usage-events-\(UUID().uuidString)/events.log"
        for index in 0..<(EventLog.keptLines + 5) {
            EventLog.append("launch pid=\(index)", at: now, to: path)
        }
        let lines = try String(contentsOfFile: path, encoding: .utf8).split(separator: "\n")
        XCTAssertEqual(lines.count, EventLog.keptLines)
        XCTAssertTrue(lines.last?.hasSuffix("launch pid=\(EventLog.keptLines + 4)") ?? false)
        XCTAssertTrue(lines.first?.hasSuffix("launch pid=5") ?? false)
        XCTAssertEqual(EventLog.line("terminate", at: now), "2026-08-29T10:40:00Z terminate")
    }
}
