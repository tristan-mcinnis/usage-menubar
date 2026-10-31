import Foundation
import ServiceManagement

/// Open at login through `SMAppService.mainApp` (macOS 13+): the Settings
/// switch and the `login-item` command install.sh runs.
///
/// The service is the bundle of the running executable, so these calls only
/// mean something when run from inside the installed `Usage.app`. Unlike a
/// System Events login item, this needs no Automation grant, so it cannot fail
/// or stall on a consent prompt the way the old install step did.
///
///     usage-bar login-item register|status|unregister
enum LoginItem {

    enum State: Equatable {
        case notRegistered, enabled, requiresApproval, notFound

        init(_ status: SMAppService.Status) {
            switch status {
            case .enabled: self = .enabled
            case .requiresApproval: self = .requiresApproval
            case .notFound: self = .notFound
            case .notRegistered: self = .notRegistered
            @unknown default: self = .notRegistered
            }
        }

        var summary: String {
            switch self {
            case .enabled: "enabled: Usage opens at login"
            case .notRegistered: "not registered"
            case .requiresApproval:
                "needs approval: turn Usage on in System Settings > General > Login Items"
            case .notFound: "not found: run this from the installed Usage.app"
            }
        }
    }

    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// The Settings switch. Returns a note when the change could not be made,
    /// so the pane can say what happened instead of quietly showing the wrong
    /// switch.
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

    enum Verb: String, CaseIterable {
        case register, status, unregister
    }

    static let usage = "usage: usage-bar login-item register|status|unregister"

    /// Runs one verb and returns the process exit code: 0 when the login item
    /// ends in the state the verb asked for, 1 when it does not, 64 on bad usage.
    static func run(_ arguments: [String]) -> Int32 {
        guard arguments.count == 1, let verb = Verb(rawValue: arguments[0]) else {
            FileHandle.standardError.write(Data((usage + "\n").utf8))
            return 64
        }
        let service = SMAppService.mainApp
        do {
            switch verb {
            case .status:
                print(State(service.status).summary)
                return 0
            case .register:
                // Idempotent: registering an enabled service again is a no-op.
                try service.register()
                let state = State(service.status)
                print(state.summary)
                return state == .enabled ? 0 : 1
            case .unregister:
                if service.status != .notRegistered {
                    try service.unregister()
                }
                let state = State(service.status)
                print(state.summary)
                return state == .notRegistered ? 0 : 1
            }
        } catch {
            FileHandle.standardError.write(Data("login item: \(error.localizedDescription)\n".utf8))
            return 1
        }
    }
}
