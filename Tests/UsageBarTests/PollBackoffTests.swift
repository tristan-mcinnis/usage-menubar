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
        XCTAssertEqual(PanelModel.backedOffInterval(base: 60, idleFor: PanelModel.idleThreshold), 120)
        XCTAssertEqual(PanelModel.backedOffInterval(base: 60, idleFor: 2 * PanelModel.idleThreshold), 240)
        XCTAssertEqual(PanelModel.backedOffInterval(base: 300, idleFor: PanelModel.idleThreshold), 600)
    }

    /// acceptance.sh (T4) wants every number under 15 minutes old. The
    /// longest backed-off gap, stretched by the timer's tolerance, plus a
    /// minute for the read itself, must stay under that.
    func testTheCeilingKeepsEveryNumberUnderFifteenMinutesOld() {
        let worst = PanelModel.idlePollCeiling * (1 + PanelModel.pollToleranceFraction) + 60
        XCTAssertLessThan(worst, 15 * 60)
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

    /// The repeating timer keeps the interval it was armed with. A fire after
    /// the idle threshold must re-arm it at the backed-off interval, or an
    /// unopened panel never backs off at all.
    func testATimerFireAfterTheIdleThresholdReArmsTheLongerInterval() throws {
        let launch = Date()
        var clock = launch
        let model = makeModel(now: { clock })
        model.schedulePoll()
        XCTAssertEqual(try XCTUnwrap(model.scheduledPoll).interval, model.baseInterval, accuracy: 0.001)

        clock = launch.addingTimeInterval(PanelModel.idleThreshold + 1)
        model.pollTimerFired()
        XCTAssertEqual(refreshCount, 1)
        XCTAssertEqual(try XCTUnwrap(model.scheduledPoll).interval, PanelModel.idlePollCeiling, accuracy: 0.001)
    }

    func testATimerFireInsideTheThresholdKeepsTheTimer() throws {
        let model = makeModel()
        model.schedulePoll()
        let before = try XCTUnwrap(model.scheduledPoll).interval
        model.pollTimerFired()
        XCTAssertEqual(refreshCount, 1)
        XCTAssertEqual(try XCTUnwrap(model.scheduledPoll).interval, before, accuracy: 0.001)
    }

    /// On wake the overdue timer may already be reading before the network is
    /// back. The wake read waits for the network, then runs after that read
    /// instead of being dropped.
    func testTheWakeReadWaitsForTheNetworkAndQueuesBehindARunningRead() async {
        let model = makeModel()
        let (gate, open) = AsyncStream<Void>.makeStream()
        model.waitForNetwork = { for await _ in gate { return } }
        model.isReading = true              // the overdue timer's read, in flight

        model.systemDidWake()
        await Task.yield()
        XCTAssertEqual(refreshCount, 0, "no read before the network is back")

        open.yield()
        for _ in 0..<50 where refreshCount == 0 { await Task.yield() }
        XCTAssertEqual(refreshCount, 0, "a read is running: the wake read waits for it, never doubles it")

        model.readFinished()
        XCTAssertEqual(refreshCount, 1, "the queued wake read runs once the first read ends")
        model.readFinished()
        XCTAssertEqual(refreshCount, 1, "and only once")
    }

    func testAWakeWithNoReadRunningReadsOnceTheNetworkIsBack() async {
        let model = makeModel()
        model.waitForNetwork = {}
        model.systemDidWake()
        for _ in 0..<50 where refreshCount == 0 { await Task.yield() }
        XCTAssertEqual(refreshCount, 1)
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
