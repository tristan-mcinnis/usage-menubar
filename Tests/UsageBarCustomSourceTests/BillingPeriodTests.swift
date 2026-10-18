import Foundation
import Testing
@testable import UsageBarCore

/// The billing period a manual plan is in: counted from the one renewal date
/// the user wrote, rolled forward (or back) whole periods, with month ends
/// and leap years handled by the calendar rather than by adding 30 days.
@Suite("Billing period math")
struct BillingPeriodTests {

    private static let utc: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    private func day(_ y: Int, _ m: Int, _ d: Int, hour: Int = 0) -> Date {
        Self.utc.date(from: DateComponents(year: y, month: m, day: d, hour: hour))!
    }

    private func period(anchor: (Int, Int, Int), months: Int = 1, now: Date) throws -> BillingMath.Period {
        try #require(BillingMath.period(
            anchor: DateComponents(year: anchor.0, month: anchor.1, day: anchor.2),
            months: months, containing: now, calendar: Self.utc
        ))
    }

    @Test("A renewal date in the past rolls forward to the period holding now")
    func rollsForward() throws {
        let found = try period(anchor: (2025, 3, 3), now: day(2026, 10, 18, hour: 9))
        #expect(found.start == day(2026, 10, 3))
        #expect(found.end == day(2026, 11, 3))
    }

    @Test("A renewal date in the future rolls back to the period holding now")
    func rollsBack() throws {
        let found = try period(anchor: (2026, 11, 3), now: day(2026, 10, 18, hour: 9))
        #expect(found.start == day(2026, 10, 3))
        #expect(found.end == day(2026, 11, 3))
    }

    @Test("A plan on the 31st renews on Feb 28, then on Mar 31 again, not the 28th")
    func monthEndDoesNotDrift() throws {
        let february = try period(anchor: (2026, 1, 31), now: day(2026, 2, 15))
        #expect(february.start == day(2026, 1, 31))
        #expect(february.end == day(2026, 2, 28))
        let march = try period(anchor: (2026, 1, 31), now: day(2026, 3, 5))
        #expect(march.start == day(2026, 2, 28))
        #expect(march.end == day(2026, 3, 31))
        let april = try period(anchor: (2026, 1, 31), now: day(2026, 4, 10))
        #expect(april.start == day(2026, 3, 31))
        #expect(april.end == day(2026, 4, 30))
    }

    @Test("In a leap year the 31st renews on Feb 29")
    func leapFebruary() throws {
        let found = try period(anchor: (2024, 1, 31), now: day(2024, 2, 10))
        #expect(found.end == day(2024, 2, 29))
    }

    @Test("A yearly plan from Feb 29 renews Feb 28 in common years and Feb 29 in leap years")
    func leapDayYearly() throws {
        let common = try period(anchor: (2024, 2, 29), months: 12, now: day(2025, 3, 1))
        #expect(common.start == day(2025, 2, 28))
        #expect(common.end == day(2026, 2, 28))
        let intoLeap = try period(anchor: (2024, 2, 29), months: 12, now: day(2027, 6, 1))
        #expect(intoLeap.start == day(2027, 2, 28))
        #expect(intoLeap.end == day(2028, 2, 29))
    }

    @Test("At the renewal instant the new period has begun")
    func boundaryStartsNewPeriod() throws {
        let found = try period(anchor: (2026, 1, 15), now: day(2026, 5, 15))
        #expect(found.start == day(2026, 5, 15))
        #expect(BillingMath.percentElapsed(found, now: day(2026, 5, 15)) == 0)
    }

    @Test("Percent elapsed runs from 0 at the start to 100 at the end")
    func percentElapsed() throws {
        // November has 30 days, so noon on the 16th is exactly half way.
        let found = try period(anchor: (2026, 11, 1), now: day(2026, 11, 16, hour: 0))
        #expect(BillingMath.percentElapsed(found, now: found.start) == 0)
        #expect(BillingMath.percentElapsed(found, now: day(2026, 11, 16)) == 50)
        #expect(BillingMath.percentElapsed(found, now: found.end) == 100)
    }

    @Test("Days left counts calendar days to the renewal day")
    func daysLeft() throws {
        let found = try period(anchor: (2026, 11, 3), now: day(2026, 10, 18, hour: 23))
        #expect(BillingMath.daysLeft(found, now: day(2026, 10, 18, hour: 23), calendar: Self.utc) == 16)
        #expect(BillingMath.daysLeft(found, now: day(2026, 11, 2, hour: 8), calendar: Self.utc) == 1)
    }

    @Test("The renewal phrase", arguments: [(0, "renews today"), (1, "renews in 1 day"), (16, "renews in 16 days")])
    func phrase(days: Int, expected: String) {
        #expect(BillingMath.renewalPhrase(daysLeft: days) == expected)
    }

    // MARK: - The manual row end to end

    private func read(_ entry: String, now: Date) throws -> ProviderReading {
        let config = CustomSourceConfig.parse(Data(#"{"sources": [\#(entry)]}"#.utf8))
        let source = try #require(config.sources.first)
        return CustomSourceReader.read(source, now: now, calendar: Self.utc)
    }

    @Test("A monthly plan reads as percent of the period, with its renewal and price")
    func manualMonthly() throws {
        let now = day(2026, 10, 18, hour: 12)
        let reading = try read(#"{"kind": "manual", "name": "SuperGrok", "plan": "SuperGrok", "cost": 30, "renews": "2026-11-03"}"#, now: now)
        #expect(reading.state == .ok)
        #expect(reading.plan == "SuperGrok")
        #expect(reading.readAt == now)
        let meter = try #require(reading.meters.first)
        #expect(meter.label == "Billing period")
        #expect(meter.note == "renews in 16 days · $30/mo")
        // Oct 3 to Nov 3 is 31 days; noon on Oct 18 is 15.5 days in.
        #expect(abs((meter.percentUsed ?? 0) - 15.5 / 31 * 100) < 0.0001)
        #expect(meter.detail(now: now) == "renews in 16 days · $30/mo")
    }

    @Test("A yearly plan says /yr, cents stay when the price has them, and no cost says only the renewal")
    func manualPriceForms() throws {
        let now = day(2026, 10, 18)
        let yearly = try read(#"{"kind": "manual", "name": "X", "cost": 84, "period": "yearly", "renews": "2026-03-01"}"#, now: now)
        #expect(yearly.meters.first?.note == "renews in 134 days · $84/yr")
        let cents = try read(#"{"kind": "manual", "name": "X", "cost": 9.99, "currency": "EUR", "renews": "2026-11-03"}"#, now: now)
        #expect(cents.meters.first?.note == "renews in 16 days · €9.99/mo")
        let free = try read(#"{"kind": "manual", "name": "X", "renews": "2026-11-03"}"#, now: now)
        #expect(free.meters.first?.note == "renews in 16 days")
    }

    @Test("The renewal rolls forward on its own: next month, the same entry is a fresh period")
    func manualRollsOver() throws {
        let entry = #"{"kind": "manual", "name": "X", "renews": "2026-11-03"}"#
        let before = try read(entry, now: day(2026, 11, 2, hour: 12))
        let after = try read(entry, now: day(2026, 11, 3, hour: 12))
        #expect((before.meters.first?.percentUsed ?? 0) > 95)
        #expect((after.meters.first?.percentUsed ?? 100) < 5)
        #expect(after.meters.first?.note == "renews in 30 days")
    }
}
