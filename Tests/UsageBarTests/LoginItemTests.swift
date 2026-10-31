import ServiceManagement
import XCTest
@testable import UsageBar

/// The login-item command's mapping and argument rules. Nothing here registers
/// or unregisters a real login item.
final class LoginItemTests: XCTestCase {

    func testEveryServiceStatusMapsToADistinctState() {
        let states = [
            SMAppService.Status.notRegistered, .enabled, .requiresApproval, .notFound,
        ].map(LoginItem.State.init)
        XCTAssertEqual(states, [.notRegistered, .enabled, .requiresApproval, .notFound])
        XCTAssertEqual(Set(states.map(\.summary)).count, states.count)
    }

    func testApprovalStateNamesTheManualStep() {
        XCTAssertTrue(LoginItem.State.requiresApproval.summary.contains("System Settings > General > Login Items"))
    }

    func testBadUsageIsRejectedWithoutTouchingTheService() {
        XCTAssertEqual(LoginItem.run([]), 64)
        XCTAssertEqual(LoginItem.run(["enable"]), 64)
        XCTAssertEqual(LoginItem.run(["register", "extra"]), 64)
    }

    func testVerbsAreTheThreeTheInstallerUses() {
        XCTAssertEqual(LoginItem.Verb.allCases.map(\.rawValue), ["register", "status", "unregister"])
    }
}
