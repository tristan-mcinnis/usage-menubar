import Foundation
import Testing
@testable import UsageBarCore

/// The config file: what a good entry becomes, and that every bad file or
/// entry becomes a row with a reason, never a crash and never a silent gap.
@Suite("sources.json parser")
struct CustomSourceConfigTests {

    private func parse(_ text: String) -> CustomSourceConfig {
        CustomSourceConfig.parse(Data(text.utf8))
    }

    private func reason(_ source: CustomSource?) -> String? {
        guard case let .invalid(reason) = source?.kind else { return nil }
        return reason
    }

    // MARK: - Empty files

    @Test("A missing file is no custom sources, not a failure")
    func missingFile() {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("absent-\(UUID().uuidString).json").path
        #expect(CustomSourceConfig.load(from: path) == .empty)
    }

    @Test("A file of only comments and blank lines is empty")
    func onlyComments() {
        #expect(parse("// nothing here yet\n\n   // still nothing\n") == .empty)
    }

    @Test("The template Edit sources writes parses to no rows")
    func templateParses() {
        #expect(parse(CustomSourceFile.template) == .empty)
    }

    @Test("Creating the template never overwrites an existing file")
    func templateNeverOverwrites() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sources-\(UUID().uuidString)")
        let path = dir.appendingPathComponent("usage-bar/sources.json").path
        #expect(try CustomSourceFile.createTemplateIfMissing(at: path))
        try Data("{\"sources\": []}".utf8).write(to: URL(fileURLWithPath: path))
        #expect(try CustomSourceFile.createTemplateIfMissing(at: path) == false)
        #expect(FileManager.default.contents(atPath: path) == Data("{\"sources\": []}".utf8))
        #expect(CustomSourceFile.stamp(of: path) != nil)
    }

    // MARK: - Good entries

    @Test("A manual entry keeps every field the file gave")
    func manualEntry() throws {
        let config = parse("""
        {"sources": [{"kind": "manual", "name": "SuperGrok", "plan": "SuperGrok", "cost": 30,
          "currency": "usd", "period": "Yearly", "renews": "2026-11-03", "url": "https://grok.com"}]}
        """)
        let source = try #require(config.sources.first)
        #expect(source.id.rawValue == "custom.supergrok")
        #expect(source.id.title == "SuperGrok")
        #expect(source.id.lane == .subscription)
        #expect(source.id.usageURL == URL(string: "https://grok.com"))
        #expect(source.kind == .manual(ManualPlan(
            plan: "SuperGrok", cost: 30, currency: "USD", period: .yearly,
            renews: DateComponents(year: 2026, month: 11, day: 3)
        )))
    }

    @Test("A manual entry defaults to monthly, USD, no cost")
    func manualDefaults() throws {
        let source = try #require(parse(#"{"sources": [{"kind": "manual", "name": "X", "renews": "2026-01-31"}]}"#).sources.first)
        guard case let .manual(plan) = source.kind else { Issue.record("not manual"); return }
        #expect(plan.period == .monthly)
        #expect(plan.currency == "USD")
        #expect(plan.cost == nil)
        #expect(plan.plan == nil)
    }

    @Test("A command array runs as given; a string runs under /bin/sh -c")
    func commandForms() throws {
        let config = parse("""
        {"sources": [
          {"kind": "command", "name": "Argv", "command": ["my-usage", "--json"], "lane": "apiKey"},
          {"kind": "command", "name": "Script", "command": "curl -s x | jq .", "timeout": 500}
        ]}
        """)
        #expect(config.sources.count == 2)
        #expect(config.sources[0].kind == .command(CommandSpec(executable: "my-usage", arguments: ["--json"], timeout: 10, plan: nil)))
        #expect(config.sources[0].id.lane == .apiKey)
        #expect(config.sources[0].id.glyph == "terminal")
        #expect(config.sources[1].kind == .command(CommandSpec(
            executable: "/bin/sh", arguments: ["-c", "curl -s x | jq ."], timeout: CustomSourceConfig.maxTimeout, plan: nil
        )))
    }

    @Test("Comment lines may sit anywhere in the JSON")
    func commentsInside() {
        let config = parse("""
        {
          // my plans
          "sources": [
            // the one I pay for
            {"kind": "manual", "name": "SuperGrok", "renews": "2026-11-03"}
          ]
        }
        """)
        #expect(config.providers.map(\.rawValue) == ["custom.supergrok"])
    }

    @Test("Names become stable slugs",
          arguments: [("SuperGrok", "supergrok"), ("X Premium+", "x-premium"), ("  Team  API ", "team-api"), ("+++", "source")])
    func slugs(name: String, slug: String) {
        #expect(CustomSourceConfig.slug(of: name) == slug)
    }

    @Test("A duplicate name gets its own key and a reason")
    func duplicateName() {
        let config = parse("""
        {"sources": [
          {"kind": "manual", "name": "Grok", "renews": "2026-11-03"},
          {"kind": "manual", "name": "grok", "renews": "2026-11-03"}
        ]}
        """)
        #expect(config.providers.map(\.rawValue) == ["custom.grok", "custom.grok-2"])
        #expect(reason(config.sources[1]) == "another source is already named grok")
    }

    // MARK: - Bad files

    @Test("Broken JSON is one row named for the file, with its line")
    func brokenJSON() throws {
        let config = parse("// header\n{\"sources\": [\n  {\"kind\": \"manual\",, }\n]}")
        let source = try #require(config.sources.first)
        #expect(config.sources.count == 1)
        #expect(source.id == .customConfig)
        #expect(source.id.title == "Custom sources")
        let said = try #require(reason(source))
        #expect(said.hasPrefix("sources.json: not valid JSON"))
        #expect(said.contains("line 3"), "the comment line still counts: \(said)")
    }

    @Test("A file with the wrong shape says what shape it wants",
          arguments: [
            ("[1, 2]", "sources.json: the top level must be an object with a \"sources\" list"),
            ("{\"source\": []}", "sources.json: no \"sources\" list"),
            ("{\"sources\": {}}", "sources.json: no \"sources\" list"),
          ])
    func wrongShape(text: String, expected: String) {
        let config = parse(text)
        #expect(config.providers == [.customConfig])
        #expect(reason(config.sources.first) == expected)
    }

    // MARK: - Bad entries

    @Test("A bad entry is its own row with a reason; the good ones still read",
          arguments: [
            (#"{"kind": "manual", "renews": "2026-11-03"}"#, #"entry 1 has no "name""#),
            (#""just a string""#, "entry 1 is not an object"),
            (#"{"name": "A", "renews": "2026-11-03"}"#, #""kind" must be "manual" or "command""#),
            (#"{"kind": "rss", "name": "A"}"#, #""kind" must be "manual" or "command""#),
            (#"{"kind": "manual", "name": "A"}"#, #""renews" is missing (a date like 2026-11-03)"#),
            (#"{"kind": "manual", "name": "A", "renews": "2026-02-30"}"#, #""renews" must be YYYY-MM-DD"#),
            (#"{"kind": "manual", "name": "A", "renews": "11/03/2026"}"#, #""renews" must be YYYY-MM-DD"#),
            (#"{"kind": "manual", "name": "A", "renews": "2026-11-03", "cost": -5}"#, #""cost" must be a number, 0 or more"#),
            (#"{"kind": "manual", "name": "A", "renews": "2026-11-03", "cost": "lots"}"#, #""cost" must be a number, 0 or more"#),
            (#"{"kind": "manual", "name": "A", "renews": "2026-11-03", "period": "weekly"}"#, #""period" must be "monthly" or "yearly""#),
            (#"{"kind": "manual", "name": "A", "renews": "2026-11-03", "lane": "prepaid"}"#, #""lane" must be "subscription" or "apiKey""#),
            (#"{"kind": "manual", "name": "A", "renews": "2026-11-03", "url": "grok.com"}"#, #""url" must be an http or https address"#),
            (#"{"kind": "command", "name": "A"}"#, #""command" is missing (an argument array or a string)"#),
            (#"{"kind": "command", "name": "A", "command": []}"#, #""command" is empty"#),
            (#"{"kind": "command", "name": "A", "command": "   "}"#, #""command" is empty"#),
            (#"{"kind": "command", "name": "A", "command": ["/bin/echo", 3]}"#, #"every word of "command" must be a string"#),
            (#"{"kind": "command", "name": "A", "command": ["/bin/echo"], "timeout": 0}"#, #""timeout" must be a number of seconds"#),
          ])
    func badEntry(entry: String, expected: String) {
        let config = parse(#"{"sources": [\#(entry), {"kind": "manual", "name": "Good", "renews": "2026-11-03"}]}"#)
        #expect(config.sources.count == 2)
        #expect(reason(config.sources[0]) == expected)
        if case .manual = config.sources[1].kind {} else { Issue.record("the good entry after a bad one must still parse") }
    }

    @Test("Leap day is a real date only in a leap year")
    func leapDay() {
        #expect(CustomSourceConfig.calendarDay("2028-02-29") == DateComponents(year: 2028, month: 2, day: 29))
        #expect(CustomSourceConfig.calendarDay("2027-02-29") == nil)
    }
}
