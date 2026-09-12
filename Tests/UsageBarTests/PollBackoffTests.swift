import XCTest
@testable import UsageBar
import UsageBarCore

/// The idle backoff: what the poll interval becomes when nobody opens the
/// panel, what opening it does, and the tolerance the timer carries. The
/// decision is a pure function of the configured interval and the idle time,
/// so nothing here waits on a clock, and no test here reads a provider.
@MainActor
final class PollBackoffTests: XCTestCase {

    private var refreshCount = 0

    private func makeModel(now: @escaping () -> Date = { Date() }) -> PanelModel {
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("PollBackoffTests-\(UUID().uuidString)")
        let model = PanelModel(
            defaults: UserDefaults(suiteName: "PollBackoffTests-\(UUID().uuidString)")!,
            samplesPath: temp.appendingPathComponent("samples.json").path,
            readingsPath: temp.appendingPathComponent("readings.json").path,
            retriesPath: temp.appendingPathComponent("retries.json").path
        )
        model.now = now
        // Opening a panel must never read a provider in a test.
        model.backgroundRefresh = { [weak self] in self?.refreshCount += 1 }
        return model
    }

    // MARK: - The pure decision

    func testTheConfiguredIntervalStandsUntilTheIdleThreshold() {
        XCTAssertEqual(PanelModel.backedOffInterval(base: 300, idleFor: 0), 300)
        XCTAssertEqual(PanelModel.backedOffInterval(base: 300, idleFor: 60 * 60), 300)
    }

    func testTheIntervalDoublesForEveryIdleThresholdPassed() {
        XCTAssertEqual(PanelModel.backedOffInterval(base: 300, idleFor: PanelModel.idleThreshold), 600)
        XCTAssertEqual(PanelModel.backedOffInterval(base: 300, idleFor: 2 * PanelModel.idleThreshold), 1200)
    }

    func testTheIntervalStopsAtTheCeiling() {
        XCTAssertEqual(
            PanelModel.backedOffInterval(base: 300, idleFor: 24 * 60 * 60),
            PanelModel.idlePollCeiling
        )
    }

    /// A configured interval longer than the ceiling is the user's choice, so
    /// the backoff must never shorten it.
    func testAConfiguredIntervalPastTheCeilingIsNeverShortened() {
        XCTAssertEqual(PanelModel.backedOffInterval(base: 3600, idleFor: 24 * 60 * 60), 3600)
    }

    func testAnUnreadSnapshotCountsAsStale() {
        XCTAssertTrue(PanelModel.isStale(age: nil, base: 300))
    }

    func testASnapshotOlderThanOnePollCountsAsStale() {
        XCTAssertFalse(PanelModel.isStale(age: 299, base: 300))
        XCTAssertTrue(PanelModel.isStale(age: 301, base: 300))
    }

    // MARK: - The model

    func testALongUnopenedPanelLengthensTheInterval() {
        let launch = Date()
        let model = makeModel(now: { launch.addingTimeInterval(48 * 60 * 60) })
        XCTAssertEqual(model.pollInterval, PanelModel.idlePollCeiling)
    }

    func testOpeningThePanelRestoresTheNormalCadence() {
        let launch = Date()
        var reading = launch.addingTimeInterval(48 * 60 * 60)
        let model = makeModel(now: { reading })
        XCTAssertEqual(model.pollInterval, PanelModel.idlePollCeiling)

        model.panelOpened()
        XCTAssertEqual(model.pollInterval, model.baseInterval)

        // Still the normal cadence an hour after that open.
        reading = reading.addingTimeInterval(60 * 60)
        XCTAssertEqual(model.pollInterval, model.baseInterval)
    }

    func testTheTimerCarriesTolerance() throws {
        let model = makeModel()
        model.schedulePoll()
        let scheduled = try XCTUnwrap(model.scheduledPoll)
        XCTAssertEqual(scheduled.interval, model.pollInterval, accuracy: 0.001)
        XCTAssertEqual(
            scheduled.tolerance,
            model.pollInterval * PanelModel.pollToleranceFraction,
            accuracy: 0.001
        )
        XCTAssertGreaterThan(scheduled.tolerance, 0)
    }

    func testOpeningAStalePanelKicksABackgroundRefresh() {
        let model = makeModel()
        model.override(snapshot: UsageSnapshot(readings: [], readAt: Date(timeIntervalSinceNow: -3600)))
        model.panelOpened()
        XCTAssertEqual(refreshCount, 1)
    }

    /// Opening is instant and free: numbers younger than one poll are as fresh
    /// as they ever get, so an open on top of them reads nothing.
    func testOpeningAFreshPanelReadsNothing() {
        let model = makeModel()
        model.override(snapshot: UsageSnapshot(readings: [], readAt: Date()))
        model.panelOpened()
        XCTAssertEqual(refreshCount, 0)
    }
}
