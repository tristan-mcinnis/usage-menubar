import XCTest
@testable import UsageBar
import UsageBarCore

/// The footnote under a provider's meters names the session reset and the
/// weekly one, the two times Baby Menu showed per window.
final class FootnoteTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_788_000_000)

    private func claude(_ meters: [Meter]) -> ProviderReading {
        ProviderReading(provider: .claude, state: .ok, plan: "max", meters: meters, readAt: now)
    }

    func testSessionAndWeekAreBothNamed() {
        let meters = [
            Meter(id: "session", label: "Session", percentUsed: 5, resetsAt: now.addingTimeInterval(3 * 3_600 + 27 * 60)),
            Meter(id: "weekly", label: "Weekly", percentUsed: 45, resetsAt: now.addingTimeInterval(2 * 86_400 + 3 * 3_600)),
            Meter(id: "weekly-scoped-fable", label: "Weekly · Fable", percentUsed: 17,
                  resetsAt: now.addingTimeInterval(2 * 86_400 + 3 * 3_600 + 20)),
        ]
        let text = MenuBarPanelView.footnote(for: claude(meters), shown: meters, now: now)
        XCTAssertEqual(text, "session resets 3h 27m · weekly 2d 3h")
    }

    func testAnUnusedWindowNamesNoReset() {
        let meters = [
            Meter(id: "session", label: "Session", percentUsed: 0, resetsAt: now.addingTimeInterval(3_600)),
            Meter(id: "weekly", label: "Weekly", percentUsed: 6, resetsAt: now.addingTimeInterval(5 * 86_400)),
        ]
        XCTAssertEqual(MenuBarPanelView.footnote(for: claude(meters), shown: meters, now: now), "weekly resets in 5d")
    }
}
