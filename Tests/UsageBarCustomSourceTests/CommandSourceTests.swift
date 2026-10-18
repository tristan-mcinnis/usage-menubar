import Foundation
import Testing
@testable import UsageBarCore

/// A command source: what its output turns into, what a failure says, and
/// that a failure keeps the last good numbers the way every other source does.
@Suite("Command sources")
struct CommandSourceTests {

    private let now = Date(timeIntervalSince1970: 1_792_000_000)

    // MARK: - Output

    @Test("The documented shape reads as one meter")
    func fullOutput() throws {
        let output = try CommandOutput.parse(#"{"percent": 42.5, "detail": "425 of 1000 credits", "resetsAt": "2026-11-01T00:00:00Z"}"#).get()
        #expect(output.percent == 42.5)
        #expect(output.detail == "425 of 1000 credits")
        #expect(output.resetsAt == ISO8601DateFormatter().date(from: "2026-11-01T00:00:00Z"))
    }

    @Test("Only percent is required; a string number counts; null is unknown, not zero")
    func minimalOutput() throws {
        #expect(try CommandOutput.parse(#"{"percent": 7}"#).get() == CommandOutput(percent: 7, detail: nil, resetsAt: nil))
        #expect(try CommandOutput.parse(#"{"percent": "12.5"}"#).get().percent == 12.5)
        #expect(try CommandOutput.parse(#"{"percent": null, "detail": "no data yet"}"#).get().percent == nil)
    }

    @Test("A script may log above its answer; the last line is read")
    func logLinesAbove() throws {
        let output = try CommandOutput.parse("fetching…\nlogged in as me\n{\"percent\": 63}\n").get()
        #expect(output.percent == 63)
    }

    @Test("Output Usage cannot trust is a reason, never a number",
          arguments: [
            ("", "printed nothing"),
            ("ok", "did not print a JSON object"),
            ("[42]", "did not print a JSON object"),
            (#"{"used": 42}"#, #"printed no "percent""#),
            (#"{"percent": "lots"}"#, #""percent" is not a number"#),
            (#"{"percent": 140}"#, #""percent" 140 is outside 0 to 100"#),
            (#"{"percent": -3}"#, #""percent" -3 is outside 0 to 100"#),
            (#"{"percent": 5, "resetsAt": "tomorrow"}"#, #""resetsAt" is not an ISO 8601 date"#),
          ])
    func badOutput(stdout: String, reason: String) {
        #expect(throws: CommandOutput.ParseFailure(reason)) { try CommandOutput.parse(stdout).get() }
    }

    // MARK: - Running

    private func source(_ command: String, extra: String = "") throws -> CustomSource {
        let config = CustomSourceConfig.parse(Data(#"{"sources": [{"kind": "command", "name": "Team", "plan": "team", "command": \#(command)\#(extra)}]}"#.utf8))
        return try #require(config.sources.first)
    }

    private func read(_ source: CustomSource, exit: Int32 = 0, stdout: String = "", stderr: String = "",
                      seen: Recorder? = nil) -> ProviderReading {
        CustomSourceReader.read(
            source, now: now, home: "/tmp/home",
            isExecutable: { $0 == "/bin/sh" || $0 == "/opt/homebrew/bin/my-usage" || $0 == "/tmp/home/bin/x" },
            run: { executable, arguments, timeout in
                seen?.record(executable, arguments, timeout)
                return CommandResult(exitCode: exit, stdout: stdout, stderr: stderr)
            }
        )
    }

    @Test("A good run is an ok reading with the command's percent, reset and detail")
    func goodRun() throws {
        let recorder = Recorder()
        let reading = read(try source(#"["my-usage", "--json"]"#, extra: #", "timeout": 5"#),
                           stdout: #"{"percent": 37, "detail": "370 of 1000", "resetsAt": "2026-11-01T00:00:00Z"}"#,
                           seen: recorder)
        #expect(recorder.calls == [Recorder.Call(executable: "/opt/homebrew/bin/my-usage", arguments: ["--json"], timeout: 5)])
        #expect(reading.state == .ok)
        #expect(reading.plan == "team")
        #expect(reading.readAt == now)
        let meter = try #require(reading.meters.first)
        #expect(meter.percentUsed == 37)
        #expect(meter.note == "370 of 1000")
        #expect(meter.resetsAt != nil)
    }

    @Test("A string command runs under /bin/sh -c, unchanged")
    func shellString() throws {
        let recorder = Recorder()
        _ = read(try source(#""echo '{\"percent\": 1}'""#), stdout: #"{"percent": 1}"#, seen: recorder)
        #expect(recorder.calls.first?.executable == "/bin/sh")
        #expect(recorder.calls.first?.arguments == ["-c", #"echo '{"percent": 1}'"#])
    }

    @Test("A failed run says why in the row",
          arguments: [
            (Int32(2), "", "my-usage: token expired\nmore detail", "my-usage: token expired"),
            (Int32(1), "", "", "exited 1"),
            (Int32(-1), "", "/opt/homebrew/bin/my-usage: timed out after 5s", "timed out after 5s"),
            (Int32(0), "nope", "", "did not print a JSON object"),
          ])
    func failedRun(exit: Int32, stdout: String, stderr: String, reason: String) throws {
        let reading = read(try source(#"["my-usage"]"#), exit: exit, stdout: stdout, stderr: stderr)
        #expect(reading.state == .error(reason))
        #expect(reading.readAt == nil)
        #expect(reading.attemptedAt == now)
    }

    @Test("A program that is not there says so, and nothing runs")
    func missingProgram() throws {
        let recorder = Recorder()
        let reading = read(try source(#"["not-installed"]"#), seen: recorder)
        #expect(reading.state == .error("not-installed not found"))
        #expect(recorder.calls.isEmpty)
    }

    @Test("Bare names are looked up on the usual install paths; ~/ is the home folder")
    func resolve() {
        let exists: (String) -> Bool = { $0 == "/opt/homebrew/bin/my-usage" || $0 == "/tmp/home/bin/x" }
        #expect(CustomSourceReader.resolve("my-usage", home: "/tmp/home", isExecutable: exists) == "/opt/homebrew/bin/my-usage")
        #expect(CustomSourceReader.resolve("~/bin/x", home: "/tmp/home", isExecutable: exists) == "/tmp/home/bin/x")
        #expect(CustomSourceReader.resolve("/usr/local/bin/my-usage", home: "/tmp/home", isExecutable: exists) == nil)
    }

    @Test("A real command through Subprocess, start to finish")
    func realSubprocess() throws {
        let reading = CustomSourceReader.read(try source(#"["/bin/echo", "{\"percent\": 12}"]"#), now: now)
        #expect(reading.state == .ok)
        #expect(reading.meters.first?.percentUsed == 12)
    }

    @Test("A command that outlives its timeout is stopped and reported")
    func realTimeout() throws {
        let reading = CustomSourceReader.read(try source(#"["/bin/sleep", "5"]"#, extra: #", "timeout": 0.2"#), now: now)
        #expect(reading.state == .error("timed out after 1s"), "a timeout under a second is raised to one")
    }

    // MARK: - Last good

    @Test("A failure keeps the last good meter, marked stale, as every source does")
    func failureKeepsLastGood() throws {
        let team = try source(#"["my-usage"]"#)
        let good = read(team, stdout: #"{"percent": 37}"#)
        let failed = read(team, exit: 1, stderr: "offline")
        let snapshot = UsageSnapshot.pending.applying([good]).applying([failed])
        let row = try #require(snapshot.reading(team.id))
        #expect(row.state == .error("offline"))
        #expect(row.meters.first?.percentUsed == 37)
        #expect(row.staleNote(now: now) != nil)
        #expect(row.provider.title == "Team")
    }

    @Test("Last good numbers survive a relaunch, and a source taken out of the file is not restored")
    func archive() throws {
        let team = try source(#"["my-usage"]"#)
        let snapshot = UsageSnapshot.pending.reconciled(with: ProviderID.builtIn + [team.id])
            .applying([read(team, stdout: #"{"percent": 37}"#)])
        var store = ReadingStore()
        store.record(snapshot)
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("readings-\(UUID().uuidString).json").path
        try store.save(to: path)

        let restored = ReadingStore.load(from: path).snapshot(providers: ProviderID.builtIn + [team.id])
        let row = try #require(restored.reading(team.id))
        #expect(row.state == .stale)
        #expect(row.meters.first?.percentUsed == 37)
        #expect(row.provider.title == "Team", "the title comes from the config, not the archive")

        let removed = ReadingStore.load(from: path).snapshot(providers: ProviderID.builtIn)
        #expect(removed.reading(team.id) == nil)
        #expect(removed.readings.count == ProviderID.builtIn.count)
    }

    @Test("A key is encoded as its plain string, the shape readings.json always had")
    func keyEncoding() throws {
        let data = try JSONEncoder().encode([ProviderID.claude, ProviderID.custom(slug: "x", display: CustomDisplay(title: "X", lane: .apiKey, glyph: "terminal"))])
        #expect(String(decoding: data, as: UTF8.self) == #"["claude","custom.x"]"#)
        let decoded = try JSONDecoder().decode([ProviderID].self, from: data)
        #expect(decoded == [.claude, ProviderID(rawValue: "custom.x")!])
        #expect(decoded[1].title == "x")
    }

    // MARK: - The panel's view of a bad config

    @Test("A broken config file is a red row named for the file, and the header names it")
    func brokenConfigRow() throws {
        let config = CustomSourceConfig.parse(Data("{ not json".utf8))
        var samples = SampleStore()
        let readings = config.providers.map {
            ProviderReader.read($0, custom: config, tools: ToolPaths(agy: "/nonexistent/agy", home: "/nonexistent"), samples: &samples, now: now)
        }
        let claude = ProviderReading(provider: .claude, state: .ok, meters: [Meter(id: "session", label: "Session", percentUsed: 10)], readAt: now, attemptedAt: now)
        let snapshot = UsageSnapshot(readings: [claude] + readings, readAt: now)
        let row = try #require(snapshot.reading(.customConfig))
        guard case let .error(reason) = row.state else { Issue.record("expected an error row"); return }
        #expect(reason.hasPrefix("sources.json: not valid JSON"))
        #expect(snapshot.shown.count == 2, "an error is shown, not hidden like a source that is not set up")
        #expect(snapshot.headline(now: now).health == .failing)
        #expect(snapshot.headline(now: now).text.contains("Custom sources"))
    }

    @Test("Reconciling follows the config: renamed titles, removed sources, new ones pending, in file order")
    func reconcile() {
        let a = ProviderID.custom(slug: "a", display: CustomDisplay(title: "A", lane: .subscription, glyph: "calendar"))
        let b = ProviderID.custom(slug: "b", display: CustomDisplay(title: "B", lane: .subscription, glyph: "calendar"))
        let aRenamed = ProviderID.custom(slug: "a", display: CustomDisplay(title: "A2", lane: .apiKey, glyph: "terminal"))
        let start = UsageSnapshot(readings: [ProviderReading(provider: a, state: .ok), ProviderReading(provider: b, state: .ok)], readAt: now)
        let next = start.reconciled(with: [.claude, aRenamed])
        #expect(next.readings.map(\.provider.rawValue) == ["claude", "custom.a"])
        #expect(next.readings[0].state == .pending)
        #expect(next.readings[1].state == .ok)
        #expect(next.readings[1].provider.title == "A2")
        #expect(next.readings[1].provider.lane == .apiKey)
    }
}

/// What the fake runner was asked to run.
final class Recorder: @unchecked Sendable {
    // Guarded by `lock`; the runner may be called from any queue.
    private let lock = NSLock()
    private var stored: [Call] = []

    struct Call: Equatable {
        let executable: String
        let arguments: [String]
        let timeout: TimeInterval
    }

    var calls: [Call] { lock.withLock { stored } }

    func record(_ executable: String, _ arguments: [String], _ timeout: TimeInterval) {
        lock.withLock { stored.append(Call(executable: executable, arguments: arguments, timeout: timeout)) }
    }
}
