import Foundation

/// An in-memory cache for one credential, so a poll does not re-read a secret
/// (a keychain item, a token) every time when the source has not changed.
///
/// The caller supplies a `fingerprint`: a short, non-secret mark of the
/// source's current state (an item's modify date, an id, a hash of metadata),
/// never the secret itself. When the fingerprint is unchanged the cached
/// outcome is returned - including a nil or denied one - so a denied credential
/// is not re-read (and re-prompted) on every poll; it is re-read only when the
/// fingerprint changes. Nothing here is written to disk, so a secret is held in
/// memory only and never persisted.
public struct CredentialCache<Value: Equatable> {
    private var value: Value?
    private var fingerprint: String?
    /// Distinguishes a cached nil outcome from a cache that has never resolved.
    private var hasResolved = false

    public init() {}

    /// Resolve the current credential.
    ///
    /// `fingerprint` is the non-secret mark of the current source. `read`
    /// returns the fresh value (or nil) to cache when the mark changed or
    /// nothing is cached yet. An unchanged mark returns the cached outcome
    /// (even nil), so a failure is remembered rather than re-asked.
    public mutating func resolve(
        fingerprint: String?,
        isValid: (Value) -> Bool = { _ in true },
        read: () -> Value?
    ) -> Value? {
        if hasResolved, fingerprint == self.fingerprint {
            // The source did not change; reuse the cached outcome. A nil here
            // is a remembered failure, not a reason to re-read. An invalid
            // value stays unavailable until its source changes or explicit
            // user intent invalidates the cache; re-reading an unchanged
            // keychain item cannot produce a fresher token.
            if let value, isValid(value) { return value }
            return nil
        }
        let fresh = read()
        self.fingerprint = fingerprint
        self.value = fresh
        self.hasResolved = true
        return fresh
    }

    /// Forget the cached value and fingerprint, so the next `resolve` re-reads
    /// the source. Used when the source reports its credential was rejected.
    public mutating func invalidate() {
        value = nil
        fingerprint = nil
        hasResolved = false
    }

    // MARK: - Read-only inputs for tests

    var _fingerprint: String? { fingerprint }
    var _value: Value? { value }
}

/// A group of per-key credential caches, so fallback across accounts (the
/// Claude keychain's per-user item then the shared one) is cached independently
/// and a failure on one account does not suppress a read of another.
public struct CredentialCacheSet<Value: Equatable> {
    private var byKey: [String: CredentialCache<Value>] = [:]

    public init() {}

    public mutating func resolve(
        key: String,
        fingerprint: String?,
        isValid: (Value) -> Bool = { _ in true },
        read: () -> Value?
    ) -> Value? {
        var cache = byKey[key] ?? CredentialCache()
        defer { byKey[key] = cache }
        return cache.resolve(fingerprint: fingerprint, isValid: isValid, read: read)
    }

    /// Forget every cached value, across all keys.
    public mutating func invalidate() {
        byKey.removeAll()
    }
}
