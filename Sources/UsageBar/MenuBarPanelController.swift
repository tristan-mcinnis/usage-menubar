import AppKit
import HouseUIKit

extension PanelModel: MenuPanelModeling {}

/// Usage's panel window. The panel is rebuilt on each open so countdowns are
/// computed then, and it grows and shrinks as readings land.
@MainActor
final class MenuBarPanelController: MenuPanelController<MenuBarPanelView, PanelModel> {
    init(model: PanelModel) {
        super.init(model: model, width: MenuBarPanelView.width, rootView: { MenuBarPanelView(model: model) })
    }

    override func panelWillShow() {
        model.selection = 0
        model.confirmation = nil
        model.panelOpened()
        // Countdowns are computed at open; the panel is rebuilt each time.
        hosting?.rootView = MenuBarPanelView(model: model, now: Date())
    }

    override func panelDidClose() {
        model.isPanelOpen = false
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

    /// The command chords are handled here rather than as SwiftUI shortcuts so
    /// they work wherever focus is.
    override func handle(_ key: PanelKeyPress) -> Bool {
        if key.flags.contains(.command) {
            switch key.characters?.lowercased() {
            case "r": model.refresh(); return true
            case ",": model.onOpenSettings(); return true
            case "q": model.onQuit(); return true
            default: return false
            }
        }
        return super.handle(key)
    }
}
