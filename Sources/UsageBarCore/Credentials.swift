import Foundation

// Where each source's credential lives on this Mac. Usage never stores a
// credential of its own; it reads what the owning tool already keeps, and
// reads it again on every poll so a rotated token is picked up. No secret is
// ever logged, printed by `--doctor`, or carried on a reading.

/// Where Usage finds the programs it drives.
public struct ToolPaths: Equatable, Sendable {
    public var security: String
    public var agy: String
    public var home: String

    public init(
        security: String = "/usr/bin/security",
        agy: String = NSHomeDirectory() + "/.local/bin/agy",
        home: String = NSHomeDirectory()
    ) {
        self.security = security
        self.agy = agy
        self.home = home
    }

    public static let installed = ToolPaths()

    public func exists(_ path: String) -> Bool {
        FileManager.default.isExecutableFile(atPath: path)
    }
}

/// A bearer token and what the credential said about the account.
public struct OAuthCredential: Equatable, Sendable {
    public let token: String
    public let plan: String?
    public let accountID: String?
    public let expiresAt: Date?

    public init(token: String, plan: String? = nil, accountID: String? = nil, expiresAt: Date? = nil) {
        self.token = token
        self.plan = plan
        self.accountID = accountID
        self.expiresAt = expiresAt
    }

    public func isExpired(now: Date = Date()) -> Bool {
        guard let expiresAt else { return false }
        return expiresAt <= now
    }
}

/// The Claude Code OAuth credential, kept in the login keychain under the
/// service "Claude Code-credentials" as a JSON blob with `claudeAiOauth`.
public enum ClaudeCredential {

    public static let keychainService = "Claude Code-credentials"

    /// Decode the blob Claude Code stores. Exposed so the parse is testable
    /// without a keychain.
    public static func parse(_ text: String) -> OAuthCredential? {
        guard let data = text.data(using: .utf8), let root = JSON.object(data) else { return nil }
        let oauth = JSON.object(root["claudeAiOauth"])
        guard let token = JSON.string(oauth?["accessToken"]) ?? JSON.string(root["accessToken"]) else { return nil }
        var expires: Date?
        if let millis = JSON.number(oauth?["expiresAt"] ?? root["expiresAt"]) {
            expires = Date(timeIntervalSince1970: millis / 1000)
        }
        return OAuthCredential(
            token: token,
            plan: JSON.string(oauth?["subscriptionType"]) ?? JSON.string(root["subscriptionType"]),
            expiresAt: expires
        )
    }

    /// Read the keychain. The service can hold more than one item (an
    /// "unknown"-account item that only carries MCP state, plus the real
    /// per-user item), and `security` returns the first match, so the
    /// user-scoped item is asked for first.
    public static func read(tools: ToolPaths, user: String = NSUserName()) -> OAuthCredential? {
        for account in [user, nil] {
            var arguments = ["find-generic-password", "-s", keychainService]
            if let account { arguments += ["-a", account] }
            arguments.append("-w")
            let result = Subprocess.run(executable: tools.security, arguments: arguments, timeout: 8)
            guard result.succeeded else { continue }
            if let credential = parse(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)),
               !credential.isExpired() {
                return credential
            }
        }
        return nil
    }
}

/// The Codex credential at `~/.codex/auth.json` (or `$CODEX_HOME/auth.json`):
/// either `OPENAI_API_KEY`, or `tokens.access_token` plus an id token whose
/// claims name the account and plan.
public enum CodexCredential {

    private static let authClaim = "https://api.openai.com/auth"

    public static func path(tools: ToolPaths, environment: [String: String] = ProcessInfo.processInfo.environment) -> String {
        if let home = environment["CODEX_HOME"], !home.isEmpty { return home + "/auth.json" }
        return tools.home + "/.codex/auth.json"
    }

    public static func parse(_ data: Data) -> OAuthCredential? {
        guard let root = JSON.object(data) else { return nil }
        if let key = JSON.string(root["OPENAI_API_KEY"]) {
            return OAuthCredential(token: key)
        }
        let tokens = JSON.object(root["tokens"])
        guard let token = JSON.string(tokens?["access_token"]) ?? JSON.string(tokens?["accessToken"]) else { return nil }
        let idClaims = jwtClaims(JSON.string(tokens?["id_token"]) ?? JSON.string(tokens?["idToken"]))
        let accessClaims = jwtClaims(token)
        let auth = JSON.object(idClaims?[authClaim]) ?? JSON.object(accessClaims?[authClaim])
        return OAuthCredential(
            token: token,
            plan: JSON.string(auth?["chatgpt_plan_type"]),
            accountID: JSON.string(tokens?["account_id"]) ?? JSON.string(tokens?["accountId"])
                ?? JSON.string(auth?["chatgpt_account_id"])
        )
    }

    public static func read(tools: ToolPaths) -> OAuthCredential? {
        guard let data = FileManager.default.contents(atPath: path(tools: tools)) else { return nil }
        return parse(data)
    }

    /// The claims segment of a JWT. Only used to name the plan and account;
    /// the signature is not checked because nothing is trusted on it.
    static func jwtClaims(_ jwt: String?) -> [String: Any]? {
        guard let jwt else { return nil }
        let segments = jwt.split(separator: ".")
        guard segments.count >= 2 else { return nil }
        var payload = String(segments[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)
        guard let data = Data(base64Encoded: payload) else { return nil }
        return JSON.object(data)
    }
}

/// A plain API key: the first non-empty line of the first key file that
/// exists, else the environment, else a keychain item named like the
/// environment variable.
public enum APIKey {

    public static func read(files: [String], environment names: [String], tools: ToolPaths,
                            env: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        for path in files {
            if let text = try? String(contentsOfFile: path, encoding: .utf8), let key = usable(text) {
                return key
            }
        }
        for name in names {
            if let key = usable(env[name]) { return key }
        }
        for name in names {
            let result = Subprocess.run(
                executable: tools.security,
                arguments: ["find-generic-password", "-s", name, "-w"],
                timeout: 8
            )
            if result.succeeded, let key = usable(result.stdout) { return key }
        }
        return nil
    }

    static func usable(_ text: String?) -> String? {
        guard let text else { return nil }
        let line = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    public static func deepseekFiles(tools: ToolPaths) -> [String] {
        [tools.home + "/.config/deepseek/api_key", tools.home + "/.deepseek/api-key"]
    }

    public static let deepseekNames = ["DEEPSEEK_API_KEY"]

    public static func moonshotFiles(tools: ToolPaths) -> [String] {
        [tools.home + "/.config/moonshot/api_key", tools.home + "/.config/kimi/api_key"]
    }

    public static let moonshotNames = ["MOONSHOT_API_KEY", "KIMI_CN_API_KEY"]
}
