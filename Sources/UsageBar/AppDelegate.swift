import AppKit
import SwiftUI
import UsageBarCore

/// Menu-bar app delegate. Owns the status item, the panel, the polling model,
/// and the settings window. Usage is an `.accessory` app: no Dock icon, and
/// it never takes the foreground unless a row asks for it.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    private var statusItem: NSStatusItem!
    private var settingsWindowController: NSWindowController?
    private var defaultsObserver: NSObjectProtocol?
    private var wakeObserver: NSObjectProtocol?

    private let model = PanelModel()
    private lazy var panel = MenuBarPanelController(model: model)
    /// The menu bar shown while a normal window is open.
    private lazy var settingsMenu = SettingsMenu(showSettings: { [weak self] in self?.openSettings() })

    func applicationDidFinishLaunching(_ notification: Notification) {
        let build = Bundle.main.object(forInfoDictionaryKey: "UsageBuiltFromCommit") as? String ?? "unstamped"
        EventLog.append("launch pid=\(ProcessInfo.processInfo.processIdentifier) build=\(build)")
        UserDefaults.standard.register(defaults: [
            // Dark is the house default; light is first-class.
            AppearancePreference.key: AppearancePreference.dark.rawValue,
            PanelModel.pollIntervalKey: 300.0,
            PanelModel.headlineProviderKey: ProviderID.claude.rawValue,
        ])
        AppearancePreference.applyCurrent()

        model.onOpenSettings = { [weak self] in
            self?.panel.close()
            self?.openSettings()
        }
        model.onQuit = {
            EventLog.append("quit from panel")
            NSApp.terminate(nil)
        }
        model.onSnapshotChange = { [weak self] snapshot in
            self?.updateStatusItem(snapshot)
            self?.panel.refit(relativeTo: self?.statusItem.button)
        }

        setupStatusItem()
        observeDefaults()
        observeSystemWake()
        model.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Any AppKit shutdown: ⌘Q, the Quit row, logout, or a polite quit
        // from outside. A kill or a crash never reaches here.
        EventLog.append("terminate pid=\(ProcessInfo.processInfo.processIdentifier)")
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
            self.wakeObserver = nil
        }
    }

    /// Refresh when the Mac wakes from sleep, so a long night of closed lid
    /// turns into a fresh set of numbers rather than a stale one. Opening the
    /// panel never fetches. The observer is owned here and removed on
    /// termination.
    private func observeSystemWake() {
        let center = NSWorkspace.shared.notificationCenter
        wakeObserver = center.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.model.poll() }
        }
    }

    // MARK: - Status item

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem = item
        item.button?.target = self
        item.button?.action = #selector(togglePanel)
        item.button?.imagePosition = .imageLeading
        updateStatusItem(model.snapshot)
    }

    /// The status item says the same thing the panel header does: the gauge
    /// from the app icon, and beside it the chosen provider's session
    /// percent when the settings ask for one. The gauge is always a template
    /// image, so it tracks the menu bar's own colour; a window at its cap
    /// says "100%" in the panel, never in colour here.
    private func updateStatusItem(_ snapshot: UsageSnapshot) {
        guard let button = statusItem?.button else { return }
        let text = model.headlineText(for: snapshot)
        let description = "Usage — " + snapshot.headline.text

        let image = NSImage(systemSymbolName: "gauge.with.needle", accessibilityDescription: description)?
            .withSymbolConfiguration(
                NSImage.SymbolConfiguration(pointSize: House.Control.statusGlyph, weight: .medium)
            )
        image?.isTemplate = true
        button.image = image
        button.title = text.map { " " + $0 } ?? ""
        button.font = NSFont.monospacedDigitSystemFont(ofSize: House.TypeToken.Size.bodySmall, weight: .regular)
        button.toolTip = description
    }

    @objc private func togglePanel() {
        panel.toggle(relativeTo: statusItem.button)
    }

    // MARK: - Defaults

    private func observeDefaults() {
        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { [weak self] in
                AppearancePreference.applyCurrent()
                guard let self else { return }
                self.updateStatusItem(self.model.snapshot)
            }
        }
    }

    // MARK: - Settings

    @objc private func openSettings() {
        if let controller = settingsWindowController, let window = controller.window {
            controller.showWindow(nil)
            present(window)
            return
        }

        let hosting = NSHostingController(rootView: SettingsView(model: model))
        let window = NSWindow(contentViewController: hosting)
        window.title = "Usage"
        window.styleMask = [.titled, .closable, .miniaturizable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.backgroundColor = House.NSColorToken.surface
        window.appearance = AppearancePreference.current.nsAppearance
        window.setContentSize(NSSize(width: 760, height: 540))
        window.minSize = NSSize(width: 720, height: 460)

        window.isReleasedWhenClosed = false
        window.delegate = self
        let controller = NSWindowController(window: window)
        controller.showWindow(self)
        window.center()
        present(window)
        settingsWindowController = controller
    }

    /// A normal window is up: install the menu bar it needs (Edit for its
    /// text fields, Window for minimise and close) and take the keyboard.
    /// An accessory app cannot activate itself on request alone, so
    /// `AppActivation` asks LaunchServices when the request is refused.
    private func present(_ window: NSWindow) {
        if NSApp.mainMenu == nil { NSApp.mainMenu = settingsMenu.makeMenu() }
        AppActivation.becomeRegularApp(showing: window)
    }
}

extension AppDelegate: NSWindowDelegate {
    /// The last normal window is closing: hand the menu bar back and become
    /// a menu-bar app again.
    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        if window === settingsWindowController?.window { settingsWindowController = nil }
        AppActivation.settleAfterClosing(window)
    }
}
