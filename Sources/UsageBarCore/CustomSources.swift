import Foundation

// Custom sources: rows Tristan adds without code, from
// `~/.config/usage-bar/sources.json`. Two kinds. A `manual` source is a plan
// with no usage API (SuperGrok, X Premium): its bar is how much of the current
// billing period has passed, and the renewal rolls forward on its own. A
// `command` source is a program the user wrote that prints one JSON object
// with a percent. Everything here is pure except `CustomSourceReader`, which
// runs the command through `Subprocess`.

/// Where the custom-source file lives, and the template "Edit sources…"
/// writes when there is none.
public enum CustomSourceFile {

    public static func defaultPath(home: String = NSHomeDirectory()) -> String {
        home + "/.config/usage-bar/sources.json"
    }

    /// The file's modification time, so the panel can tell a saved edit from
    /// an unchanged file with one stat. Nil when the file does not exist.
    public static func stamp(of path: String) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
    }

    /// Write the template when the file does not exist yet. Returns true when
    /// it wrote one; an existing file is never touched.
    @discardableResult
    public static func createTemplateIfMissing(at path: String) throws -> Bool {
        guard !FileManager.default.fileExists(atPath: path) else { return false }
        let url = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(template.utf8).write(to: url, options: .withoutOverwriting)
        return true
    }

    /// The file "Edit sources…" creates. Every example is a comment, so a
    /// new file adds no row until one is copied into "sources".
    public static let template = """
    // Usage custom sources.
    // Usage reads this file on every poll and whenever the panel opens, so a
    // saved change shows the next time you open the panel. No restart.
    // A line that starts with // is a comment. Everything else is JSON.
    //
    // Two kinds of source:
    //
    //   "manual": a plan with no usage API. The bar is how much of the current
    //   billing period has passed. "renews" is any one renewal date, past or
    //   future; Usage rolls it forward each period. "period" is "monthly"
    //   (the default) or "yearly".
    //
    //   "command": a program you write. Usage runs it on every poll and reads
    //   one JSON object from what it prints:
    //     {"percent": 42, "detail": "420 of 1000 credits", "resetsAt": "2026-11-01T00:00:00Z"}
    //   "percent" is 0 to 100 (or null when unknown); "detail" and "resetsAt"
    //   are optional. "command" is an argument array, run directly with no
    //   shell, or a string, run with /bin/sh -c. "timeout" is in seconds
    //   (default 10, 1 to 60). If the program fails, the row keeps its last
    //   good numbers and says why.
    //
    // Optional on both: "lane" ("subscription", the default, or "apiKey"),
    // "url" (what Return on the row opens), and "plan" (the text on the right).
    //
    // Examples, to copy into "sources" below:
    //
    //   {"kind": "manual", "name": "SuperGrok", "plan": "SuperGrok", "cost": 30,
    //    "currency": "USD", "period": "monthly", "renews": "2026-11-03",
    //    "url": "https://grok.com"}
    //
    //   {"kind": "command", "name": "My API", "lane": "apiKey",
    //    "command": ["~/bin/my-usage", "--json"], "timeout": 10}
    {
      "sources": [
      ]
    }

    """
}

/// How often a manual plan renews.
public enum BillingPeriod: String, Equatable, Sendable {
    case monthly
    case yearly

    public var months: Int { self == .monthly ? 1 : 12 }
    /// "/mo", "/yr", after the price.
    public var suffix: String { self == .monthly ? "/mo" : "/yr" }
}

/// A plan with no usage API: what it costs and when it renews.
public struct ManualPlan: Equatable, Sendable {
    public let plan: String?
    public let cost: Double?
    public let currency: String
    public let period: BillingPeriod
    /// One renewal date, as the calendar day the user wrote ("2026-11-03").
    public let renews: DateComponents

    public init(plan: String?, cost: Double?, currency: String, period: BillingPeriod, renews: DateComponents) {
        self.plan = plan
        self.cost = cost
        self.currency = currency
        self.period = period
        self.renews = renews
    }
}

/// A user program that prints `{"percent": …}`. Run with no shell unless the
/// config gave a string, which is then the user's own `/bin/sh -c` script;
/// Usage never puts a value of its own into it.
public struct CommandSpec: Equatable, Sendable {
    public let executable: String
    public let arguments: [String]
    public let timeout: TimeInterval
    public let plan: String?

    public init(executable: String, arguments: [String], timeout: TimeInterval, plan: String?) {
        self.executable = executable
        self.arguments = arguments
        self.timeout = timeout
        self.plan = plan
    }
}

/// One entry of the config file, read and checked.
public struct CustomSource: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case manual(ManualPlan)
        case command(CommandSpec)
        /// The entry, or the whole file, could not be used. The row says why.
        case invalid(String)
    }

    public let id: ProviderID
    public let kind: Kind

    public init(id: ProviderID, kind: Kind) {
        self.id = id
        self.kind = kind
    }
}

/// The parsed config file: every entry in file order, a broken one included
/// as `.invalid` so it is a row with a reason rather than a silent gap.
public struct CustomSourceConfig: Equatable, Sendable {
    public let sources: [CustomSource]

    public init(sources: [CustomSource] = []) {
        self.sources = sources
    }

    public static let empty = CustomSourceConfig()

    /// The panel keys, in file order.
    public var providers: [ProviderID] { sources.map(\.id) }

    public func source(_ id: ProviderID) -> CustomSource? {
        sources.first { $0.id == id }
    }

    /// A missing file is no custom sources, not a failure.
    public static func load(from path: String) -> CustomSourceConfig {
        guard let data = FileManager.default.contents(atPath: path) else { return .empty }
        return parse(data)
    }

    /// Read the file's text. Never throws: a file that cannot be used becomes
    /// one `.invalid` row that names the problem.
    public static func parse(_ data: Data) -> CustomSourceConfig {
        let text = String(decoding: data, as: UTF8.self)
        let json = stripComments(text)
        if json.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return .empty }
        let root: Any
        do {
            root = try JSONSerialization.jsonObject(with: Data(json.utf8))
        } catch {
            return fileProblem("not valid JSON" + location(of: error))
        }
        guard let object = root as? [String: Any] else {
            return fileProblem("the top level must be an object with a \"sources\" list")
        }
        guard let list = object["sources"] as? [Any] else {
            return fileProblem("no \"sources\" list")
        }

        var sources: [CustomSource] = []
        var used: Set<String> = []
        for (index, value) in list.enumerated() {
            sources.append(entry(value, number: index + 1, used: &used))
        }
        return CustomSourceConfig(sources: sources)
    }

    // MARK: - Entries

    private static func fileProblem(_ reason: String) -> CustomSourceConfig {
        CustomSourceConfig(sources: [CustomSource(id: .customConfig, kind: .invalid("sources.json: " + reason))])
    }

    private static func entry(_ value: Any, number: Int, used: inout Set<String>) -> CustomSource {
        let object = value as? [String: Any] ?? [:]
        let name = JSON.string(object["name"])
        let lane = laneValue(object["lane"])
        let url = urlValue(object["url"])
        let kindWord = JSON.string(object["kind"])?.lowercased()
        let glyph = kindWord == "command" ? "terminal" : "calendar"

        let title = name ?? "Entry \(number)"
        var slug = slug(of: name ?? "entry-\(number)")
        var duplicate = false
        if used.contains(slug) {
            duplicate = true
            var n = 2
            while used.contains("\(slug)-\(n)") { n += 1 }
            slug = "\(slug)-\(n)"
        }
        used.insert(slug)
        let id = ProviderID.custom(
            slug: slug,
            display: CustomDisplay(title: title, lane: lane.value ?? .subscription, glyph: glyph, url: url.value)
        )
        func invalid(_ reason: String) -> CustomSource { CustomSource(id: id, kind: .invalid(reason)) }

        guard value is [String: Any] else { return invalid("entry \(number) is not an object") }
        guard name != nil else { return invalid("entry \(number) has no \"name\"") }
        if duplicate { return invalid("another source is already named \(title)") }
        if let problem = lane.problem { return invalid(problem) }
        if let problem = url.problem { return invalid(problem) }
        let plan = JSON.string(object["plan"])

        switch kindWord {
        case "manual":
            switch manual(object, plan: plan) {
            case let .success(manual): return CustomSource(id: id, kind: .manual(manual))
            case let .failure(problem): return invalid(problem.reason)
            }
        case "command":
            switch command(object, plan: plan) {
            case let .success(spec): return CustomSource(id: id, kind: .command(spec))
            case let .failure(problem): return invalid(problem.reason)
            }
        default:
            return invalid("\"kind\" must be \"manual\" or \"command\"")
        }
    }

    struct Problem: Error { let reason: String }

    private static func manual(_ object: [String: Any], plan: String?) -> Result<ManualPlan, Problem> {
        guard let renewsText = JSON.string(object["renews"]) else {
            return .failure(Problem(reason: "\"renews\" is missing (a date like 2026-11-03)"))
        }
        guard let renews = calendarDay(renewsText) else {
            return .failure(Problem(reason: "\"renews\" must be YYYY-MM-DD"))
        }
        var cost: Double?
        if let raw = object["cost"], !(raw is NSNull) {
            guard let number = JSON.number(raw), number >= 0 else {
                return .failure(Problem(reason: "\"cost\" must be a number, 0 or more"))
            }
            cost = number
        }
        var period = BillingPeriod.monthly
        if let word = JSON.string(object["period"]) {
            guard let parsed = BillingPeriod(rawValue: word.lowercased()) else {
                return .failure(Problem(reason: "\"period\" must be \"monthly\" or \"yearly\""))
            }
            period = parsed
        }
        let currency = JSON.string(object["currency"])?.uppercased() ?? "USD"
        return .success(ManualPlan(plan: plan, cost: cost, currency: currency, period: period, renews: renews))
    }

    /// The longest a command may run before it is stopped.
    public static let maxTimeout: TimeInterval = 60
    public static let defaultTimeout: TimeInterval = 10

    private static func command(_ object: [String: Any], plan: String?) -> Result<CommandSpec, Problem> {
        let argv: [String]
        if let text = object["command"] as? String {
            let script = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !script.isEmpty else { return .failure(Problem(reason: "\"command\" is empty")) }
            argv = ["/bin/sh", "-c", script]
        } else if let list = object["command"] as? [Any] {
            let words = list.compactMap { $0 as? String }
            guard words.count == list.count else {
                return .failure(Problem(reason: "every word of \"command\" must be a string"))
            }
            guard let first = words.first, !first.isEmpty else {
                return .failure(Problem(reason: "\"command\" is empty"))
            }
            argv = words
        } else {
            return .failure(Problem(reason: "\"command\" is missing (an argument array or a string)"))
        }
        var timeout = defaultTimeout
        if let raw = object["timeout"], !(raw is NSNull) {
            guard let seconds = JSON.number(raw), seconds > 0 else {
                return .failure(Problem(reason: "\"timeout\" must be a number of seconds"))
            }
            timeout = min(max(seconds, 1), maxTimeout)
        }
        return .success(CommandSpec(executable: argv[0], arguments: Array(argv.dropFirst()), timeout: timeout, plan: plan))
    }

    private static func laneValue(_ value: Any?) -> (value: Lane?, problem: String?) {
        guard let word = JSON.string(value) else { return (nil, nil) }
        switch word.lowercased().replacingOccurrences(of: " ", with: "") {
        case "subscription": return (.subscription, nil)
        case "apikey", "api": return (.apiKey, nil)
        default: return (nil, "\"lane\" must be \"subscription\" or \"apiKey\"")
        }
    }

    private static func urlValue(_ value: Any?) -> (value: URL?, problem: String?) {
        guard let text = JSON.string(value) else { return (nil, nil) }
        guard let url = URL(string: text), let scheme = url.scheme?.lowercased(),
              scheme == "https" || scheme == "http", url.host != nil else {
            return (nil, "\"url\" must be an http or https address")
        }
        return (url, nil)
    }

    // MARK: - Text

    /// Blank every line that starts with `//`, keeping the line breaks, so a
    /// JSON error's line number is still the line in the file.
    static func stripComments(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces).hasPrefix("//") ? "" : String($0) }
            .joined(separator: "\n")
    }

    /// " (line 4, column 3)" from a JSONSerialization error, when it says.
    private static func location(of error: Error) -> String {
        let said = ((error as NSError).userInfo[NSDebugDescriptionErrorKey] as? String) ?? ""
        guard let range = said.range(of: #"line \d+, column \d+"#, options: .regularExpression) else { return "" }
        return " (" + said[range] + ")"
    }

    /// "SuperGrok" → "supergrok", "X Premium+" → "x-premium".
    static func slug(of name: String) -> String {
        var out = ""
        var dash = false
        for scalar in name.lowercased().unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                out.unicodeScalars.append(scalar)
                dash = false
            } else if !out.isEmpty, !dash {
                out.append("-")
                dash = true
            }
        }
        while out.hasSuffix("-") { out.removeLast() }
        return out.isEmpty ? "source" : out
    }

    /// "2026-11-03" → year, month, day. A day that does not exist (Feb 30)
    /// is refused rather than rolled into March.
    static func calendarDay(_ text: String) -> DateComponents? {
        let parts = text.split(separator: "-")
        guard parts.count == 3, parts[0].count == 4,
              let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2]),
              (1...12).contains(month), day >= 1 else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let components = DateComponents(year: year, month: month, day: day)
        guard let date = calendar.date(from: components),
              calendar.component(.day, from: date) == day,
              calendar.component(.month, from: date) == month else { return nil }
        return components
    }
}

/// The billing period that contains a moment, for a plan that renews every
/// `months` months from one anchor day.
public enum BillingMath {

    public struct Period: Equatable, Sendable {
        public let start: Date
        public let end: Date
    }

    /// Every boundary is counted from the anchor (anchor + k months), never
    /// from the previous boundary, so a plan that renews on the 31st renews
    /// on Feb 28 (or 29) and then on Mar 31 again, and a Feb 29 yearly plan
    /// renews on Feb 28 in common years and Feb 29 in leap years.
    public static func period(
        anchor: DateComponents,
        months: Int,
        containing now: Date,
        calendar: Calendar
    ) -> Period? {
        guard months > 0, let start = calendar.date(from: anchor) else { return nil }
        func boundary(_ k: Int) -> Date? { calendar.date(byAdding: .month, value: k * months, to: start) }
        let elapsed = calendar.dateComponents([.month], from: start, to: now).month ?? 0
        var k = Int((Double(elapsed) / Double(months)).rounded(.down))
        // The month count is approximate across short months: step until the
        // period [k, k+1) holds `now`.
        for _ in 0..<4 {
            guard let lower = boundary(k) else { return nil }
            if lower > now { k -= 1; continue }
            guard let upper = boundary(k + 1) else { return nil }
            if upper <= now { k += 1; continue }
            return Period(start: lower, end: upper)
        }
        return nil
    }

    /// Percent of the period that has passed, 0…100.
    public static func percentElapsed(_ period: Period, now: Date) -> Double {
        let total = period.end.timeIntervalSince(period.start)
        guard total > 0 else { return 0 }
        return min(100, max(0, now.timeIntervalSince(period.start) / total * 100))
    }

    /// Whole calendar days from today to the renewal day.
    public static func daysLeft(_ period: Period, now: Date, calendar: Calendar) -> Int {
        let today = calendar.startOfDay(for: now)
        let renewal = calendar.startOfDay(for: period.end)
        return max(0, calendar.dateComponents([.day], from: today, to: renewal).day ?? 0)
    }

    /// "renews today", "renews in 1 day", "renews in 12 days".
    public static func renewalPhrase(daysLeft: Int) -> String {
        switch daysLeft {
        case 0: return "renews today"
        case 1: return "renews in 1 day"
        default: return "renews in \(daysLeft) days"
        }
    }
}

/// What a custom command printed, read.
public struct CommandOutput: Equatable, Sendable {
    public let percent: Double?
    public let detail: String?
    public let resetsAt: Date?

    public init(percent: Double?, detail: String?, resetsAt: Date?) {
        self.percent = percent
        self.detail = detail
        self.resetsAt = resetsAt
    }

    /// The JSON object the command printed: the whole output, or else its
    /// last non-empty line, so a script may log above its answer. The reason
    /// on a failure is what the row shows.
    public static func parse(_ stdout: String) -> Result<CommandOutput, ParseFailure> {
        let trimmed = stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .failure(ParseFailure("printed nothing")) }
        let lastLine = trimmed.split(whereSeparator: \.isNewline).last.map(String.init) ?? trimmed
        guard let object = JSON.object(Data(trimmed.utf8)) ?? JSON.object(Data(lastLine.utf8)) else {
            return .failure(ParseFailure("did not print a JSON object"))
        }
        guard object.keys.contains("percent") else { return .failure(ParseFailure("printed no \"percent\"")) }
        var percent: Double?
        if !(object["percent"] is NSNull) {
            guard let number = JSON.number(object["percent"]), number.isFinite else {
                return .failure(ParseFailure("\"percent\" is not a number"))
            }
            guard (0...100).contains(number) else {
                return .failure(ParseFailure("\"percent\" \(Format.trimmed(number)) is outside 0 to 100"))
            }
            percent = number
        }
        var resetsAt: Date?
        if let raw = object["resetsAt"], !(raw is NSNull) {
            guard let date = JSON.date(raw) else {
                return .failure(ParseFailure("\"resetsAt\" is not an ISO 8601 date"))
            }
            resetsAt = date
        }
        return .success(CommandOutput(percent: percent, detail: JSON.string(object["detail"]), resetsAt: resetsAt))
    }

    public struct ParseFailure: Error, Equatable, Sendable {
        public let reason: String
        public init(_ reason: String) { self.reason = reason }
    }
}

/// Reads one custom source. A manual source is arithmetic on the clock; a
/// command source runs its program on the caller's queue, never the main one.
public enum CustomSourceReader {

    /// Runs a command: executable, arguments, timeout. Tests pass a fake.
    public typealias Runner = @Sendable (String, [String], TimeInterval) -> CommandResult

    public static let subprocess: Runner = { executable, arguments, timeout in
        Subprocess.run(executable: executable, arguments: arguments, timeout: timeout)
    }

    /// Where a bare program name ("my-usage") is looked for. The app starts
    /// from launchd with a short PATH, so the usual install places are named.
    public static func searchPaths(home: String = NSHomeDirectory()) -> [String] {
        [home + "/.local/bin", home + "/bin", "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"]
    }

    /// An absolute or `~/` path as it is, a bare name through `searchPaths`.
    public static func resolve(
        _ executable: String,
        home: String = NSHomeDirectory(),
        isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    ) -> String? {
        if executable.hasPrefix("~/") { return resolve(home + executable.dropFirst(), home: home, isExecutable: isExecutable) }
        if executable.contains("/") { return isExecutable(executable) ? executable : nil }
        return searchPaths(home: home).map { $0 + "/" + executable }.first(where: isExecutable)
    }

    public static func read(
        _ source: CustomSource,
        now: Date = Date(),
        calendar: Calendar = .current,
        home: String = NSHomeDirectory(),
        isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) },
        run: Runner = subprocess
    ) -> ProviderReading {
        func attempt(_ state: ReadState, plan: String? = nil, meters: [Meter] = []) -> ProviderReading {
            ProviderReading(
                provider: source.id, state: state, plan: plan, meters: meters,
                readAt: state.isOK ? now : nil, attemptedAt: now
            )
        }
        switch source.kind {
        case let .invalid(reason):
            return attempt(.error(reason))

        case let .manual(manual):
            guard let period = BillingMath.period(anchor: manual.renews, months: manual.period.months, containing: now, calendar: calendar) else {
                return attempt(.error("could not work out the billing period"))
            }
            let days = BillingMath.daysLeft(period, now: now, calendar: calendar)
            var note = BillingMath.renewalPhrase(daysLeft: days)
            if let cost = manual.cost {
                note += " · " + Format.price(cost, currency: manual.currency) + manual.period.suffix
            }
            let meter = Meter(
                id: "period",
                label: "Billing period",
                percentUsed: BillingMath.percentElapsed(period, now: now),
                note: note
            )
            return attempt(.ok, plan: manual.plan, meters: [meter])

        case let .command(spec):
            guard let executable = resolve(spec.executable, home: home, isExecutable: isExecutable) else {
                return attempt(.error("\(spec.executable) not found"), plan: spec.plan)
            }
            let result = run(executable, spec.arguments, spec.timeout)
            guard result.succeeded else {
                return attempt(.error(failureReason(result, executable: executable)), plan: spec.plan)
            }
            switch CommandOutput.parse(result.stdout) {
            case let .failure(failure):
                return attempt(.error(failure.reason), plan: spec.plan)
            case let .success(output):
                let meter = Meter(
                    id: "command",
                    label: "Usage",
                    percentUsed: output.percent,
                    resetsAt: output.resetsAt,
                    note: output.detail
                )
                return attempt(.ok, plan: spec.plan, meters: [meter])
            }
        }
    }

    /// The first line the command wrote to stderr, without the executable
    /// path `Subprocess` puts in front of its own messages, or its exit code.
    static func failureReason(_ result: CommandResult, executable: String) -> String {
        let said = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var line = said.split(whereSeparator: \.isNewline).first.map(String.init) else {
            return "exited \(result.exitCode)"
        }
        if line.hasPrefix(executable + ": ") { line = String(line.dropFirst(executable.count + 2)) }
        return line
    }
}
