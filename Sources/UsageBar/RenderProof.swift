import AppKit
import SwiftUI
import UsageBarCore

// Offscreen render proof. `usage-bar --render-proof <dir>` draws every Slate
// surface into PNGs without putting a window on screen, so the design can be
// compared against design-system/DESIGN.md and against Memory's panel by
// hand. Nothing here runs in the normal app path, and nothing here reads a
// credential or calls a network: every state is a fixed snapshot, so the
// proof is the same on any Mac. Ported from memory-menubar's RenderProof.

@MainActor
enum RenderProof {

    /// A fixed "now", so every countdown in the PNGs is the same on any day.
    static let now = Date(timeIntervalSince1970: 1_788_000_000)

    /// Render every proof surface into `directory` and return the file paths.
    @discardableResult
    static func run(into directory: URL) -> [URL] {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        var written: [URL] = []
        for (name, appearance) in [("dark", NSAppearance(named: .darkAqua)), ("light", NSAppearance(named: .aqua))] {
            let panels: [(String, PanelModel)] = [
                ("panel-all-read", allReadModel()),
                ("panel-partial", partialModel()),
                ("panel-pending", pendingModel()),
            ]
            for (surface, model) in panels {
                if let url = write(
                    view: MenuBarPanelView(model: model, now: now),
                    size: NSSize(width: MenuBarPanelView.width + 2 * House.Spacing.md, height: 360),
                    appearance: appearance,
                    to: directory.appendingPathComponent("\(surface)-\(name).png"),
                    fitToContent: true
                ) {
                    written.append(url)
                }
            }
            if let url = write(
                view: SettingsView(model: allReadModel()),
                size: NSSize(width: 760, height: 720),
                appearance: appearance,
                to: directory.appendingPathComponent("settings-\(name).png")
            ) {
                written.append(url)
            }
        }
        return written
    }

    // MARK: - The states

    private static func hours(_ hours: Double) -> Date { now.addingTimeInterval(hours * 3_600) }

    /// Every source readable, the shape a normal afternoon has.
    static let allRead = UsageSnapshot(
        readings: [
            ProviderReading(provider: .claude, state: .ok, plan: "max", meters: [
                Meter(id: "session", label: "Session", percentUsed: 42, resetsAt: hours(2.2)),
                Meter(id: "weekly", label: "Weekly", percentUsed: 18, resetsAt: hours(99)),
                Meter(id: "weekly-opus", label: "Weekly · Opus", percentUsed: 31, resetsAt: hours(99)),
            ], readAt: now.addingTimeInterval(-120)),
            ProviderReading(provider: .codex, state: .ok, plan: "plus", meters: [
                Meter(id: "rate-primary", label: "Session", percentUsed: 7, resetsAt: hours(4.5)),
                Meter(id: "rate-secondary", label: "Weekly", percentUsed: 63, resetsAt: hours(52)),
            ], readAt: now.addingTimeInterval(-120)),
            ProviderReading(provider: .antigravity, state: .ok, meters: [
                Meter(id: "g1", label: "Gemini · session", percentUsed: 12, resetsAt: hours(3)),
                Meter(id: "g2", label: "Gemini · weekly", percentUsed: 55, resetsAt: hours(140)),
                Meter(id: "c1", label: "Claude · session", percentUsed: 0, resetsAt: hours(5)),
                Meter(id: "c2", label: "Claude · weekly", percentUsed: 100, resetsAt: hours(30)),
                Meter(id: "o1", label: "Other · weekly", percentUsed: 3, resetsAt: hours(140)),
            ], readAt: now.addingTimeInterval(-120)),
            ProviderReading(provider: .deepseek, state: .ok, meters: [
                Meter(id: "balance-cny", label: "Balance", percentUsed: 24, amount: 83.2, currency: "CNY"),
            ], readAt: now.addingTimeInterval(-120)),
            ProviderReading(provider: .moonshot, state: .ok, meters: [
                Meter(id: "balance", label: "Balance", percentUsed: nil, amount: 120, currency: "CNY"),
            ], readAt: now.addingTimeInterval(-120)),
        ],
        readAt: now.addingTimeInterval(-120)
    )

    /// One source needs a sign-in and one could not be reached.
    static let partial = UsageSnapshot(
        readings: [
            allRead.readings[0],
            ProviderReading(provider: .codex, state: .signIn("Sign in to Codex"), readAt: now),
            allRead.readings[2],
            ProviderReading(provider: .deepseek, state: .error("timeout"), readAt: now),
            allRead.readings[4],
        ],
        readAt: now.addingTimeInterval(-30)
    )

    private static func model(_ snapshot: UsageSnapshot) -> PanelModel {
        let model = PanelModel(defaults: proofDefaults)
        model.override(snapshot: snapshot)
        return model
    }

    /// Settings the proof reads, so a Mac's own defaults cannot change it.
    private static let proofDefaults: UserDefaults = {
        let defaults = UserDefaults(suiteName: "com.tristan.usage-menubar.render-proof")!
        defaults.set(300.0, forKey: PanelModel.pollIntervalKey)
        defaults.set(ProviderID.claude.rawValue, forKey: PanelModel.headlineProviderKey)
        return defaults
    }()

    static func allReadModel() -> PanelModel {
        let model = model(allRead)
        model.selection = 0
        return model
    }

    static func partialModel() -> PanelModel {
        let model = model(partial)
        model.selection = 1
        return model
    }

    static func pendingModel() -> PanelModel {
        model(.pending)
    }

    // MARK: - Rendering

    private static func write<V: View>(
        view: V,
        size: NSSize,
        appearance: NSAppearance?,
        to url: URL,
        fitToContent: Bool = false
    ) -> URL? {
        let hosting = NSHostingView(rootView: view)
        hosting.appearance = appearance
        hosting.frame = NSRect(origin: .zero, size: size)
        if fitToContent {
            let fitted = hosting.fittingSize
            hosting.frame = NSRect(
                origin: .zero,
                size: NSSize(width: max(fitted.width, size.width), height: max(fitted.height, 1))
            )
        }
        hosting.layoutSubtreeIfNeeded()
        // Give SwiftUI one runloop turn to commit its first layout pass.
        RunLoop.main.run(until: Date().addingTimeInterval(0.35))
        hosting.layoutSubtreeIfNeeded()
        return capture(hosting, appearance: appearance, to: url)
    }

    /// Snapshot a view over a plain ground, so a glass panel reads the way it
    /// does on screen instead of over transparency.
    private static func capture(_ view: NSView, appearance: NSAppearance?, to url: URL) -> URL? {
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: rep)

        let scale = rep.pixelsWide > 0 ? CGFloat(rep.pixelsWide) / view.bounds.width : 1
        guard let composite = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: rep.pixelsWide,
            pixelsHigh: rep.pixelsHigh,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else { return nil }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: composite)
        NSGraphicsContext.current?.cgContext.scaleBy(x: scale, y: scale)
        let isDark = (appearance ?? NSAppearance.currentDrawing())
            .bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        (appearance ?? NSAppearance.currentDrawing()).performAsCurrentDrawingAppearance {
            // The desktop behind a floating panel, not a token: the proof
            // paints a plain ground the way a wallpaper would.
            (isDark ? NSColor(white: 0.09, alpha: 1) : NSColor(white: 0.86, alpha: 1)).setFill()
            NSRect(origin: .zero, size: view.bounds.size).fill()
        }
        NSImage(size: view.bounds.size, flipped: false) { rect in
            rep.draw(in: rect)
            return true
        }.draw(in: NSRect(origin: .zero, size: view.bounds.size))
        NSGraphicsContext.restoreGraphicsState()

        guard let data = composite.representation(using: .png, properties: [:]) else { return nil }
        try? data.write(to: url)
        return url
    }
}
