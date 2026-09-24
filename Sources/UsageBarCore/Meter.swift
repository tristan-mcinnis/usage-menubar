import Foundation

/// What a source is billed as. The panel groups its rows by this.
public enum Lane: String, Codable, Sendable, CaseIterable {
    /// A flat monthly plan with rate windows: a session cap and a weekly cap.
    case subscription
    /// A prepaid balance that calls draw down.
    case apiKey

    public var title: String {
        switch self {
        case .subscription: return "Subscriptions"
        case .apiKey: return "API keys"
        }
    }
}

/// Every source Usage knows how to read. The order here is the order in the
/// panel.
public enum ProviderID: String, Codable, Sendable, CaseIterable, Identifiable {
    case claude
    case codex
    case antigravity
    case deepseek
    case moonshot
    case soniox

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .claude: return "Claude Code"
        case .codex: return "Codex"
        case .antigravity: return "Antigravity"
        case .deepseek: return "DeepSeek"
        case .moonshot: return "Moonshot"
        case .soniox: return "Soniox"
        }
    }

    public var lane: Lane {
        switch self {
        case .claude, .codex, .antigravity: return .subscription
        case .deepseek, .moonshot, .soniox: return .apiKey
        }
    }

    /// The SF symbol on the provider row. One family, so the rows align.
    public var glyph: String {
        switch self {
        case .claude: return "sparkle"
        case .codex: return "chevron.left.forwardslash.chevron.right"
        case .antigravity: return "arrow.up.circle"
        case .deepseek: return "key"
        case .moonshot: return "key"
        case .soniox: return "waveform"
        }
    }

    /// Where Return on the row goes: the provider's own usage or billing page.
    public var usageURL: URL {
        switch self {
        case .claude: return URL(string: "https://claude.ai/settings/usage")!
        case .codex: return URL(string: "https://chatgpt.com/codex/settings/usage")!
        case .antigravity: return URL(string: "https://antigravity.google/")!
        case .deepseek: return URL(string: "https://platform.deepseek.com/usage")!
        case .moonshot: return URL(string: "https://platform.moonshot.cn/console/account")!
        case .soniox: return URL(string: "https://console.soniox.com/")!
        }
    }

    public static var subscriptions: [ProviderID] { allCases.filter { $0.lane == .subscription } }
    public static var apiKeys: [ProviderID] { allCases.filter { $0.lane == .apiKey } }
}

/// One line on the panel: a quota window or a balance, on one axis.
///
/// `percentUsed` is the axis. A quota window reports it directly. A balance
/// reports it as spend since the highest balance seen in the last thirty
/// days, so a top-up resets the bar the way a window reset does. It is nil
/// only when the source gave no number, and then the row says so.
public struct Meter: Equatable, Sendable, Identifiable, Codable {
    public let id: String
    /// "Session", "Weekly", "Weekly · Opus", "Balance".
    public let label: String
    public let percentUsed: Double?
    /// When a quota window comes back. Nil for balances.
    public let resetsAt: Date?
    /// The remaining balance and its currency, for balance meters only.
    public let amount: Double?
    public let currency: String?
    /// A scoped window the account is currently metered against.
    public let active: Bool
    /// The amount is money spent over a window, not a balance left. It has
    /// no bar, because a spend has no cap to be a percent of.
    public let spent: Bool

    public init(
        id: String,
        label: String,
        percentUsed: Double?,
        resetsAt: Date? = nil,
        amount: Double? = nil,
        currency: String? = nil,
        active: Bool = false,
        spent: Bool = false
    ) {
        self.id = id
        self.label = label
        self.percentUsed = percentUsed.map { min(100, max(0, $0)) }
        self.resetsAt = resetsAt
        self.amount = amount
        self.currency = currency
        self.active = active
        self.spent = spent
    }

    public var isBalance: Bool { amount != nil && !spent }

    /// The number on the right of the row: "42%" or "¥83.20".
    public func value() -> String {
        if let amount, let currency {
            return Format.money(amount, currency: currency)
        }
        if let percentUsed {
            return "\(Int(percentUsed.rounded()))%"
        }
        return "—"
    }

    /// The dim text after the number: "resets 2h 10m", "resets Mon", or the
    /// balance's spend since the peak.
    public func detail(now: Date = Date()) -> String? {
        if let resetsAt {
            return "resets " + Format.countdown(to: resetsAt, from: now)
        }
        if spent { return "spent in the last 30 days" }
        if isBalance, let percentUsed, percentUsed > 0 {
            return "\(Int(percentUsed.rounded()))% of 30d peak spent"
        }
        return nil
    }
}

/// What a read of one provider came back as.
public enum ReadState: Equatable, Sendable {
    /// Meters were read just now.
    case ok
    /// Restored from last session's archive: the data is real but old, shown
    /// stale until the next successful read.
    case stale
    /// The credential is missing or was rejected; the text says which.
    case signIn(String)
    /// The source is not set up on this Mac: its tool is not installed or it
    /// has no key. Not a failure, so the panel leaves it off and the header
    /// does not count it; `--doctor` still names it.
    case notSetUp(String)
    /// The source could not be reached or answered with something unreadable.
    case error(String)
    /// The source throttled the ask; the text says why and how to wait.
    case rateLimited(String)
    /// Not read yet.
    case pending

    public var isOK: Bool { self == .ok }

    /// The words for a non-ok state, for a line that must say what happened.
    public var reason: String {
        switch self {
        case .ok, .stale: return ""
        case let .signIn(reason), let .error(reason), let .rateLimited(reason), let .notSetUp(reason): return reason
        case .pending: return "Reading…"
        }
    }

    /// Whether the source is set up on this Mac at all.
    public var isSetUp: Bool {
        if case .notSetUp = self { return false }
        return true
    }

    /// The last good numbers stop being shown: the account is not valid (a
    /// sign-in ask) or the source is gone (not set up). Every other failure
    /// keeps them, marked stale.
    public var dropsData: Bool {
        switch self {
        case .signIn, .notSetUp: return true
        case .ok, .stale, .error, .rateLimited, .pending: return false
        }
    }
}

extension ReadState: Codable {
    private enum CodingKeys: String, CodingKey { case kind, reason }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(String.self, forKey: .kind) {
        case "ok": self = .ok
        case "stale": self = .stale
        case "signIn": self = .signIn(try container.decode(String.self, forKey: .reason))
        case "error": self = .error(try container.decode(String.self, forKey: .reason))
        case "rateLimited": self = .rateLimited(try container.decode(String.self, forKey: .reason))
        case "notSetUp": self = .notSetUp(try container.decode(String.self, forKey: .reason))
        case "pending": self = .pending
        default:
            throw DecodingError.dataCorruptedError(forKey: .kind, in: container, debugDescription: "unknown ReadState")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .ok: try container.encode("ok", forKey: .kind)
        case .stale: try container.encode("stale", forKey: .kind)
        case let .signIn(reason):
            try container.encode("signIn", forKey: .kind)
            try container.encode(reason, forKey: .reason)
        case let .error(reason):
            try container.encode("error", forKey: .kind)
            try container.encode(reason, forKey: .reason)
        case let .rateLimited(reason):
            try container.encode("rateLimited", forKey: .kind)
            try container.encode(reason, forKey: .reason)
        case let .notSetUp(reason):
            try container.encode("notSetUp", forKey: .kind)
            try container.encode(reason, forKey: .reason)
        case .pending: try container.encode("pending", forKey: .kind)
        }
    }
}

/// One provider, as shown: the last good display data and how fresh the
/// latest read attempt is. `meters` and `plan` are the values to keep on the
/// row; a transient `error` or `rateLimited` state keeps the last good values,
/// while `signIn` removes them because the account is no longer valid.
public struct ProviderReading: Equatable, Sendable, Identifiable, Codable {
    public let provider: ProviderID
    public let state: ReadState
    /// The plan or tier the source named, if it did: "max", "plus", "team".
    public let plan: String?
    public let meters: [Meter]
    /// When the displayed meters were last read OK. Nil until there has been a
    /// successful read, so a never-read provider is not shown as stale.
    public let readAt: Date?
    /// When the latest read attempt happened, successful or not. This is what
    /// "refreshed X ago" counts from, so a failure still shows its age.
    public let attemptedAt: Date?
    /// Retry-After seconds the source sent with a 429, so the retry deadline
    /// honors it. Nil for any non-rate-limited read.
    public let retryAfterSeconds: TimeInterval?

    public var id: ProviderID { provider }

    public init(
        provider: ProviderID,
        state: ReadState,
        plan: String? = nil,
        meters: [Meter] = [],
        readAt: Date? = nil,
        attemptedAt: Date? = nil,
        retryAfterSeconds: TimeInterval? = nil
    ) {
        self.provider = provider
        self.state = state
        self.plan = plan
        self.meters = meters
        self.readAt = readAt
        self.attemptedAt = attemptedAt
        self.retryAfterSeconds = retryAfterSeconds
    }

    public static func pending(_ provider: ProviderID) -> ProviderReading {
        ProviderReading(provider: provider, state: .pending)
    }

    /// The last good plan or balance to put on the right of the row, whether or
    /// not the latest read freshened it. Empty when there is nothing to show
    /// (a provider never read OK).
    public var retainedValue: String {
        if provider.lane == .apiKey, let balance = meters.first(where: { $0.isBalance }) {
            return balance.value()
        }
        if provider.lane == .apiKey, let spend = meters.first(where: \.spent) {
            return spend.value() + " spent"
        }
        return plan.map(Format.planTitle) ?? ""
    }

    /// The row's right-hand text: the plan on a subscription, the balance on a
    /// key, or (when there is no number to keep) the reason there is none.
    public var trailing: String {
        switch state {
        case .ok, .stale: return retainedValue
        case let .signIn(reason), let .error(reason), let .rateLimited(reason):
            return retainedValue.isEmpty ? reason : retainedValue
        case let .notSetUp(reason): return reason
        case .pending: return "Reading…"
        }
    }

    /// The age of the data this row shows, for a line that must say how old it
    /// is: "5 min ago". Nil when there is no data to be old.
    public func shownAge(now: Date = Date()) -> String? {
        guard let readAt else { return nil }
        return Format.age(of: readAt, now: now)
    }

    /// How stale the shown data is for a row the latest read could not refresh
    /// (an error, a rate limit, a sign-in ask): "stale 5 min ago". Nil when the
    /// read is fresh or there is no data to be stale.
    public func staleNote(now: Date = Date()) -> String? {
        let isStaleable: Bool
        switch state {
        case .error, .rateLimited, .signIn: isStaleable = true
        default: isStaleable = false
        }
        guard isStaleable, let readAt else { return nil }
        return "stale " + Format.age(of: readAt, now: now)
    }
}

/// Everything the panel shows, in one value.
public struct UsageSnapshot: Equatable, Sendable {
    public let readings: [ProviderReading]
    public let readAt: Date?

    public init(readings: [ProviderReading], readAt: Date?) {
        self.readings = readings
        self.readAt = readAt
    }

    public static let pending = UsageSnapshot(
        readings: ProviderID.allCases.map(ProviderReading.pending),
        readAt: nil
    )

    /// The readings the panel draws: every source that is set up on this
    /// Mac. A source with no tool or no key is not a row and not a failure.
    public var shown: [ProviderReading] {
        readings.filter(\.state.isSetUp)
    }

    /// The panel's rows in one lane, set-up sources only.
    public func readings(in lane: Lane) -> [ProviderReading] {
        shown.filter { $0.provider.lane == lane }
    }

    public func reading(_ provider: ProviderID) -> ProviderReading? {
        readings.first { $0.provider == provider }
    }

    /// The one-line status under the app name, and its dot.
    public var headline: (text: String, health: Health) { headline(now: Date()) }

    public func headline(now: Date) -> (text: String, health: Health) {
        // A source that is not set up here is not a row, so it is not counted.
        let readings = shown
        let okCount = readings.filter(\.state.isOK).count
        // Fresh, restored, and transiently degraded rows may all carry a real
        // value. Count what is visible rather than only `.ok`, so a cold launch
        // never says "0 sources" while restored meters are on screen.
        let visibleCount = readings.filter { reading in
            switch reading.state {
            case .ok, .stale: return true
            case .error, .rateLimited: return !reading.meters.isEmpty || reading.plan != nil
            case .signIn, .pending, .notSetUp: return false
            }
        }.count
        guard let readAt else { return ("Reading sources…", .unknown) }
        let failing = readings.filter {
            if case .signIn = $0.state { return true }
            if case .error = $0.state { return true }
            if case .rateLimited = $0.state { return true }
            return false
        }
        let age = Format.age(of: readAt, now: now)
        if !failing.isEmpty {
            let names = failing.map { $0.provider.title }.joined(separator: ", ")
            if okCount == 0 {
                if visibleCount > 0 { return ("\(visibleCount) cached · \(names) not refreshed", .failing) }
                return ("No source readable · \(age)", .failing)
            }
            return ("\(okCount) of \(readings.count) · \(names) not read", .failing)
        }
        // Every source was read just now: green, and the age is honest.
        if readings.allSatisfy(\.state.isOK) {
            return ("\(okCount) sources · refreshed \(age)", .ok)
        }
        // Some data is restored from last session or still pending: never claim
        // it is fresh. The dot is dim (unknown), not green.
        let pendingCount = readings.filter { $0.state == .pending }.count
        if pendingCount > 0 {
            return ("\(visibleCount) of \(readings.count) sources · \(age)", .unknown)
        }
        let restored = readings.filter { $0.state == .stale }
        if !restored.isEmpty {
            let oldest = restored.compactMap(\.readAt).min() ?? readAt
            let restoredAge = Format.age(of: oldest, now: now)
            return ("\(restored.count) restored · last read \(restoredAge)", .unknown)
        }
        return ("\(visibleCount) of \(readings.count) sources · \(age)", .unknown)
    }

    public enum Health: Equatable, Sendable {
        case ok
        case failing
        case unknown
    }

    /// Whether any subscription window is at its cap.
    public var anyWindowExhausted: Bool {
        readings.contains { reading in
            reading.provider.lane == .subscription
                && reading.meters.contains { ($0.percentUsed ?? 0) >= 100 }
        }
    }
}

extension UsageSnapshot {
    /// Combine a batch of fresh attempt results with what is already shown.
    ///
    /// A transient failure (an error or a rate limit) keeps the last good meters
    /// and plan, so a failure never blanks a number. A sign-in ask supersedes
    /// them: the credential is not valid, so the last good values stop being
    /// shown. A provider with no fresh attempt in the batch is left exactly as
    /// it is, so a background refresh never replaces a not-yet-read row with
    /// "pending".
    public func applying(_ attempts: [ProviderReading]) -> UsageSnapshot {
        var byProvider: [ProviderID: ProviderReading] = [:]
        for reading in readings { byProvider[reading.provider] = reading }
        for attempt in attempts {
            byProvider[attempt.provider] = Self.merge(attempt, over: byProvider[attempt.provider])
        }
        let merged = ProviderID.allCases.compactMap { byProvider[$0] }
        let attempted = attempts.compactMap(\.attemptedAt).max()
        return UsageSnapshot(readings: merged, readAt: attempted ?? readAt)
    }

    /// Carry the last good display data over an attempt that could not refresh.
    /// A transient failure keeps it; a sign-in ask or a source that is no
    /// longer set up drops it.
    private static func merge(_ attempt: ProviderReading, over previous: ProviderReading?) -> ProviderReading {
        if attempt.state.isOK { return attempt }
        if attempt.state.dropsData {
            return ProviderReading(
                provider: attempt.provider,
                state: attempt.state,
                plan: nil,
                meters: [],
                readAt: nil,
                attemptedAt: attempt.attemptedAt
            )
        }
        return ProviderReading(
            provider: attempt.provider,
            state: attempt.state,
            plan: attempt.plan ?? previous?.plan,
            meters: previous?.meters ?? [],
            readAt: previous?.readAt,
            attemptedAt: attempt.attemptedAt,
            retryAfterSeconds: attempt.retryAfterSeconds
        )
    }
}

/// The words Usage prints for numbers and times. One place, so the panel,
/// the status item, and `--doctor` agree.
public enum Format {

    public static func money(_ amount: Double, currency: String) -> String {
        let symbol: String
        switch currency.uppercased() {
        case "CNY", "RMB": symbol = "¥"
        case "USD": symbol = "$"
        case "EUR": symbol = "€"
        case "GBP": symbol = "£"
        default: symbol = currency.uppercased() + " "
        }
        return symbol + String(format: "%.2f", amount)
    }

    /// "2h 10m", "4d 3h", "12m", "now".
    public static func countdown(to date: Date, from now: Date) -> String {
        let seconds = Int(date.timeIntervalSince(now).rounded())
        if seconds <= 0 { return "now" }
        let days = seconds / 86_400
        let hours = (seconds % 86_400) / 3_600
        let minutes = (seconds % 3_600) / 60
        if days > 0 { return hours > 0 ? "\(days)d \(hours)h" : "\(days)d" }
        if hours > 0 { return minutes > 0 ? "\(hours)h \(minutes)m" : "\(hours)h" }
        return "\(max(1, minutes))m"
    }

    /// "just now", "2 min ago", "3 h ago".
    public static func age(of date: Date, now: Date = Date()) -> String {
        let seconds = Int(now.timeIntervalSince(date))
        if seconds < 45 { return "just now" }
        if seconds < 3_600 { return "\(max(1, seconds / 60)) min ago" }
        if seconds < 86_400 { return "\(seconds / 3_600) h ago" }
        return "\(seconds / 86_400) d ago"
    }

    /// "max" → "Max", "team_plus" → "Team plus".
    public static func planTitle(_ plan: String) -> String {
        let words = plan.replacingOccurrences(of: "_", with: " ").replacingOccurrences(of: "-", with: " ")
        return words.prefix(1).uppercased() + words.dropFirst()
    }
}
