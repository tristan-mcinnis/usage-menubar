import AppKit
import Combine
import Foundation
import UsageBarCore

/// One selectable row in the panel: a provider, or an action.
struct PanelAction: Identifiable {
    let id: String
    let glyph: String
    let title: String
    /// The chord drawn as key caps on the right. Empty draws none.
    var chord: String = ""
    var isEnabled: Bool = true
    /// A rarer action, drawn at reduced ink in the second group.
    var isQuiet: Bool = false
    var run: () -> Void = {}
}

/// A one-line answer under the header: what just happened, with a dot.
struct Confirmation: Equatable {
    let ok: Bool
    let text: String
}

/// The panel's live state and every action behind it.
///
/// Usage owns no credential and no account. Every reading is a call to a
/// source that already exists on this Mac: the Claude Code keychain item, the
/// Codex auth file, the agy CLI, and the two key files. All of that runs off
/// the main thread; the panel is never blocked on a read.
@MainActor
final class PanelModel: ObservableObject {

    // MARK: Published state

    @Published private(set) var snapshot: UsageSnapshot
    @Published private(set) var isReading = false
    @Published var selection: Int = 0
    @Published var confirmation: Confirmation?

    // MARK: Collaborators

    private let tools: ToolPaths
    private let defaults: UserDefaults
    private let samplesPath: String
    private let readingsPath: String
    private let retriesPath: String
    private let work = DispatchQueue(label: "com.tristan.usage-menubar.work", qos: .userInitiated)

    private var pollTimer: Timer?
    /// Bumped on every poll so a slow read cannot overwrite a newer one.
    private var generation = 0

    /// When the panel was last opened. Launch counts as an open, so a Mac
    /// that has just started polls at the normal rate until the first idle
    /// threshold passes.
    private var lastOpenedAt = Date()
    /// The clock, injected so the idle backoff is tested without waiting.
    var now: () -> Date = { Date() }
    /// The read a stale open kicks off behind the panel. It is the ordinary
    /// poll; a test replaces it so that opening a panel reads no provider.
    lazy var backgroundRefresh: () -> Void = { [weak self] in self?.poll() }

    /// Raised while the panel is on screen.
    var isPanelOpen = false

    var onOpenSettings: () -> Void = {}
    var onQuit: () -> Void = {}
    var onClose: () -> Void = {}
    /// Fired whenever the snapshot changes, so the status item can repaint.
    var onSnapshotChange: (UsageSnapshot) -> Void = { _ in }

    static let pollIntervalKey = "pollIntervalSeconds"
    /// Which provider's session window the status item shows, or "none".
    static let headlineProviderKey = "headlineProvider"
    /// How many meter rows one provider may take before the rest fold.
    static let meterRowLimit = 4
    /// How long the panel can go unopened before the poll starts stretching.
    /// Two hours is longer than a walk away from the desk and shorter than a
    /// morning, so numbers nobody has looked at since breakfast stop costing
    /// five network calls and a CLI launch every five minutes.
    static let idleThreshold: TimeInterval = 2 * 60 * 60
    /// The longest gap between polls, however long nobody looks. Half an hour
    /// keeps the backoff bounded: at worst one open finds the numbers half an
    /// hour old, says so, and reads again behind the panel.
    static let idlePollCeiling: TimeInterval = 30 * 60
    /// The share of the interval macOS may slide a poll wakeup by, so it can
    /// batch this timer with others instead of waking the CPU for it alone.
    /// A background poll owes nobody a particular second.
    static let pollToleranceFraction = 0.15

    init(
        tools: ToolPaths = .installed,
        defaults: UserDefaults = .standard,
        samplesPath: String = SampleStore.defaultPath(),
        readingsPath: String = ReadingStore.defaultPath(),
        retriesPath: String = RetryStore.defaultPath()
    ) {
        self.tools = tools
        self.defaults = defaults
        self.samplesPath = samplesPath
        self.readingsPath = readingsPath
        self.retriesPath = retriesPath
        // Show the last good numbers immediately, so opening the panel before
        // the first poll lands is not a wall of "Reading…". A provider with no
        // stored good reading stays pending until a poll reads it.
        self.snapshot = ReadingStore.load(from: readingsPath).snapshot()
    }

    // MARK: - Rows

    /// The provider rows, in panel order. Return opens the provider's own
    /// usage page, which is the one thing a number on a panel cannot show.
    var providerActions: [PanelAction] {
        snapshot.shown.map { reading in
            PanelAction(id: reading.provider.rawValue, glyph: reading.provider.glyph, title: reading.provider.title) {
                [weak self] in self?.openUsagePage(reading.provider)
            }
        }
    }

    var moreActions: [PanelAction] {
        [
            PanelAction(
                id: "refresh",
                glyph: "arrow.clockwise",
                title: isReading ? "Reading…" : "Refresh now",
                chord: "⌘R",
                isEnabled: !isReading,
                isQuiet: true
            ) { [weak self] in self?.refresh() },
        ]
    }

    /// Every row the keyboard walks, in order: the providers, the rarer
    /// group, then the two footer actions.
    var selectableActions: [PanelAction] {
        providerActions + moreActions + [
            PanelAction(id: "settings", glyph: "gearshape", title: "Settings", chord: "⌘,") {
                [weak self] in self?.onOpenSettings()
            },
            PanelAction(id: "quit", glyph: "power", title: "Quit", chord: "⌘Q") {
                [weak self] in self?.onQuit()
            },
        ]
    }

    var footerSelectionBase: Int { providerActions.count + moreActions.count }

    /// The keyboard index of a provider's row.
    func selectionIndex(of provider: ProviderID) -> Int {
        snapshot.shown.firstIndex { $0.provider == provider } ?? 0
    }

    func moveSelection(by delta: Int) {
        let rows = selectableActions
        guard !rows.isEmpty else { return }
        var next = selection
        for _ in 0..<rows.count {
            next = (next + delta + rows.count) % rows.count
            if rows[next].isEnabled { break }
        }
        selection = next
    }

    func runSelection() {
        let rows = selectableActions
        guard rows.indices.contains(selection), rows[selection].isEnabled else { return }
        rows[selection].run()
    }

    func escape() {
        onClose()
    }

    // MARK: - Actions

    /// Open the provider's usage page. User-initiated, so taking the
    /// foreground is what was asked for.
    func openUsagePage(_ provider: ProviderID) {
        onClose()
        NSWorkspace.shared.open(provider.usageURL)
    }

    func refresh() {
        confirmation = nil
        poll()
    }

    /// Refresh one provider, from the row's context menu. It reads only that
    /// provider, respects a persisted server rate-limit backoff, and on an
    /// explicit user ask clears the cached Claude credential so a denied one
    /// is re-read (reauthorized) rather than answered from cache.
    func refresh(_ provider: ProviderID) {
        guard !isReading else { return }
        isReading = true
        generation += 1
        let gen = self.generation
        let base = self.snapshot
        work.async { [tools, samplesPath, retriesPath, readingsPath] in
            var samples = SampleStore.load(from: samplesPath)
            var retries = RetryStore.load(from: retriesPath)
            let now = Date()
            guard retries.shouldAttempt(provider, now: now) else {
                let wait = retries.nextAllowedAt(provider, now: now)
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.generation == gen else { return }
                    self.isReading = false
                    self.confirmation = Confirmation(
                        ok: false,
                        text: "\(provider.title) is rate limited — retry \(wait.map { Format.countdown(to: $0, from: now) } ?? "later")"
                    )
                }
                return
            }
            // Explicit user intent: forget a cached (possibly denied) credential.
            if provider == .claude { ClaudeCredential.resetCache() }
            let reading = ProviderReader.read(provider, tools: tools, samples: &samples, now: now)
            if case .rateLimited = reading.state {
                retries.backoff(provider, retryAfterSeconds: reading.retryAfterSeconds, now: now)
            } else if reading.state.isOK {
                retries.clear(provider)
            }
            try? samples.save(to: samplesPath)
            try? retries.save(to: retriesPath)
            let finalSnapshot = base.applying([reading])
            var store = ReadingStore()
            store.record(finalSnapshot)
            try? store.save(to: readingsPath)
            let outcome = reading.state
            DispatchQueue.main.async { [weak self] in
                guard let self, self.generation == gen else { return }
                self.isReading = false
                self.apply(self.snapshot.applying([reading]))
                self.confirmation = Confirmation(ok: outcome.isOK, text: Self.refreshNote(provider, outcome))
            }
        }
    }

    private static func refreshNote(_ provider: ProviderID, _ state: ReadState) -> String {
        switch state {
        case .ok: return "\(provider.title) refreshed"
        case let .signIn(reason): return reason
        case let .error(reason): return "Could not refresh: \(reason)"
        case let .rateLimited(reason): return reason
        case .stale: return "\(provider.title) restored"
        case let .notSetUp(reason): return reason
        case .pending: return "\(provider.title) not read"
        }
    }

    // MARK: - Polling

    /// Seconds between polls while the panel is in use, from settings. Every
    /// poll is five network calls and one CLI launch, so the floor is a minute.
    var baseInterval: TimeInterval {
        let configured = defaults.double(forKey: Self.pollIntervalKey)
        return configured >= 60 ? configured : 300
    }

    /// Seconds between polls now: the configured interval while the panel is
    /// being used, a longer one once nobody has opened it for hours.
    var pollInterval: TimeInterval {
        Self.backedOffInterval(base: baseInterval, idleFor: idleDuration)
    }

    /// How long since the panel was last opened.
    private var idleDuration: TimeInterval { max(0, now().timeIntervalSince(lastOpenedAt)) }

    /// The interval to poll at, given the configured interval and how long the
    /// panel has gone unopened. Under the threshold it is the configured
    /// interval; past it the gap doubles for every further threshold, up to the
    /// ceiling. A configured interval longer than the ceiling is the user's
    /// choice and is never shortened. Pure, so the decision is tested without a
    /// clock.
    static func backedOffInterval(base: TimeInterval, idleFor: TimeInterval) -> TimeInterval {
        guard idleFor >= idleThreshold else { return base }
        // Eight doublings pass any ceiling; the cap keeps the exponent small.
        let steps = min(Int(idleFor / idleThreshold), 8)
        return max(base, min(base * pow(2, Double(steps)), idlePollCeiling))
    }

    /// Whether what is on screen is older than one normal poll. An unread
    /// snapshot counts as stale: there is nothing on screen to trust yet.
    static func isStale(age: TimeInterval?, base: TimeInterval) -> Bool {
        guard let age else { return true }
        return age > base
    }

    /// How old the numbers on screen are, by the time of the read that put
    /// them there. Nil before the first reading lands.
    private var snapshotAge: TimeInterval? {
        snapshot.readAt.map { now().timeIntervalSince($0) }
    }

    /// What the armed poll timer is set to, for tests. Nil when none is armed.
    var scheduledPoll: (interval: TimeInterval, tolerance: TimeInterval)? {
        pollTimer.map { ($0.timeInterval, $0.tolerance) }
    }

    func start() {
        poll()
        schedulePoll()
    }

    func schedulePoll() {
        pollTimer?.invalidate()
        let interval = pollInterval
        let timer = Timer(timeInterval: interval, repeats: true) { _ in
            MainActor.assumeIsolated { [weak self] in self?.poll() }
        }
        // Let macOS batch this wakeup with whatever else wakes near it rather
        // than waking the CPU for the poll alone.
        timer.tolerance = interval * Self.pollToleranceFraction
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    /// Called when the panel opens. Opening stays instant and free: it draws
    /// the last good numbers at once and waits on no read. It also ends any
    /// idle backoff, so the cadence is back to normal from here, and when the
    /// numbers on screen are older than one poll it starts a read behind the
    /// panel rather than letting an aged number pass for a fresh one. A
    /// manual ⌘R, a per-provider refresh, and a system wake still read as
    /// they did.
    func panelOpened() {
        isPanelOpen = true
        lastOpenedAt = now()
        schedulePoll()
        if Self.isStale(age: snapshotAge, base: baseInterval) { backgroundRefresh() }
    }

    /// One reading of every source the retry policy allows, off the main
    /// thread. Sources are read one after another on the work queue; a slow one
    /// delays the others, but the timeout on each bounds the whole pass. A
    /// provider behind a persisted rate-limit deadline is skipped, and its row
    /// is left as it was, so a backoff never blanks a number.
    func poll() {
        guard !isReading else { return }
        isReading = true
        generation += 1
        let generation = self.generation
        let base = self.snapshot
        work.async { [tools, samplesPath, retriesPath, readingsPath] in
            var samples = SampleStore.load(from: samplesPath)
            var retries = RetryStore.load(from: retriesPath)
            let now = Date()
            var attempts: [ProviderReading] = []
            for provider in ProviderID.allCases {
                guard retries.shouldAttempt(provider, now: now) else { continue }
                let reading = ProviderReader.read(provider, tools: tools, samples: &samples, now: now)
                if case .rateLimited = reading.state {
                    retries.backoff(provider, retryAfterSeconds: reading.retryAfterSeconds, now: now)
                } else if reading.state.isOK {
                    retries.clear(provider)
                }
                attempts.append(reading)
                let batch = attempts
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.generation == generation else { return }
                    // Keep the untouched rows exactly as they are; only the ones
                    // in this batch are refreshed.
                    self.apply(self.snapshot.applying(batch))
                }
            }
            try? samples.save(to: samplesPath)
            try? retries.save(to: retriesPath)
            let finalSnapshot = base.applying(attempts)
            var store = ReadingStore()
            store.record(finalSnapshot)
            try? store.save(to: readingsPath)
            DispatchQueue.main.async { [weak self] in
                guard let self, self.generation == generation else { return }
                self.isReading = false
                self.apply(self.snapshot.applying(attempts))
            }
        }
    }

    private func apply(_ snapshot: UsageSnapshot) {
        guard snapshot != self.snapshot else { return }
        self.snapshot = snapshot
        onSnapshotChange(snapshot)
    }

    // MARK: - Status item

    /// The provider whose session window the status item shows.
    var headlineProvider: ProviderID? {
        ProviderID(rawValue: defaults.string(forKey: Self.headlineProviderKey) ?? "")
    }

    /// "42%" for the status item, or nil when there is nothing to say.
    func headlineText(for snapshot: UsageSnapshot) -> String? {
        guard let provider = headlineProvider, let reading = snapshot.reading(provider), reading.state.isOK else {
            return nil
        }
        let meter = reading.meters.first { $0.id == "session" } ?? reading.meters.first { !$0.isBalance }
        guard let percent = meter?.percentUsed else { return nil }
        return "\(Int(percent.rounded()))%"
    }

    // MARK: - Render proof

    /// Used by the render proof to draw a state without reading anything.
    func override(snapshot: UsageSnapshot) {
        self.snapshot = snapshot
        self.isReading = false
    }
}
