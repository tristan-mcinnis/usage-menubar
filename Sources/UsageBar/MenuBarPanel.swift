import AppKit
import SwiftUI
import UsageBarCore

// The menu-bar surface, following the "Menu bar panel" component in
// design-system/DESIGN.md and the NSPanel plumbing Cotype built for it, taken
// here from memory-menubar/Sources/MemoryBar/MenuBarPanel.swift (2026-09-03):
// a 300 px glass panel in place of an NSMenu, a header with a status dot,
// 36 px rows, a second group for the rarer actions, and a footer well.
// Arrows, Return and Escape drive it and it closes on focus loss.
//
// What is different here: the rows are grouped by lane (Subscriptions, API
// keys), each provider row is a two-line row with its plan or balance on the
// right, and under it sit "Meter rows" (registered in components.json): one
// per quota window or balance, every one on the same percent-used axis, so
// a Claude session, a Codex week and a DeepSeek balance read side by side.

/// One 36 px provider row: an icon tile, the provider in `label`, the read
/// state in `meta` under it, and the plan or balance on the right.
struct ProviderRow: View {
    let reading: ProviderReading
    let isSelected: Bool
    let onHover: () -> Void
    let onTap: () -> Void
    let onRefresh: () -> Void
    /// Fixed by the render proof so a stale/error age is the same in every PNG.
    let now: Date

    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: House.Spacing.sm) {
                IconTile(symbol: reading.provider.glyph)
                VStack(alignment: .leading, spacing: 1) {
                    Text(reading.provider.title)
                        .font(House.TypeToken.label)
                        .foregroundStyle(House.ColorToken.textPrimary)
                        .lineLimit(1)
                    Text(detail)
                        .font(House.TypeToken.meta)
                        .foregroundStyle(detailIsProblem ? House.ColorToken.danger : House.ColorToken.textTertiary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                Spacer(minLength: House.Spacing.xs)
                Text(trailing)
                    .font(House.TypeToken.meta)
                    .foregroundStyle(House.ColorToken.textSecondary)
                    .lineLimit(1)
            }
            .padding(.horizontal, House.Spacing.sm)
            .frame(height: House.Control.railRow)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(background)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { if $0 { onHover() } }
        .contextMenu {
            Button("Refresh \(reading.provider.title)") { onRefresh() }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(reading.provider.title), \(detail), \(trailing)")
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    /// The second line: the lane word when the read is fine, the reason when
    /// it is not, with the age of the data it is replacing. The reason is the
    /// only line on the panel that may go red, and it is a sentence, so the
    /// colour is never alone.
    private var detail: String {
        switch reading.state {
        case .ok: return reading.provider.lane == .subscription ? "Subscription" : "Prepaid key"
        case .stale:
            if let age = reading.shownAge(now: now) { return "Restored · \(age)" }
            return "Restored"
        case let .signIn(reason), let .error(reason), let .rateLimited(reason):
            if let stale = reading.staleNote(now: now) { return "\(reason) · \(stale)" }
            return reason
        case let .notSetUp(reason): return reason
        case .pending: return "Reading…"
        }
    }

    private var detailIsProblem: Bool {
        switch reading.state {
        case .signIn, .error, .rateLimited: return true
        case .ok, .stale, .pending, .notSetUp: return false
        }
    }

    /// The number on the right: the last good plan or balance, kept visible
    /// even while a refresh or a transient failure runs. The reason (if any)
    /// is in the detail line, so the number is not duplicated. A sign-in ask
    /// supersedes the last good values, so it draws no number.
    private var trailing: String {
        switch reading.state {
        case .pending, .signIn, .notSetUp: return ""
        case .ok, .stale, .error, .rateLimited: return reading.retainedValue
        }
    }

    @ViewBuilder
    private var background: some View {
        let shape = RoundedRectangle(cornerRadius: House.Radius.row, style: .continuous)
        if isSelected {
            shape
                .fill(House.ColorToken.selectionFill)
                .overlay(shape.strokeBorder(House.ColorToken.selectionRing, lineWidth: House.hairline))
                .houseShadow(House.Shadow.selection, dark: scheme == .dark)
        } else {
            shape.fill(Color.clear)
        }
    }
}

/// One 28 px meter row under a provider: the window's name in `meta`, an ink
/// bar on a `tileFill` track, the percent in `label`, and the reset time in
/// `meta` after it. No colour: a window at its cap says "100%" and the reset
/// beside it says when. Inset to the provider row's text column.
struct MeterRow: View {
    let meter: Meter
    let now: Date

    /// The label column, so the bars of every provider line up.
    private static let labelWidth: CGFloat = 96
    private static let valueWidth: CGFloat = 40

    var body: some View {
        HStack(spacing: House.Spacing.xs) {
            Text(meter.label)
                .font(House.TypeToken.meta)
                .foregroundStyle(House.ColorToken.textSecondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(width: Self.labelWidth, alignment: .leading)
            MeterBar(fraction: (meter.percentUsed ?? 0) / 100, known: meter.percentUsed != nil)
            Text(meter.value())
                .font(House.TypeToken.label)
                .foregroundStyle(House.ColorToken.textPrimary)
                .monospacedDigit()
                .lineLimit(1)
                .frame(minWidth: Self.valueWidth, alignment: .trailing)
        }
        .padding(.leading, House.Spacing.sm + House.Control.tile + House.Spacing.sm)
        .padding(.trailing, House.Spacing.sm)
        .frame(height: House.Control.compact)
        .frame(maxWidth: .infinity, alignment: .leading)
        .help(meter.detail(now: now) ?? meter.label)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(meter.label) \(meter.value())" + (meter.detail(now: now).map { ", \($0)" } ?? ""))
    }
}

/// The bar itself: a 4 px track in `tileFill` with an ink fill at
/// `Radius.xs`. Unknown draws an empty track, never a fabricated zero.
struct MeterBar: View {
    let fraction: Double
    var known = true

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: House.Radius.xs, style: .continuous)
                    .fill(House.ColorToken.tileFill)
                    .overlay(
                        RoundedRectangle(cornerRadius: House.Radius.xs, style: .continuous)
                            .strokeBorder(House.ColorToken.tileStroke, lineWidth: House.hairline)
                    )
                if known, fraction > 0 {
                    RoundedRectangle(cornerRadius: House.Radius.xs, style: .continuous)
                        .fill(House.ColorToken.textPrimary)
                        .frame(width: max(House.Spacing.xxs, geometry.size.width * min(1, fraction)))
                }
            }
        }
        .frame(height: House.Spacing.xxs)
        .frame(maxWidth: .infinity)
    }
}

/// The one line of detail under a provider's meters: when the tightest
/// window resets, or the balance's spend since its peak.
struct MeterFootnote: View {
    let text: String

    var body: some View {
        Text(text)
            .font(House.TypeToken.caption)
            .foregroundStyle(House.ColorToken.textTertiary)
            .lineLimit(1)
            .truncationMode(.tail)
            .padding(.leading, House.Spacing.sm + House.Control.tile + House.Spacing.sm)
            .padding(.trailing, House.Spacing.sm)
            .padding(.bottom, House.Spacing.xxs)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// One 36 px action row: a glyph, a `label` title, and outlined key caps.
struct PanelRow: View {
    let action: PanelAction
    let isSelected: Bool
    let onHover: () -> Void
    let onTap: () -> Void

    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: House.Spacing.sm) {
                Image(systemName: action.glyph)
                    .font(.system(size: House.TypeToken.Size.bodySmall))
                    .foregroundStyle(House.ColorToken.textSecondary)
                    .frame(width: 16)
                Text(action.title)
                    .font(House.TypeToken.label)
                    .foregroundStyle(House.ColorToken.textPrimary)
                    .lineLimit(1)
                Spacer(minLength: House.Spacing.xs)
                if !action.chord.isEmpty {
                    KeyCaps(chord: action.chord)
                }
            }
            .padding(.horizontal, House.Spacing.sm)
            .frame(height: House.Control.railRow)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(background)
            .contentShape(Rectangle())
            .opacity(opacity)
        }
        .buttonStyle(.plain)
        .disabled(!action.isEnabled)
        .onHover { if $0 { onHover() } }
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    private var opacity: Double {
        if !action.isEnabled { return 0.45 }
        return action.isQuiet ? 0.75 : 1
    }

    @ViewBuilder
    private var background: some View {
        let shape = RoundedRectangle(cornerRadius: House.Radius.row, style: .continuous)
        if isSelected && action.isEnabled {
            shape
                .fill(House.ColorToken.selectionFill)
                .overlay(shape.strokeBorder(House.ColorToken.selectionRing, lineWidth: House.hairline))
                .houseShadow(House.Shadow.selection, dark: scheme == .dark)
        } else {
            shape.fill(Color.clear)
        }
    }
}

/// An uppercase `section` label inside the panel ("SUBSCRIPTIONS").
struct PanelSectionLabel: View {
    let text: String

    var body: some View {
        Text(text.uppercased())
            .font(House.TypeToken.section)
            .tracking(House.TypeToken.Tracking.section)
            .foregroundStyle(House.ColorToken.textTertiary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, House.Spacing.sm)
            .padding(.top, House.Spacing.xs)
            .padding(.bottom, 2)
    }
}

/// A dim explanatory line inside the panel.
struct PanelNote: View {
    let text: String
    var danger = false

    var body: some View {
        Text(text)
            .font(House.TypeToken.meta)
            .foregroundStyle(danger ? House.ColorToken.danger : House.ColorToken.textTertiary)
            .lineLimit(2)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, House.Spacing.sm)
            .padding(.vertical, House.Spacing.xxs)
    }
}

// MARK: - The panel

struct MenuBarPanelView: View {
    @ObservedObject var model: PanelModel
    /// Fixed by the render proof so a countdown is the same in every PNG.
    var now: Date = Date()

    /// The panel width from the mockup.
    static let width: CGFloat = 300

    var body: some View {
        HouseGlass(radius: House.Radius.lg) {
            VStack(spacing: 0) {
                header
                SlateDivider()
                rows
                FooterWell(height: 36) {
                    footerButton(
                        index: model.footerSelectionBase,
                        title: "Settings", chord: "⌘ ,", run: model.onOpenSettings
                    )
                } trailing: {
                    footerButton(
                        index: model.footerSelectionBase + 1,
                        title: "Quit", chord: "⌘ Q", run: model.onQuit
                    )
                }
            }
        }
        .frame(width: Self.width)
        .padding(House.Spacing.md)
    }

    // MARK: Header

    /// 26 px icon tile, the app name in `label`, and a status line in
    /// `caption` with a 6 px dot. There is no master switch: there is
    /// nothing here to turn off.
    private var header: some View {
        HStack(spacing: House.Spacing.sm) {
            IconTile(symbol: "gauge.with.needle")
            VStack(alignment: .leading, spacing: 1) {
                Text("Usage")
                    .font(House.TypeToken.label)
                    .foregroundStyle(House.ColorToken.textPrimary)
                HStack(spacing: House.Spacing.xxs) {
                    StatusDot(tint: dotTint)
                    Text(model.snapshot.headline(now: now).text)
                        .font(House.TypeToken.caption)
                        .foregroundStyle(House.ColorToken.textTertiary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: House.Spacing.xs)
        }
        .padding(.horizontal, House.Spacing.sm)
        .padding(.vertical, House.Spacing.sm)
    }

    private var dotTint: Color {
        switch model.snapshot.headline.health {
        case .ok: return House.ColorToken.success
        case .failing: return House.ColorToken.danger
        case .unknown: return House.ColorToken.textTertiary
        }
    }

    // MARK: Rows

    private var rows: some View {
        VStack(spacing: 2) {
            if let confirmation = model.confirmation {
                HStack(spacing: House.Spacing.xs) {
                    StatusDot(tint: confirmation.ok ? House.ColorToken.success : House.ColorToken.danger)
                    Text(confirmation.text)
                        .font(House.TypeToken.meta)
                        .foregroundStyle(House.ColorToken.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, House.Spacing.sm)
                .padding(.top, House.Spacing.xxs)
            }

            // A lane with no set-up source draws no label.
            ForEach(Lane.allCases.filter { !model.snapshot.readings(in: $0).isEmpty }, id: \.rawValue) { lane in
                PanelSectionLabel(text: lane.title)
                ForEach(model.snapshot.readings(in: lane)) { reading in
                    provider(reading)
                }
            }

            SlateDivider().padding(.vertical, House.Spacing.xxs)
            ForEach(Array(model.moreActions.enumerated()), id: \.element.id) { index, action in
                PanelRow(
                    action: action,
                    isSelected: model.selection == model.providerActions.count + index,
                    onHover: { model.selection = model.providerActions.count + index },
                    onTap: action.run
                )
            }
        }
        .padding(.horizontal, House.Spacing.xs)
        .padding(.vertical, House.Spacing.xs)
    }

    /// A provider row and, when the read succeeded, its meters. A provider
    /// with more windows than the budget shows the tightest ones and says
    /// how many it folded.
    @ViewBuilder
    private func provider(_ reading: ProviderReading) -> some View {
        let index = model.selectionIndex(of: reading.provider)
        ProviderRow(
            reading: reading,
            isSelected: model.selection == index,
            onHover: { model.selection = index },
            onTap: { model.openUsagePage(reading.provider) },
            onRefresh: { model.refresh(reading.provider) },
            now: now
        )
        if !reading.meters.isEmpty {
            let shown = Self.meters(toShow: reading.meters)
            ForEach(shown) { meter in
                MeterRow(meter: meter, now: now)
            }
            if let footnote = Self.footnote(for: reading, shown: shown, now: now) {
                MeterFootnote(text: footnote)
            }
        }
    }

    /// The rows a provider gets: every meter up to the budget, fullest first
    /// when there are too many, in source order otherwise.
    static func meters(toShow meters: [Meter]) -> [Meter] {
        if meters.count <= PanelModel.meterRowLimit { return meters }
        return Array(meters.sorted { ($0.percentUsed ?? -1) > ($1.percentUsed ?? -1) }.prefix(PanelModel.meterRowLimit))
    }

    static func footnote(for reading: ProviderReading, shown: [Meter], now: Date) -> String? {
        var parts: [String] = []
        // The two soonest distinct resets among the windows that have used
        // anything: a session and its week, as Baby Menu showed each window's
        // reset. Windows that reset together (a week and its model-scoped
        // week) are named once, by the first of them.
        let resets = Self.resets(of: shown)
        if let first = resets.first {
            if resets.count > 1 {
                // Short form, so both fit in the 300 px column.
                parts.append("\(first.owner) resets \(Format.countdown(to: first.at, from: now))"
                    + " · \(resets[1].owner) \(Format.countdown(to: resets[1].at, from: now))")
            } else {
                parts.append("\(first.owner) resets in \(Format.countdown(to: first.at, from: now))")
            }
        } else if let balance = shown.first(where: \.isBalance), let detail = balance.detail(now: now) {
            parts.append(detail)
        }
        let folded = reading.meters.count - shown.count
        if folded > 0 { parts.append("\(folded) more") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// Distinct reset times of the windows that have used anything, soonest
    /// first, each named by the first window (in source order) that resets
    /// then. Resets within a minute of each other count as one.
    static func resets(of meters: [Meter]) -> [(owner: String, at: Date)] {
        var found: [(owner: String, at: Date)] = []
        for meter in meters where (meter.percentUsed ?? 0) > 0 {
            guard let at = meter.resetsAt else { continue }
            if found.contains(where: { abs($0.at.timeIntervalSince(at)) < 60 }) { continue }
            found.append((meter.label.lowercased(), at))
        }
        return found.sorted { $0.at < $1.at }
    }

    // MARK: Footer

    private func footerButton(index: Int, title: String, chord: String, run: @escaping () -> Void) -> some View {
        Button(action: run) {
            KeyHint(title: title, chord: chord)
                .padding(.horizontal, House.Spacing.xxs)
                .padding(.vertical, 2)
                .background(
                    RoundedRectangle(cornerRadius: House.Radius.sm, style: .continuous)
                        .fill(model.selection == index ? House.ColorToken.selectionFill : Color.clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { if $0 { model.selection = index } }
    }
}

// MARK: - Panel window

/// A borderless panel that can take key focus, so arrows, Return and Escape
/// drive it without a pointer.
final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Owns the menu-bar panel window: shows it under the status item, routes the
/// keyboard, and closes it on focus loss. Ported from Memory's controller of
/// the same name.
@MainActor
final class MenuBarPanelController {
    let model: PanelModel

    private var panel: KeyablePanel?
    private var hosting: NSHostingView<MenuBarPanelView>?
    private var keyMonitor: Any?
    private var resignObserver: NSObjectProtocol?

    var isVisible: Bool { panel?.isVisible ?? false }

    init(model: PanelModel) {
        self.model = model
        model.onClose = { [weak self] in self?.close() }
    }

    func toggle(relativeTo button: NSStatusBarButton?) {
        if isVisible { close() } else { show(relativeTo: button) }
    }

    func show(relativeTo button: NSStatusBarButton?) {
        let panel = self.panel ?? makePanel()
        self.panel = panel
        model.selection = 0
        model.confirmation = nil
        model.panelOpened()
        // Countdowns are computed at open; the panel is rebuilt each time.
        hosting?.rootView = MenuBarPanelView(model: model, now: Date())

        panel.setContentSize(panel.contentView?.fittingSize ?? NSSize(width: MenuBarPanelView.width + 32, height: 320))
        if let origin = anchorFrame(for: button, size: panel.frame.size) {
            panel.setFrameOrigin(origin)
        } else {
            panel.center()
        }
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        startKeyMonitor()
        observeResign(panel)
    }

    func close() {
        stopKeyMonitor()
        if let resignObserver {
            NotificationCenter.default.removeObserver(resignObserver)
            self.resignObserver = nil
        }
        model.isPanelOpen = false
        panel?.orderOut(nil)
    }

    /// The panel grows and shrinks as readings land; keep the top edge
    /// anchored under the status item.
    func refit(relativeTo button: NSStatusBarButton?) {
        guard let panel, panel.isVisible else { return }
        let size = panel.contentView?.fittingSize ?? panel.frame.size
        let top = panel.frame.maxY
        panel.setContentSize(size)
        if let origin = anchorFrame(for: button, size: panel.frame.size) {
            panel.setFrameOrigin(origin)
        } else {
            panel.setFrameOrigin(NSPoint(x: panel.frame.minX, y: top - panel.frame.height))
        }
    }

    private func makePanel() -> KeyablePanel {
        let hosting = NSHostingView(rootView: MenuBarPanelView(model: model))
        hosting.setFrameSize(hosting.fittingSize)
        self.hosting = hosting

        let panel = KeyablePanel(
            contentRect: NSRect(origin: .zero, size: hosting.fittingSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.contentView = hosting
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .statusBar
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.appearance = AppearancePreference.current.nsAppearance
        return panel
    }

    /// Anchor under the status item, clamped to the screen.
    private func anchorFrame(for button: NSStatusBarButton?, size: NSSize) -> NSPoint? {
        guard let button, let window = button.window else { return nil }
        let inScreen = window.convertToScreen(button.convert(button.bounds, to: nil))
        let screen = NSScreen.screens.first(where: { $0.frame.intersects(inScreen) }) ?? NSScreen.main
        var x = inScreen.midX - size.width / 2
        let y = inScreen.minY - size.height
        if let visible = screen?.visibleFrame {
            x = min(max(x, visible.minX), visible.maxX - size.width)
        }
        return NSPoint(x: x, y: y)
    }

    // MARK: Keyboard

    private func startKeyMonitor() {
        guard keyMonitor == nil else { return }
        // Only the key's Sendable parts cross into the main actor; the event
        // itself stays in the monitor, which returns it or swallows it.
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.isVisible else { return event }
            let key = KeyPress(event)
            let consumed = MainActor.assumeIsolated { self.handle(key) }
            return consumed ? nil : event
        }
    }

    private func stopKeyMonitor() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }

    /// Arrows and Return drive the rows; Escape closes. The command chords
    /// are handled here rather than as SwiftUI shortcuts so they work
    /// wherever focus is. True when the key was handled and must not reach
    /// the focused view.
    private func handle(_ key: KeyPress) -> Bool {
        if key.flags.contains(.command) {
            switch key.characters?.lowercased() {
            case "r": model.refresh(); return true
            case ",": model.onOpenSettings(); return true
            case "q": model.onQuit(); return true
            default: return false
            }
        }

        switch key.keyCode {
        case 125: // down
            model.moveSelection(by: 1)
            return true
        case 126: // up
            model.moveSelection(by: -1)
            return true
        case 36, 76: // return, enter
            model.runSelection()
            return true
        case 53: // esc
            model.escape()
            return true
        default:
            return false
        }
    }

    private func observeResign(_ panel: NSPanel) {
        guard resignObserver == nil else { return }
        resignObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification, object: panel, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.close() }
        }
    }
}

/// The parts of a key-down the panel reads. `NSEvent` is not Sendable, so the
/// monitor copies these out before it hops onto the main actor.
private struct KeyPress: Sendable {
    let keyCode: UInt16
    let flags: NSEvent.ModifierFlags
    let characters: String?

    init(_ event: NSEvent) {
        keyCode = event.keyCode
        flags = event.modifierFlags
        characters = event.charactersIgnoringModifiers
    }
}
