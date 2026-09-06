import Foundation
import UsageBarCore

/// `usage-bar --doctor`: read every source the panel reads and print what
/// came back, then exit. A menu-bar app that silently shows "Reading…"
/// forever is exactly the failure this catches.
///
/// Read-only, and it prints no secret: a credential is reported as found or
/// not, never by value. Output follows the house terminal style
/// (design-system/DESIGN.md, "Terminal surfaces"): one status line first,
/// then uppercase sections with key and value rows at two spaces of indent.
enum Doctor {

    /// 0 when every source read, 1 when any did not.
    static func run(tools: ToolPaths = .installed) -> Int32 {
        var samples = SampleStore.load(from: SampleStore.defaultPath())
        let now = Date()
        var readings: [ProviderReading] = []
        for provider in ProviderID.allCases {
            readings.append(ProviderReader.read(provider, tools: tools, samples: &samples, now: now))
        }
        let snapshot = UsageSnapshot(readings: readings, readAt: now)

        // The dot is the only colour a house CLI prints, and this one is
        // never styled: `--doctor` is read off a pipe as often as off a
        // terminal, and the word beside it carries the meaning anyway.
        print("● \(snapshot.headline.text)")

        for lane in Lane.allCases {
            print("")
            print(lane.title.uppercased())
            var rows: [(String, String)] = []
            for reading in snapshot.readings(in: lane) {
                switch reading.state {
                case .ok:
                    let plan = reading.plan.map { " · \(Format.planTitle($0))" } ?? ""
                    rows.append((reading.provider.title, "ok\(plan) · \(reading.meters.count) meters"))
                    for meter in reading.meters {
                        let detail = meter.detail(now: now).map { " · \($0)" } ?? ""
                        rows.append(("  " + meter.label, meter.value() + detail))
                    }
                case .stale:
                    let age = reading.shownAge(now: now).map { " · \($0)" } ?? ""
                    rows.append((reading.provider.title, "restored\(age)"))
                case let .signIn(reason):
                    rows.append((reading.provider.title, "SIGN IN: \(reason)"))
                case let .error(reason):
                    rows.append((reading.provider.title, "FAILED: \(reason)"))
                case let .rateLimited(reason):
                    rows.append((reading.provider.title, "RATE LIMITED: \(reason)"))
                case .pending:
                    rows.append((reading.provider.title, "not read"))
                }
            }
            block(rows)
        }

        print("")
        print("STORE")
        block([
            ("samples", SampleStore.defaultPath()),
            ("agy", tools.exists(tools.agy) ? tools.agy : "NOT INSTALLED (\(tools.agy))"),
            ("codex auth", FileManager.default.fileExists(atPath: CodexCredential.path(tools: tools)) ? "present" : "absent"),
        ])

        return readings.allSatisfy(\.state.isOK) ? 0 : 1
    }

    private static func block(_ pairs: [(String, String)]) {
        let width = (pairs.map(\.0.count).max() ?? 0) + 2
        for (key, value) in pairs {
            print("  " + key + String(repeating: " ", count: max(1, width - key.count)) + value)
        }
    }
}
