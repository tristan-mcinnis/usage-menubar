import Foundation

/// How long to hold off a source that answered 429, before asking again.
/// Pure and deterministic, so a test can pin the sequence: the wait is at
/// least the exponential backoff, and a Retry-After the source sent only
/// raises that floor (it never shortens it). The exponential doubles from a
/// minute and caps at 15 minutes.
public enum Backoff {

    public static let minDelay: TimeInterval = 60
    /// The exponential cap: 15 minutes.
    public static let maxExponential: TimeInterval = 15 * 60
    public static let base: TimeInterval = 60

    /// A Retry-After header value as seconds to wait. It is either a plain
    /// non-negative number, or an HTTP-date (RFC 7231 IMF-fixdate) from which
    /// the seconds until `now` are computed. Anything else is nil. `now` is
    /// pinned so a date-valued header can be tested deterministically.
    public static func retryAfterSeconds(from header: String?, now: Date = Date()) -> TimeInterval? {
        guard let header else { return nil }
        let trimmed = header.trimmingCharacters(in: .whitespaces)
        if let value = Double(trimmed), value.isFinite, value >= 0 {
            return value
        }
        if let date = httpDate.date(from: trimmed) {
            return max(0, date.timeIntervalSince(now))
        }
        return nil
    }

    /// The seconds to wait before asking again, for the consecutive attempt
    /// count (1-based): the exponential `60 * 2^(attempt-1)` capped at 15
    /// minutes, raised to at least the source's Retry-After seconds (which
    /// can only be larger, never smaller, and never below a minute).
    public static func delay(attempts: Int, retryAfterSeconds: TimeInterval?) -> TimeInterval {
        let attempt = Swift.max(1, attempts)
        let retryAfter = max(0, retryAfterSeconds ?? 0)
        let exponential = min(maxExponential, base * pow(2, Double(attempt - 1)))
        return Swift.max(exponential, retryAfter, minDelay)
    }

    private static let httpDate: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter
    }()
}

/// Persisted per-provider retry deadlines, so a rate-limited source is not
/// asked again until its deadline passes. Holds dates and counts only, never a
/// credential. This is the third thing Usage writes to disk.
public struct RetryStore: Equatable, Sendable {

    public struct Entry: Equatable, Sendable, Codable {
        public let nextAllowedAt: Date
        public let attempts: Int

        public init(nextAllowedAt: Date, attempts: Int) {
            self.nextAllowedAt = nextAllowedAt
            self.attempts = attempts
        }
    }

    public private(set) var entries: [ProviderID: Entry]

    public init(entries: [ProviderID: Entry] = [:]) {
        self.entries = entries
    }

    /// The deadline already set that is still in the future, if any.
    public func nextAllowedAt(_ provider: ProviderID, now: Date) -> Date? {
        guard let entry = entries[provider], entry.nextAllowedAt > now else { return nil }
        return entry.nextAllowedAt
    }

    /// Whether a fresh read of this provider is allowed right now.
    public func shouldAttempt(_ provider: ProviderID, now: Date) -> Bool {
        nextAllowedAt(provider, now: now) == nil
    }

    /// Record a rate limit and return the new deadline: now plus the backoff
    /// for the (incremented) consecutive attempt count, or the source's own
    /// Retry-After seconds when it sent some.
    @discardableResult
    public mutating func backoff(_ provider: ProviderID, retryAfterSeconds: TimeInterval?, now: Date) -> Date {
        let attempts = (entries[provider]?.attempts ?? 0) + 1
        let deadline = now.addingTimeInterval(Backoff.delay(attempts: attempts, retryAfterSeconds: retryAfterSeconds))
        entries[provider] = Entry(nextAllowedAt: deadline, attempts: attempts)
        return deadline
    }

    /// A provider read OK again; drop its backoff so a later rate limit starts
    /// at the base delay rather than a compounded one.
    public mutating func clear(_ provider: ProviderID) {
        entries[provider] = nil
    }

    // MARK: - Disk

    public static func defaultPath(home: String = NSHomeDirectory()) -> String {
        home + "/Library/Application Support/Usage/retries.json"
    }

    public static func load(from path: String) -> RetryStore {
        guard let data = FileManager.default.contents(atPath: path),
              let entries = try? decoder.decode([ProviderID: Entry].self, from: data) else {
            return RetryStore()
        }
        return RetryStore(entries: entries)
    }

    public func save(to path: String) throws {
        let url = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Self.encoder.encode(entries).write(to: url, options: .atomic)
    }

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()
}
