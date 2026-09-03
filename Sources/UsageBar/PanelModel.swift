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

    @Published private(set) var snapshot: UsageSnapshot = .pending
    @Published private(set) var isReading = false
    @Published var selection: Int = 0
    @Published var confirmation: Confirmation?

    // MARK: Collaborators

    private let tools: ToolPaths
    private let defaults: UserDefaults
    private let samplesPath: String
    private let work = DispatchQueue(label: "com.tristan.usage-menubar.work", qos: .userInitiated)

    private var pollTimer: Timer?
    /// Bumped on every poll so a slow read cannot overwrite a newer one.
    private var generation = 0

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
    /// A read older than this is refreshed when the panel opens.
    static let openRefreshAge: TimeInterval = 60
    /// How many meter rows one provider may take before the rest fold.
    static let meterRowLimit = 4

    init(
        tools: ToolPaths = .installed,
        defaults: UserDefaults = .standard,
        samplesPath: String = SampleStore.defaultPath()
    ) {
        self.tools = tools
        self.defaults = defaults
        self.samplesPath = samplesPath
    }

    // MARK: - Rows

    /// The provider rows, in panel order. Return opens the provider's own
    /// usage page, which is the one thing a number on a panel cannot show.
    var providerActions: [PanelAction] {
        snapshot.readings.map { reading in
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
        snapshot.readings.firstIndex { $0.provider == provider } ?? 0
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

    // MARK: - Polling

    /// Seconds between polls, from settings. Every poll is five network
    /// calls and one CLI launch, so the floor is a minute.
    var pollInterval: TimeInterval {
        let configured = defaults.double(forKey: Self.pollIntervalKey)
        return configured >= 60 ? configured : 300
    }

    func start() {
        poll()
        schedulePoll()
    }

    func schedulePoll() {
        pollTimer?.invalidate()
        let timer = Timer(timeInterval: pollInterval, repeats: true) { _ in
            MainActor.assumeIsolated { [weak self] in self?.poll() }
        }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    /// Called when the panel opens: refresh only if the last read is stale,
    /// so opening the panel twice in a minute does not call five APIs twice.
    func panelOpened() {
        isPanelOpen = true
        guard let readAt = snapshot.readAt else { return }
        if Date().timeIntervalSince(readAt) > Self.openRefreshAge { poll() }
    }

    /// One reading of every source, off the main thread. Sources are read one
    /// after another on the work queue; a slow one delays the others, but the
    /// timeout on each bounds the whole pass.
    func poll() {
        guard !isReading else { return }
        isReading = true
        generation += 1
        let generation = self.generation
        work.async { [tools, samplesPath] in
            var samples = SampleStore.load(from: samplesPath)
            let now = Date()
            var readings: [ProviderReading] = []
            for provider in ProviderID.allCases {
                let reading = ProviderReader.read(provider, tools: tools, samples: &samples, now: now)
                readings.append(reading)
                let partial = readings
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.generation == generation else { return }
                    // Show each source as it lands, with the rest still pending.
                    let pending = ProviderID.allCases.dropFirst(partial.count).map(ProviderReading.pending)
                    self.apply(UsageSnapshot(readings: partial + pending, readAt: self.snapshot.readAt))
                }
            }
            try? samples.save(to: samplesPath)
            DispatchQueue.main.async { [weak self] in
                guard let self, self.generation == generation else { return }
                self.isReading = false
                self.apply(UsageSnapshot(readings: readings, readAt: now))
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
