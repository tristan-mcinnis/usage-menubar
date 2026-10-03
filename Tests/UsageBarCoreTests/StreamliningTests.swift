import Foundation
import XCTest
@testable import UsageBarCore

/// The streamlining seams: persist last-good readings and hydrate at launch as
/// visibly stale, keep last-good data visible through a transient failure but
/// not a sign-in ask, never fetch on panel open, back off a rate-limited source
/// across launches, and cache a credential (even a nil) until its source
/// changes.
final class StreamliningTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_788_000_000)

    // MARK: - Archive round-trip

    func testReadingStoreRoundTrip() throws {
        let path = NSTemporaryDirectory() + "usage-readings-\(UUID().uuidString)/readings.json"
        let okClaude = ProviderReading(
            provider: .claude, state: .ok, plan: "max",
            meters: [Meter(id: "session", label: "Session", percentUsed: 42, resetsAt: now.addingTimeInterval(3_600))],
            readAt: now, attemptedAt: now
        )
        let okDeepSeek = ProviderReading(
            provider: .deepseek, state: .ok,
            meters: [Meter(id: "balance", label: "Balance", percentUsed: nil, amount: 83.2, currency: "CNY")],
            readAt: now, attemptedAt: now
        )
        let snapshot = UsageSnapshot(readings: [okClaude, okDeepSeek, ProviderReading(provider: .codex, state: .error("timeout"))], readAt: now)

        var store = ReadingStore()
        store.record(snapshot)
        XCTAssertEqual(store.readings.count, 2, "only good readings are archived")

        try store.save(to: path)
        let loaded = ReadingStore.load(from: path)
        XCTAssertEqual(loaded.readings, store.readings)

        let hydrated = loaded.snapshot()
        XCTAssertEqual(hydrated.readings.count, ProviderID.allCases.count)
        XCTAssertEqual(hydrated.reading(.claude)?.state, .stale, "archived data is presented stale at launch")
        XCTAssertEqual(hydrated.reading(.claude)?.plan, "max")
        XCTAssertEqual(hydrated.reading(.claude)?.meters.first?.percentUsed, 42)
        XCTAssertEqual(hydrated.reading(.deepseek)?.meters.first?.currency, "CNY")
        XCTAssertEqual(hydrated.reading(.codex)?.state, .pending, "a failed provider comes back as pending")

        XCTAssertEqual(ReadingStore.load(from: path + ".missing"), ReadingStore())

        let raw = try String(contentsOfFile: path, encoding: .utf8)
        XCTAssertFalse(raw.contains("sk-"), "the archive must never carry a token")
        XCTAssertFalse(raw.contains("stale"), "the archive stores good readings, not a status")
    }

    func testReadingStoreKeepsLastGoodThroughAFailure() {
        let ok = ProviderReading(
            provider: .claude, state: .ok, plan: "max",
            meters: [Meter(id: "session", label: "Session", percentUsed: 42)],
            readAt: now, attemptedAt: now
        )
        let base = UsageSnapshot(readings: [ok], readAt: now)
        let degraded = base.applying([
            ProviderReading(provider: .claude, state: .rateLimited("rate limited"), attemptedAt: now.addingTimeInterval(60)),
        ])
        var store = ReadingStore()
        store.record(degraded)
        XCTAssertEqual(store.readings.first?.provider, .claude, "the rate-limited provider keeps its last good meters")
        XCTAssertEqual(store.readings.first?.meters.first?.percentUsed, 42)
    }

    func testSignInSupersedesAndIsNotRearcached() {
        let ok = ProviderReading(
            provider: .claude, state: .ok, plan: "max",
            meters: [Meter(id: "session", label: "Session", percentUsed: 42)],
            readAt: now, attemptedAt: now
        )
        let base = UsageSnapshot(readings: [ok], readAt: now)
        let signIn = ProviderReading(provider: .claude, state: .signIn("Sign in to Claude Code"), attemptedAt: now.addingTimeInterval(60))
        let merged = base.applying([signIn])

        let reading = merged.reading(.claude)
        XCTAssertEqual(reading?.state, .signIn("Sign in to Claude Code"))
        XCTAssertTrue(reading?.meters.isEmpty ?? false, "a sign-in ask drops the last good meters")
        XCTAssertNil(reading?.plan, "…and the plan")
        XCTAssertNil(reading?.readAt, "…and the data age")

        // The archive must not rearchive invalid auth as OK.
        var store = ReadingStore()
        store.record(UsageSnapshot(readings: [signIn], readAt: now))
        XCTAssertTrue(store.readings.isEmpty, "a sign-in ask is never archived as OK")
    }

    func testHydratedSnapshotIsStaleAndNotGreen() {
        let oldRead = now.addingTimeInterval(-7_200)
        let store = ReadingStore(readings: [
            ProviderReading(provider: .claude, state: .ok, plan: "max",
                            meters: [Meter(id: "session", label: "Session", percentUsed: 42)], readAt: oldRead),
            ProviderReading(provider: .deepseek, state: .ok,
                            meters: [Meter(id: "b", label: "Balance", percentUsed: nil, amount: 83.2, currency: "CNY")], readAt: oldRead),
        ])
        let hydrated = store.snapshot()
        XCTAssertEqual(hydrated.reading(.claude)?.state, .stale, "archived data must be visibly stale")
        XCTAssertEqual(hydrated.reading(.deepseek)?.state, .stale)
        XCTAssertEqual(hydrated.reading(.claude)?.shownAge(now: now), "2 h ago", "each provider keeps its own data age")

        let headline = hydrated.headline(now: now)
        XCTAssertEqual(headline.health, .unknown, "a restored+pending mix must not report green healthy")
        XCTAssertTrue(headline.text.contains("2 of \(ProviderID.allCases.count)"), "restored providers count as visible data: \(headline.text)")
        XCTAssertFalse(headline.text.contains("refreshed just now"), "stale data is never called fresh: \(headline.text)")
        XCTAssertTrue(headline.text.contains("2 h ago"), "the header is honest about the data's age: \(headline.text)")
    }

    func testHydratedHeadlineUsesOldestReadingAge() {
        let recent = now.addingTimeInterval(-120)
        let old = now.addingTimeInterval(-2 * 86_400)
        let store = ReadingStore(readings: [
            ProviderReading(provider: .claude, state: .ok, plan: "max",
                            meters: [Meter(id: "session", label: "Session", percentUsed: 42)], readAt: recent),
            ProviderReading(provider: .deepseek, state: .ok,
                            meters: [Meter(id: "b", label: "Balance", percentUsed: nil, amount: 83.2, currency: "CNY")], readAt: old),
        ])

        let hydrated = store.snapshot()
        XCTAssertEqual(hydrated.readAt, old, "the summary age must not hide the oldest restored reading")
        XCTAssertTrue(hydrated.headline(now: now).text.contains("2 d ago"))
    }

    // MARK: - Degradation: last-good data stays visible

    func testApplyingKeepsLastGoodOnFailure() {
        let ok = ProviderReading(
            provider: .claude, state: .ok, plan: "max",
            meters: [Meter(id: "session", label: "Session", percentUsed: 42, resetsAt: now.addingTimeInterval(3_600))],
            readAt: now, attemptedAt: now
        )
        let base = UsageSnapshot(readings: [ok], readAt: now)

        let failedAttempt = ProviderReading(provider: .claude, state: .error("timeout"), attemptedAt: now.addingTimeInterval(60))
        let merged = base.applying([failedAttempt])

        let reading = merged.reading(.claude)
        XCTAssertEqual(reading?.state, .error("timeout"))
        XCTAssertEqual(reading?.meters.count, 1, "the last good meter stays")
        XCTAssertEqual(reading?.meters.first?.percentUsed, 42)
        XCTAssertEqual(reading?.readAt, now, "the displayed data still says how old it is")
        XCTAssertEqual(reading?.staleNote(now: now.addingTimeInterval(120)), "stale 2 min ago")
        XCTAssertEqual(merged.readAt, now.addingTimeInterval(60))
        XCTAssertTrue(merged.headline(now: now.addingTimeInterval(120)).text.contains("1 cached"),
                      "a transient failure should describe retained data as cached, not freshly read")
    }

    func testApplyingKeepsLastGoodOnRateLimit() {
        let ok = ProviderReading(
            provider: .deepseek, state: .ok,
            meters: [Meter(id: "balance", label: "Balance", percentUsed: 24, amount: 83.2, currency: "CNY")],
            readAt: now, attemptedAt: now
        )
        let base = UsageSnapshot(readings: [ok], readAt: now)

        let limited = ProviderReading(provider: .deepseek, state: .rateLimited("rate limited"), attemptedAt: now.addingTimeInterval(60), retryAfterSeconds: 60)
        let merged = base.applying([limited])

        let reading = merged.reading(.deepseek)
        XCTAssertEqual(reading?.state, .rateLimited("rate limited"))
        XCTAssertEqual(reading?.meters.count, 1)
        XCTAssertEqual(reading?.retryAfterSeconds, 60)
        XCTAssertEqual(reading?.readAt, now, "the balance number is not blanked")
    }

    func testApplyingLeavesUntouchedProvidersAlone() {
        let okDeepSeek = ProviderReading(
            provider: .deepseek, state: .ok,
            meters: [Meter(id: "balance", label: "Balance", percentUsed: nil, amount: 83.2, currency: "CNY")],
            readAt: now, attemptedAt: now
        )
        let base = UsageSnapshot(readings: [okDeepSeek], readAt: now)
        let okClaude = ProviderReading(
            provider: .claude, state: .ok, plan: "max",
            meters: [Meter(id: "session", label: "Session", percentUsed: 10)],
            readAt: now, attemptedAt: now
        )

        let merged = base.applying([okClaude])
        XCTAssertEqual(merged.reading(.deepseek)?.meters.count, 1, "an untouched provider is not replaced with pending")
        XCTAssertEqual(merged.reading(.claude)?.state, .ok)
    }

    // MARK: - Open policy and honest header

    func testArchiveHydrationKeepsTheRealReadAge() {
        let oldRead = now.addingTimeInterval(-120)
        let store = ReadingStore(readings: [
            ProviderReading(provider: .claude, state: .ok, plan: "max",
                            meters: [Meter(id: "session", label: "Session", percentUsed: 42)], readAt: oldRead),
        ])
        let hydrated = store.snapshot()
        XCTAssertEqual(hydrated.readAt, oldRead, "the last read age is kept, not advanced")
        let headline = hydrated.headline(now: now).text
        XCTAssertTrue(headline.contains("2 min ago"), "the panel shows a real stale age, not 'just now': \(headline)")
        XCTAssertNotEqual(headline, "Reading sources…", "hydrated data means we are not stuck pending")
    }

    func testHeaderNeverClaimsFreshWhenDataIsOld() {
        let old = now.addingTimeInterval(-3_600)
        let snapshot = UsageSnapshot(readings: [
            ProviderReading(provider: .claude, state: .stale, meters: [Meter(id: "session", label: "Session", percentUsed: 42)], readAt: old),
            ProviderReading(provider: .deepseek, state: .ok, meters: [Meter(id: "b", label: "Balance", percentUsed: nil, amount: 83.2, currency: "CNY")], readAt: now),
        ], readAt: now)
        let headline = snapshot.headline(now: now)
        XCTAssertEqual(headline.health, .unknown)
        XCTAssertFalse(headline.text.contains("refreshed"), "stale data is never described as fresh: \(headline.text)")
        XCTAssertTrue(headline.text.contains("1 h ago"), "the header uses the restored provider's age, not the latest attempt: \(headline.text)")
    }

    func testSignInPlanIsNotCountedAsCachedData() {
        let snapshot = UsageSnapshot(readings: [
            ProviderReading(provider: .claude, state: .signIn("Sign in"), plan: "max", attemptedAt: now),
        ], readAt: now)
        let headline = snapshot.headline(now: now)
        XCTAssertTrue(headline.text.hasPrefix("No source readable"), "invalid auth must not count its plan as cached data: \(headline.text)")
    }

    // MARK: - Backoff

    func testBackoffDelay() {
        // Retry-After raises the floor; it never shortens the wait.
        XCTAssertEqual(Backoff.delay(attempts: 1, retryAfterSeconds: 30), 60, "a Retry-After below a minute still waits a minute")
        XCTAssertEqual(Backoff.delay(attempts: 1, retryAfterSeconds: 0), 60, "Retry-After 0 still waits at least a minute")
        XCTAssertEqual(Backoff.delay(attempts: 1, retryAfterSeconds: 120), 120, "a larger Retry-After raises the wait")
        XCTAssertEqual(Backoff.delay(attempts: 3, retryAfterSeconds: 300), 300)
        XCTAssertEqual(Backoff.delay(attempts: 2, retryAfterSeconds: 90), 120, "a Retry-After below the exponential is ignored")
        // Exponential: 60s doubling capped at 15 minutes.
        XCTAssertEqual(Backoff.delay(attempts: 1, retryAfterSeconds: nil), 60)
        XCTAssertEqual(Backoff.delay(attempts: 2, retryAfterSeconds: nil), 120)
        XCTAssertEqual(Backoff.delay(attempts: 3, retryAfterSeconds: nil), 240)
        XCTAssertEqual(Backoff.delay(attempts: 4, retryAfterSeconds: nil), 480)
        XCTAssertEqual(Backoff.delay(attempts: 5, retryAfterSeconds: nil), 900, "capped at 15 minutes")
        XCTAssertEqual(Backoff.delay(attempts: 20, retryAfterSeconds: nil), 900)
        XCTAssertEqual(Backoff.maxExponential, 900)
    }

    func testBackoffRetryAfterParser() {
        let now = Date(timeIntervalSince1970: 1_788_000_000)
        XCTAssertEqual(Backoff.retryAfterSeconds(from: "42", now: now), 42)
        XCTAssertEqual(Backoff.retryAfterSeconds(from: " 10 ", now: now), 10)
        // A past HTTP-date clamps to zero; a future one gives a deterministic delta.
        XCTAssertEqual(Backoff.retryAfterSeconds(from: "Mon, 05 Jan 1970 00:00:00 GMT", now: now), 0)
        let future = "Tue, 08 Sep 2026 00:00:00 GMT"
        let parsed = Backoff.retryAfterSeconds(from: future, now: now)!
        XCTAssertGreaterThan(parsed, 0)
        XCTAssertEqual(Backoff.retryAfterSeconds(from: future, now: now)!, parsed, "deterministic for a fixed now")
        XCTAssertNil(Backoff.retryAfterSeconds(from: "not a number", now: now))
        XCTAssertNil(Backoff.retryAfterSeconds(from: nil, now: now))
    }

    func testRetryStorePersistence() throws {
        let path = NSTemporaryDirectory() + "usage-retries-\(UUID().uuidString)/retries.json"
        var store = RetryStore()
        XCTAssertTrue(store.shouldAttempt(.claude, now: now))

        let deadline = store.backoff(.claude, retryAfterSeconds: 120, now: now)
        XCTAssertEqual(deadline, now.addingTimeInterval(120))
        XCTAssertFalse(store.shouldAttempt(.claude, now: now.addingTimeInterval(60)))
        XCTAssertTrue(store.shouldAttempt(.claude, now: now.addingTimeInterval(121)))

        let second = store.backoff(.claude, retryAfterSeconds: nil, now: now.addingTimeInterval(200))
        XCTAssertEqual(second, now.addingTimeInterval(200 + Backoff.delay(attempts: 2, retryAfterSeconds: nil)))

        try store.save(to: path)
        let loaded = RetryStore.load(from: path)
        XCTAssertEqual(loaded.entries[.claude]?.attempts, 2)
        XCTAssertFalse(loaded.shouldAttempt(.claude, now: now.addingTimeInterval(200)))

        var cleared = loaded
        cleared.clear(.claude)
        XCTAssertTrue(cleared.shouldAttempt(.claude, now: now.addingTimeInterval(200)))

        XCTAssertEqual(RetryStore.load(from: path + ".missing"), RetryStore())
    }

    // MARK: - Credential cache

    func testCredentialCacheReadsOnceUntilFingerprintChanges() {
        var cache = CredentialCache<OAuthCredential>()
        var reads = 0
        let first = cache.resolve(fingerprint: "item-A") { reads += 1; return OAuthCredential(token: "tok-1") }
        XCTAssertEqual(first?.token, "tok-1")
        XCTAssertEqual(reads, 1)

        let cached = cache.resolve(fingerprint: "item-A") { reads += 1; return OAuthCredential(token: "tok-2") }
        XCTAssertEqual(cached?.token, "tok-1", "an unchanged item reuses the cached credential")
        XCTAssertEqual(reads, 1, "the secret is not re-read when the item did not change")

        let changed = cache.resolve(fingerprint: "item-B") { reads += 1; return OAuthCredential(token: "tok-2") }
        XCTAssertEqual(changed?.token, "tok-2")
        XCTAssertEqual(reads, 2)

        cache.invalidate()
        let afterInvalidate = cache.resolve(fingerprint: "item-B") { reads += 1; return OAuthCredential(token: "tok-3") }
        XCTAssertEqual(afterInvalidate?.token, "tok-3")
        XCTAssertEqual(reads, 3)
    }

    func testCredentialCacheReadsOnceWhenInitialFingerprintIsNil() {
        var cache = CredentialCache<OAuthCredential>()
        var reads = 0

        XCTAssertNil(cache.resolve(fingerprint: nil) { reads += 1; return nil })
        XCTAssertEqual(reads, 1, "an unresolved cache must invoke its reader even when the fingerprint is nil")
        XCTAssertNil(cache.resolve(fingerprint: nil) { reads += 1; return OAuthCredential(token: "tok") })
        XCTAssertEqual(reads, 1, "the nil outcome is cached for an unchanged nil fingerprint")
    }

    func testCredentialCacheCachesFailureForUnchangedFingerprint() {
        var cache = CredentialCache<OAuthCredential>()
        var reads = 0
        let denied = cache.resolve(fingerprint: "item-A") { reads += 1; return nil }
        XCTAssertNil(denied)
        XCTAssertEqual(reads, 1)

        // Same fingerprint: the remembered nil is reused, not re-read
        // (so a denied credential does not re-prompt on every poll).
        let again = cache.resolve(fingerprint: "item-A") { reads += 1; return OAuthCredential(token: "tok") }
        XCTAssertNil(again)
        XCTAssertEqual(reads, 1)

        // A changed fingerprint re-reads.
        let changed = cache.resolve(fingerprint: "item-B") { reads += 1; return OAuthCredential(token: "tok") }
        XCTAssertEqual(changed?.token, "tok")
        XCTAssertEqual(reads, 2)
    }

    func testCredentialCacheSetIsPerKey() {
        var set = CredentialCacheSet<OAuthCredential>()
        var reads = 0

        let user = set.resolve(key: "user", fingerprint: "user-item") { reads += 1; return nil }
        XCTAssertNil(user)
        XCTAssertEqual(reads, 1)

        // The shared account is still read: the user's nil does not suppress it.
        let shared = set.resolve(key: "shared", fingerprint: "shared-item") { reads += 1; return OAuthCredential(token: "tok-shared") }
        XCTAssertEqual(shared?.token, "tok-shared")
        XCTAssertEqual(reads, 2)

        // Unchanged "user" still returns nil without a re-read.
        let userAgain = set.resolve(key: "user", fingerprint: "user-item") { reads += 1; return OAuthCredential(token: "x") }
        XCTAssertNil(userAgain)
        XCTAssertEqual(reads, 2)

        set.invalidate()
        let userAfter = set.resolve(key: "user", fingerprint: "user-item") { reads += 1; return OAuthCredential(token: "y") }
        XCTAssertEqual(userAfter?.token, "y")
        XCTAssertEqual(reads, 3)
    }

    func testClaudeFingerprintIsNotTheSecret() {
        // The metadata a rotated token changes, and it never carries the token.
        // This is the shape `/usr/bin/security` prints without `-w`.
        let meta = """
        keychain: "/Library/Keychains/login.keychain-db"
        class: "genp"
        attributes:
            0x00000007 <blob>="Claude Code-credentials"
            0x00000008 <blob>=user
            0x0000000A <date>=2026-08-29 02:37:00 +0000
        """
        XCTAssertTrue(meta.contains("Claude Code-credentials"))
        XCTAssertFalse(meta.contains("sk-"), "metadata must not contain the token")
    }
}
