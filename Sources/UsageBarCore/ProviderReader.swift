import Foundation

/// Reads one provider end to end: credential, call, parse, meters. Every
/// function here blocks and is meant for the model's work queue. The
/// `SampleStore` is passed in so a balance read can also record itself.
public enum ProviderReader {

    public static let claudeUsageURL = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    public static let codexUsageURL = URL(string: "https://chatgpt.com/backend-api/wham/usage")!
    public static let deepseekBalanceURL = URL(string: "https://api.deepseek.com/user/balance")!
    public static let moonshotDefaultBase = "https://api.moonshot.cn/v1"
    public static let sonioxUsageURL = URL(string: "https://api.soniox.com/v1/usage/summary")!

    public static func read(
        _ provider: ProviderID,
        tools: ToolPaths,
        samples: inout SampleStore,
        now: Date = Date()
    ) -> ProviderReading {
        switch provider {
        case .claude: return claude(tools: tools, now: now)
        case .codex: return codex(tools: tools, now: now)
        case .antigravity: return antigravity(tools: tools, now: now)
        case .deepseek: return deepseek(tools: tools, samples: &samples, now: now)
        case .moonshot: return moonshot(tools: tools, samples: &samples, now: now)
        case .soniox: return soniox(tools: tools, now: now)
        }
    }

    // MARK: - Subscriptions

    static func claude(tools: ToolPaths, now: Date) -> ProviderReading {
        guard let credential = ClaudeCredential.read(tools: tools) else {
            return ProviderReading(provider: .claude, state: .signIn("Sign in to Claude Code"), readAt: now)
        }
        let headers = ["Authorization": "Bearer \(credential.token)", "anthropic-beta": "oauth-2025-04-20"]
        switch HTTP.get(claudeUsageURL, headers: headers) {
        case let .success(data):
            guard let meters = ClaudeUsage.parse(data) else {
                return ProviderReading(provider: .claude, state: .error("Unreadable usage answer"), plan: credential.plan, readAt: now)
            }
            return ProviderReading(provider: .claude, state: .ok, plan: credential.plan, meters: meters, readAt: now)
        case .failure(.auth):
            return ProviderReading(provider: .claude, state: .signIn("Sign in to Claude Code"), plan: credential.plan, readAt: now)
        case let .failure(failure):
            return ProviderReading(provider: .claude, state: .error(failure.message), plan: credential.plan, readAt: now)
        }
    }

    static func codex(tools: ToolPaths, now: Date) -> ProviderReading {
        guard let credential = CodexCredential.read(tools: tools) else {
            return ProviderReading(provider: .codex, state: .signIn("Sign in to Codex"), readAt: now)
        }
        var headers = ["Authorization": "Bearer \(credential.token)"]
        if let account = credential.accountID { headers["ChatGPT-Account-Id"] = account }
        switch HTTP.get(codexUsageURL, headers: headers) {
        case let .success(data):
            guard let parsed = CodexUsage.parse(data) else {
                return ProviderReading(provider: .codex, state: .error("Unreadable usage answer"), plan: credential.plan, readAt: now)
            }
            return ProviderReading(
                provider: .codex, state: .ok, plan: parsed.plan ?? credential.plan, meters: parsed.meters, readAt: now
            )
        case .failure(.auth):
            return ProviderReading(provider: .codex, state: .signIn("Sign in to Codex"), plan: credential.plan, readAt: now)
        case let .failure(failure):
            return ProviderReading(provider: .codex, state: .error(failure.message), plan: credential.plan, readAt: now)
        }
    }

    /// `/usage` is a local CLI command: it makes no model turn.
    static func antigravity(tools: ToolPaths, now: Date) -> ProviderReading {
        guard tools.exists(tools.agy) else {
            return ProviderReading(provider: .antigravity, state: .signIn("agy not installed"), readAt: now)
        }
        let result = Subprocess.run(
            executable: tools.agy,
            arguments: ["--output-format", "json", "--print=/usage"],
            timeout: 20
        )
        guard result.succeeded else {
            let said = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            let reason = said.split(whereSeparator: \.isNewline).first.map(String.init) ?? "agy exited \(result.exitCode)"
            let state: ReadState = reason.lowercased().contains("login") || reason.lowercased().contains("auth")
                ? .signIn("Sign in to Antigravity") : .error(reason)
            return ProviderReading(provider: .antigravity, state: state, readAt: now)
        }
        guard let meters = AntigravityUsage.parse(Data(result.stdout.utf8)) else {
            return ProviderReading(provider: .antigravity, state: .error("Unreadable usage answer"), readAt: now)
        }
        return ProviderReading(provider: .antigravity, state: .ok, meters: meters, readAt: now)
    }

    // MARK: - API keys

    static func deepseek(tools: ToolPaths, samples: inout SampleStore, now: Date) -> ProviderReading {
        guard let key = APIKey.read(files: APIKey.deepseekFiles(tools: tools), environment: APIKey.deepseekNames, tools: tools) else {
            return ProviderReading(provider: .deepseek, state: .signIn("No DeepSeek key"), readAt: now)
        }
        switch HTTP.get(deepseekBalanceURL, headers: ["Authorization": "Bearer \(key)"]) {
        case let .success(data):
            guard let balances = DeepSeekBalance.parse(data) else {
                return ProviderReading(provider: .deepseek, state: .error("Unreadable balance answer"), readAt: now)
            }
            let meters = balances.map { balance -> Meter in
                let spent = samples.record(balance.total, for: "deepseek:\(balance.currency)", at: now)
                return Meter(
                    id: "balance-\(balance.currency.lowercased())",
                    label: balances.count > 1 ? "Balance · \(balance.currency)" : "Balance",
                    percentUsed: spent,
                    amount: balance.total,
                    currency: balance.currency
                )
            }
            return ProviderReading(provider: .deepseek, state: .ok, meters: meters, readAt: now)
        case .failure(.auth):
            return ProviderReading(provider: .deepseek, state: .signIn("DeepSeek key rejected"), readAt: now)
        case let .failure(failure):
            return ProviderReading(provider: .deepseek, state: .error(failure.message), readAt: now)
        }
    }

    static func moonshot(tools: ToolPaths, samples: inout SampleStore, now: Date,
                         env: [String: String] = ProcessInfo.processInfo.environment) -> ProviderReading {
        guard let key = APIKey.read(files: APIKey.moonshotFiles(tools: tools), environment: APIKey.moonshotNames, tools: tools) else {
            return ProviderReading(provider: .moonshot, state: .signIn("No Moonshot key"), readAt: now)
        }
        let base = (env["MOONSHOT_BASE_URL"]?.trimmingCharacters(in: .whitespaces)).flatMap { $0.isEmpty ? nil : $0 }
            ?? moonshotDefaultBase
        guard let url = URL(string: base.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/users/me/balance") else {
            return ProviderReading(provider: .moonshot, state: .error("Bad MOONSHOT_BASE_URL"), readAt: now)
        }
        let host = url.host ?? "api.moonshot.cn"
        switch HTTP.get(url, headers: ["Authorization": "Bearer \(key)"]) {
        case let .success(data):
            guard let balance = MoonshotBalance.parse(data) else {
                return ProviderReading(provider: .moonshot, state: .error("Unreadable balance answer"), readAt: now)
            }
            let currency = MoonshotBalance.currency(forHost: host)
            let spent = samples.record(balance.available, for: "moonshot:\(host)", at: now)
            let meter = Meter(id: "balance", label: "Balance", percentUsed: spent, amount: balance.available, currency: currency)
            return ProviderReading(provider: .moonshot, state: .ok, meters: [meter], readAt: now)
        case .failure(.auth):
            return ProviderReading(provider: .moonshot, state: .signIn("Moonshot key rejected"), readAt: now)
        case let .failure(failure):
            return ProviderReading(provider: .moonshot, state: .error(failure.message), readAt: now)
        }
    }
}

extension ProviderReader {

    /// Spend over the last thirty days, in USD. No balance exists to read.
    static func soniox(tools: ToolPaths, now: Date) -> ProviderReading {
        guard let key = APIKey.read(files: APIKey.sonioxFiles(tools: tools), environment: APIKey.sonioxNames, tools: tools) else {
            return ProviderReading(provider: .soniox, state: .signIn("No Soniox key"), readAt: now)
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        var components = URLComponents(url: sonioxUsageURL, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "start_time", value: formatter.string(from: now.addingTimeInterval(-30 * 86_400))),
            URLQueryItem(name: "end_time", value: formatter.string(from: now)),
        ]
        switch HTTP.get(components.url!, headers: ["Authorization": "Bearer \(key)"]) {
        case let .success(data):
            guard let spent = SonioxUsage.parse(data) else {
                return ProviderReading(provider: .soniox, state: .error("Unreadable usage answer"), readAt: now)
            }
            let meter = Meter(id: "spend-30d", label: "Spent · 30d", percentUsed: nil, amount: spent, currency: "USD", spent: true)
            return ProviderReading(provider: .soniox, state: .ok, meters: [meter], readAt: now)
        case .failure(.auth):
            return ProviderReading(provider: .soniox, state: .signIn("Soniox key rejected"), readAt: now)
        case let .failure(failure):
            return ProviderReading(provider: .soniox, state: .error(failure.message), readAt: now)
        }
    }
}
