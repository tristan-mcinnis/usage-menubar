import AppKit
import XCTest
@testable import UsageBar

/// The keys the panel controller routes, driven through the real controller
/// and a real model without opening a window or reading a provider.
@MainActor
final class MenuPanelKeysTests: XCTestCase {

    private func key(_ code: UInt16, _ chars: String = "", flags: NSEvent.ModifierFlags = []) throws -> KeyPress {
        let event = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
            windowNumber: 0, context: nil, characters: chars, charactersIgnoringModifiers: chars,
            isARepeat: false, keyCode: code
        ))
        return KeyPress(event)
    }

    private func makeController() -> (MenuBarPanelController, PanelModel) {
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("MenuPanelKeysTests-\(UUID().uuidString)")
        let model = PanelModel(
            defaults: UserDefaults(suiteName: "MenuPanelKeysTests-\(UUID().uuidString)")!,
            samplesPath: temp.appendingPathComponent("samples.json").path,
            readingsPath: temp.appendingPathComponent("readings.json").path,
            retriesPath: temp.appendingPathComponent("retries.json").path
        )
        return (MenuBarPanelController(model: model), model)
    }

    func testEscapeCloses() throws {
        let (controller, model) = makeController()
        var closed = 0
        model.onClose = { closed += 1 }
        XCTAssertTrue(controller.handle(try key(53)))
        XCTAssertEqual(closed, 1)
    }

    func testDownArrowMovesTheSelection() throws {
        let (controller, model) = makeController()
        XCTAssertTrue(controller.handle(try key(125)))
        XCTAssertEqual(model.selection, 1)
    }

    func testSettingsAndQuitChords() throws {
        let (controller, model) = makeController()
        var settings = 0, quit = 0
        model.onOpenSettings = { settings += 1 }
        model.onQuit = { quit += 1 }
        XCTAssertTrue(controller.handle(try key(43, ",", flags: .command)))
        XCTAssertTrue(controller.handle(try key(12, "q", flags: .command)))
        XCTAssertEqual(settings, 1)
        XCTAssertEqual(quit, 1)
    }

    func testUnmappedKeysReachTheFocusedView() throws {
        let (controller, _) = makeController()
        XCTAssertFalse(controller.handle(try key(0, "a")))
        XCTAssertFalse(controller.handle(try key(6, "z", flags: .command)))
    }
}
