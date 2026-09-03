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
    /// Meters were read.
    case ok
    /// The credential is missing or was rejected; the text says which.
    case signIn(String)
    /// The source could not be reached or answered with something unreadable.
    case error(String)
    /// Not read yet.
    case pending

    public var isOK: Bool { self == .ok }
}

/// One provider, as read: its meters and how the read went.
public struct ProviderReading: Equatable, Sendable, Identifiable {
    public let provider: ProviderID
    public let state: ReadState
    /// The plan or tier the source named, if it did: "max", "plus", "team".
    public let plan: String?
    public let meters: [Meter]
    public let readAt: Date?

    public var id: ProviderID { provider }

    public init(
        provider: ProviderID,
        state: ReadState,
        plan: String? = nil,
        meters: [Meter] = [],
        readAt: Date? = nil
    ) {
        self.provider = provider
        self.state = state
        self.plan = plan
        self.meters = meters
        self.readAt = readAt
    }

    public static func pending(_ provider: ProviderID) -> ProviderReading {
        ProviderReading(provider: provider, state: .pending)
    }

    /// The row's right-hand text: the plan on a subscription, the balance on
    /// a key, or the reason there is nothing.
    public var trailing: String {
        switch state {
        case .ok:
            if provider.lane == .apiKey, let balance = meters.first(where: { $0.isBalance }) {
                return balance.value()
            }
            if provider.lane == .apiKey, let spend = meters.first(where: \.spent) {
                return spend.value() + " spent"
            }
            return plan.map(Format.planTitle) ?? ""
        case let .signIn(reason): return reason
        case let .error(reason): return reason
        case .pending: return "Reading…"
        }
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

    public func readings(in lane: Lane) -> [ProviderReading] {
        readings.filter { $0.provider.lane == lane }
    }

    public func reading(_ provider: ProviderID) -> ProviderReading? {
        readings.first { $0.provider == provider }
    }

    /// The one-line status under the app name, and its dot.
    public var headline: (text: String, health: Health) { headline(now: Date()) }

    public func headline(now: Date) -> (text: String, health: Health) {
        let okCount = readings.filter(\.state.isOK).count
        if readAt == nil { return ("Reading sources…", .unknown) }
        let failing = readings.filter {
            if case .signIn = $0.state { return true }
            if case .error = $0.state { return true }
            return false
        }
        let age = readAt.map { "refreshed " + Format.age(of: $0, now: now) } ?? ""
        if failing.isEmpty {
            return ("\(okCount) sources · \(age)", .ok)
        }
        if okCount == 0 {
            return ("No source readable · \(age)", .failing)
        }
        let names = failing.map { $0.provider.title }.joined(separator: ", ")
        return ("\(okCount) of \(readings.count) · \(names) not read", .failing)
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
