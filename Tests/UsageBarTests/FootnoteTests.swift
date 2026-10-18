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

    /// A custom source's own words follow the reset: a manual plan's renewal
    /// and price, or a command's detail after its reset.
    func testACustomSourceNoteIsTheFootnote() {
        let manual = [Meter(id: "period", label: "Billing period", percentUsed: 55, note: "renews in 14 days · $30/mo")]
        XCTAssertEqual(MenuBarPanelView.footnote(for: claude(manual), shown: manual, now: now), "renews in 14 days · $30/mo")
        let command = [Meter(id: "command", label: "Usage", percentUsed: 37,
                             resetsAt: now.addingTimeInterval(2 * 86_400), note: "370 of 1000 credits")]
        XCTAssertEqual(MenuBarPanelView.footnote(for: claude(command), shown: command, now: now),
                       "usage resets in 2d · 370 of 1000 credits")
    }
}
