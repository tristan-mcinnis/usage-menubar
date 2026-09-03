import AppKit
import ServiceManagement
import SwiftUI
import UsageBarCore

/// Usage has one settings pane, so the shared Slate shell is used at its
/// smallest: a 220 px rail with a single row, a 60 px pane header, cards on
/// the window ground, and a footer well. The shell is the one Memory and
/// Cotype use; a second pane would slot into the rail without changing
/// anything else.
struct SettingsView: View {
    @ObservedObject var model: PanelModel

    @AppStorage(AppearancePreference.key) private var appearance = AppearancePreference.dark.rawValue
    @AppStorage(PanelModel.pollIntervalKey) private var pollInterval = 300.0
    @AppStorage(PanelModel.headlineProviderKey) private var headlineProvider = ProviderID.claude.rawValue
    @State private var launchAtLogin = LoginItem.isEnabled
    @State private var loginItemNote: String?

    /// Every poll is five network calls and one CLI launch, so the floor is
    /// a minute and the default is five.
    private static let intervals: [(value: Double, title: String)] = [
        (60, "1 min"), (300, "5 min"), (900, "15 min"),
    ]

    /// The segment labels: the plan's name, not the product's, so they fit.
    private static func shortTitle(_ provider: ProviderID) -> String {
        provider == .claude ? "Claude" : provider.title
    }

    var body: some View {
        HStack(spacing: 0) {
            rail
            pane
        }
        .background(House.ColorToken.surface)
        .frame(minWidth: 720, minHeight: 460)
    }

    // MARK: - Rail

    private var rail: some View {
        VStack(alignment: .leading, spacing: House.Spacing.sm) {
            AppMark(symbol: "gauge.with.needle", name: "Usage", caption: "Settings")
                .padding(.horizontal, House.Spacing.xs)
                .padding(.top, House.Spacing.xxl)
            RailRow(symbol: "gearshape", title: "General", isSelected: true) {}
            Spacer(minLength: 0)
        }
        .padding(.horizontal, House.Spacing.sm)
        .frame(width: House.Layout.settingsRail)
        .frame(maxHeight: .infinity)
        .background(House.ColorToken.surfaceSunken)
        .overlay(alignment: .trailing) {
            House.ColorToken.divider.frame(width: House.hairline)
        }
    }

    // MARK: - Pane

    private var pane: some View {
        VStack(spacing: 0) {
            PaneHeader(
                title: "General",
                purpose: "How Usage looks, what the menu bar shows, and how often the sources are asked."
            )
            // The window hides its title bar, so the pane starts under the
            // traffic lights; this is the clearance for them.
            .padding(.top, House.Spacing.lg)
            ScrollView {
                VStack(alignment: .leading, spacing: House.Spacing.md) {
                    appearanceCard
                    menuBarCard
                    sourcesCard
                }
                .padding(House.Spacing.lg)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            FooterWell {
                FooterStatus(text: model.snapshot.headline.text, tint: footerTint)
            } trailing: {
                KeyHint(title: "Close", chord: "⌘ W")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var footerTint: Color {
        switch model.snapshot.headline.health {
        case .ok: return House.ColorToken.success
        case .failing: return House.ColorToken.danger
        case .unknown: return House.ColorToken.textTertiary
        }
    }

    // MARK: - Cards

    private var appearanceCard: some View {
        SlateCard(section: "Appearance") {
            SlateRow(title: "Theme", detail: "Dark is the house default; light is first-class.") {
                SlateSegmented(
                    options: AppearancePreference.allCases.map { ($0.rawValue, $0.title) },
                    selection: Binding(
                        get: { appearance },
                        set: { newValue in
                            appearance = newValue
                            AppearancePreference.applyCurrent()
                        }
                    )
                )
                .frame(width: 230)
            }
            SlateDivider()
            SlateRow(
                title: "Launch at login",
                detail: loginItemNote ?? "Usage has no Dock icon; it lives in the menu bar."
            ) {
                InkSwitch(isOn: Binding(
                    get: { launchAtLogin },
                    set: { wanted in
                        loginItemNote = LoginItem.set(wanted)
                        launchAtLogin = LoginItem.isEnabled
                    }
                ))
            }
        }
    }

    private var menuBarCard: some View {
        SlateCard(
            section: "Menu bar",
            footnote: "The gauge turns red only when a subscription window is at its cap; the panel says which."
        ) {
            SlateRow(
                title: "Beside the gauge",
                detail: "One subscription's session percent, or nothing."
            ) {
                SlateSegmented(
                    options: [("none", "None")] + ProviderID.subscriptions.map { ($0.rawValue, Self.shortTitle($0)) },
                    selection: $headlineProvider
                )
                .frame(width: 320)
            }
        }
    }

    private var sourcesCard: some View {
        SlateCard(
            section: "Sources",
            footnote: "Usage keeps no credential. It reads what each tool already stores, on every poll, and writes only balance samples to ~/Library/Application Support/Usage."
        ) {
            SlateRow(
                title: "Poll interval",
                detail: "How often every source is asked. Opening the panel also refreshes a reading older than a minute."
            ) {
                SlateSegmented(
                    options: Self.intervals.map { ($0.value, $0.title) },
                    selection: $pollInterval
                )
                .frame(width: 230)
            }
            SlateDivider()
            SlateBlock {
                SlateInfoRow(title: "Claude Code", value: "keychain · \(ClaudeCredential.keychainService)", monospaced: true)
                SlateInfoRow(title: "Codex", value: CodexCredential.path(tools: .installed), monospaced: true)
                SlateInfoRow(title: "Antigravity", value: ToolPaths.installed.agy, monospaced: true)
                SlateInfoRow(title: "DeepSeek", value: APIKey.deepseekFiles(tools: .installed)[0], monospaced: true)
                SlateInfoRow(title: "Moonshot", value: APIKey.moonshotFiles(tools: .installed)[0], monospaced: true)
                SlateInfoRow(title: "Soniox", value: "SONIOX_API_KEY in " + APIKey.secretsFile(tools: .installed), monospaced: true)
            }
        }
        .onChange(of: pollInterval) { _, _ in model.schedulePoll() }
    }
}

/// The login item, through `SMAppService`. The app is a menu-bar accessory, so
/// this registers the whole bundle rather than a helper.
enum LoginItem {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// Returns a note when the change could not be made, so the pane can say
    /// what happened instead of quietly showing the wrong switch.
    static func set(_ enabled: Bool) -> String? {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            return nil
        } catch {
            return "could not change the login item: \(error.localizedDescription)"
        }
    }
}
