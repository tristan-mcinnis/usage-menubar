import Foundation

// One parser per source, each a pure function from the bytes the endpoint
// answered with to meters. Nothing here reads a file, runs a program, or
// touches the network; that is `ProviderReader`. The shapes are the ones the
// live endpoints answer with as of 2026-09; each is pinned by a fixture in
// Tests/UsageBarCoreTests/Fixtures.

/// `GET https://api.anthropic.com/api/oauth/usage` with the Claude Code
/// OAuth token. Top-level windows carry `utilization` as 0…100 and
/// `resets_at`; newer accounts also list model-scoped weekly windows under
/// `limits` with `kind: "weekly_scoped"`.
public enum ClaudeUsage {

    private static let windows: [(field: String, id: String, label: String)] = [
        ("five_hour", "session", "Session"),
        ("seven_day", "weekly", "Weekly"),
        ("seven_day_sonnet", "weekly-sonnet", "Weekly · Sonnet"),
        ("seven_day_opus", "weekly-opus", "Weekly · Opus"),
    ]

    public static func parse(_ data: Data) -> [Meter]? {
        guard let root = JSON.object(data) else { return nil }
        var meters: [Meter] = []

        for spec in windows {
            guard let raw = JSON.object(root[spec.field]),
                  let percent = JSON.percent(raw["utilization"]) else { continue }
            meters.append(Meter(
                id: spec.id, label: spec.label, percentUsed: percent, resetsAt: JSON.date(raw["resets_at"])
            ))
        }

        for entry in JSON.array(root["limits"]) ?? [] {
            guard let limit = JSON.object(entry), JSON.string(limit["kind"]) == "weekly_scoped",
                  let percent = JSON.percent(limit["percent"]) else { continue }
            let model = JSON.string(JSON.object(JSON.object(limit["scope"])?["model"])?["display_name"])
            let suffix = model ?? "scoped"
            meters.append(Meter(
                id: "weekly-scoped-\(suffix.lowercased())",
                label: "Weekly · \(suffix)",
                percentUsed: percent,
                resetsAt: JSON.date(limit["resets_at"]),
                active: JSON.bool(limit["is_active"]) ?? false
            ))
        }

        return meters.isEmpty ? nil : meters
    }
}

/// `GET https://chatgpt.com/backend-api/wham/usage` with the Codex OAuth
/// token. `rate_limit` has a primary and a secondary window, each with
/// `used_percent`, `limit_window_seconds`, and `reset_at` in epoch seconds;
/// per-feature caps are listed under `additional_rate_limits`.
public enum CodexUsage {

    public struct Parsed: Equatable {
        public let plan: String?
        public let meters: [Meter]
    }

    public static func parse(_ data: Data) -> Parsed? {
        guard let root = JSON.object(data) else { return nil }
        var meters: [Meter] = []

        meters += windows(of: root["rate_limit"], key: "rate", prefix: nil)

        for (index, entry) in (JSON.array(root["additional_rate_limits"]) ?? []).enumerated() {
            guard let record = JSON.object(entry) else { continue }
            let name = JSON.string(record["limit_name"]) ?? JSON.string(record["metered_feature"]) ?? "limit \(index + 1)"
            // Codex Spark's cap is a separate metered feature that is not the
            // plan; hidden, as Baby Menu also hides it.
            if name.lowercased().contains("spark") || JSON.string(record["metered_feature"]) == "codex_bengalfox" {
                continue
            }
            meters += windows(of: record["rate_limit"], key: "extra-\(index)", prefix: name)
        }

        meters += windows(of: root["code_review_rate_limit"], key: "review", prefix: "Code review")

        guard !meters.isEmpty else { return nil }
        return Parsed(plan: JSON.string(root["plan_type"]), meters: meters)
    }

    private static func windows(of raw: Any?, key: String, prefix: String?) -> [Meter] {
        guard let record = JSON.object(raw) else { return [] }
        var meters: [Meter] = []
        if let primary = window(record["primary_window"], key: "\(key)-primary", position: "primary", prefix: prefix) {
            meters.append(primary)
        }
        if let secondary = window(record["secondary_window"], key: "\(key)-secondary", position: "secondary", prefix: prefix) {
            meters.append(secondary)
        }
        return meters
    }

    private static func window(_ raw: Any?, key: String, position: String, prefix: String?) -> Meter? {
        guard let record = JSON.object(raw), let percent = JSON.percent(record["used_percent"]) else { return nil }
        let seconds = JSON.number(record["limit_window_seconds"])
        var label: String
        if let seconds {
            if seconds >= 6 * 86_400 { label = "Weekly" }
            else if seconds <= 6 * 3_600 { label = "Session" }
            else { label = Format.countdown(to: Date(timeIntervalSince1970: seconds), from: Date(timeIntervalSince1970: 0)) + " window" }
        } else {
            label = position.prefix(1).uppercased() + position.dropFirst() + " window"
        }
        if let prefix { label = "\(prefix) · \(label.lowercased())" }

        var resetsAt: Date?
        if let epoch = JSON.number(record["reset_at"]) {
            resetsAt = Date(timeIntervalSince1970: epoch)
        } else if let after = JSON.number(record["reset_after_seconds"]) {
            resetsAt = Date().addingTimeInterval(after)
        }
        return Meter(id: key, label: label, percentUsed: percent, resetsAt: resetsAt)
    }
}

/// `agy --output-format json --print=/usage`. Groups of buckets, each bucket
/// a `weekly` or `5h` window with `remaining_fraction` 0…1 and `reset_time`.
public enum AntigravityUsage {

    public static func parse(_ data: Data) -> [Meter]? {
        guard let root = JSON.object(data),
              let command = JSON.object(root["command"]),
              JSON.string(command["name"]) == "usage",
              let groups = JSON.array(JSON.object(command["data"])?["groups"]) else { return nil }

        var meters: [Meter] = []
        for entry in groups {
            guard let group = JSON.object(entry), let groupName = JSON.string(group["name"]) else { continue }
            for rawBucket in JSON.array(group["buckets"]) ?? [] {
                guard let bucket = JSON.object(rawBucket),
                      let id = JSON.string(bucket["id"]),
                      let window = JSON.string(bucket["window"]),
                      let remaining = JSON.number(bucket["remaining_fraction"]) else { continue }
                let span = window == "weekly" ? "weekly" : "session"
                meters.append(Meter(
                    id: id,
                    label: "\(groupName) · \(span)",
                    percentUsed: (1 - remaining) * 100,
                    resetsAt: JSON.date(bucket["reset_time"])
                ))
            }
        }
        return meters.isEmpty ? nil : meters
    }
}

/// `GET https://api.deepseek.com/user/balance`. Every amount is a decimal
/// string: `{ is_available, balance_infos: [{ currency, total_balance,
/// granted_balance, topped_up_balance }] }`.
public enum DeepSeekBalance {

    public struct Balance: Equatable, Sendable {
        public let currency: String
        public let total: Double
        public let granted: Double
        public let toppedUp: Double
    }

    public static func parse(_ data: Data) -> [Balance]? {
        guard let root = JSON.object(data), let infos = JSON.array(root["balance_infos"]) else { return nil }
        var balances: [Balance] = []
        for entry in infos {
            guard let record = JSON.object(entry), let total = JSON.number(record["total_balance"]) else { continue }
            balances.append(Balance(
                currency: JSON.string(record["currency"]) ?? "",
                total: total,
                granted: JSON.number(record["granted_balance"]) ?? 0,
                toppedUp: JSON.number(record["topped_up_balance"]) ?? 0
            ))
        }
        return balances.isEmpty ? nil : balances
    }
}

/// `GET https://api.moonshot.cn/v1/users/me/balance`: `{ code: 0, data: {
/// available_balance, voucher_balance, cash_balance } }`. A non-zero `code`
/// is an error even under HTTP 200. The response names no currency; the host
/// does (`.cn` bills in CNY, `.ai` in USD).
public enum MoonshotBalance {

    public struct Balance: Equatable, Sendable {
        public let available: Double
        public let cash: Double
        public let voucher: Double
    }

    public static func parse(_ data: Data) -> Balance? {
        guard let root = JSON.object(data), JSON.number(root["code"]) == 0,
              let payload = JSON.object(root["data"]),
              let available = JSON.number(payload["available_balance"]) else { return nil }
        return Balance(
            available: available,
            cash: JSON.number(payload["cash_balance"]) ?? 0,
            voucher: JSON.number(payload["voucher_balance"]) ?? 0
        )
    }

    public static func currency(forHost host: String) -> String {
        host.hasSuffix(".cn") ? "CNY" : "USD"
    }
}
