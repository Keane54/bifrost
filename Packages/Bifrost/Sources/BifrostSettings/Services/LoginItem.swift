import BifrostFoundation
import Foundation
import OSLog
import ServiceManagement

// The login item of the app: Start at login (docs/behaviour/settings.md, "Start at login"). Only
// a release app with no test home has one (LoginItemRule). In each other app the setting saves
// and nothing registers.

// Why a change of the login item failed. message is the friendly text.
public enum LoginItemError: Error, Sendable, Equatable {
    // The login item is registered, but the user did not allow it in System Settings.
    case needsApproval
    // macOS cannot find the app, for example a copy that does not run from a fixed place.
    case notFound
    // Another failure, with the error code of ServiceManagement.
    case failed(code: Int)

    // The reason from the status of the login item after the failed call, else from the error
    // code of the call.
    package init(status: SMAppService.Status, code: Int) {
        switch status {
        case .requiresApproval: self = .needsApproval
        case .notFound: self = .notFound
        default: self = code == kSMErrorLaunchDeniedByUser ? .needsApproval : .failed(code: code)
        }
    }

    package var message: String {
        switch self {
        case .needsApproval:
            "To open Bifrost at login, allow it in System Settings > General > Login Items & "
                + "Extensions."
        case .notFound:
            "macOS can't find this copy of Bifrost, so it can't open it at login. Move Bifrost to "
                + "your Applications folder, open it from there, and try again."
        case .failed:
            "Bifrost couldn't change its login item. Try again, or set it in System Settings > "
                + "General > Login Items & Extensions."
        }
    }
}

// The login item that the effects of the settings change. A test gives a fake, so no test
// changes a real login item.
@MainActor
public protocol LoginItemService: AnyObject {
    // True when macOS opens the app at login.
    var isOn: Bool { get }
    // Register (true) or remove (false) the login item.
    func set(_ on: Bool) throws(LoginItemError)
}

// The login item of the running app, through SMAppService.mainApp. Only the app delegate makes
// it, and only when LoginItemRule allows it. No test makes it.
@MainActor
public final class SystemLoginItem: LoginItemService {
    private static let logger = Logger(bifrost: "login-item")

    public init() {}

    public var isOn: Bool { SMAppService.mainApp.status == .enabled }

    // A login item that waits for the approval of the user is registered. So off removes it, and
    // on gives the reason and registers nothing again.
    public func set(_ on: Bool) throws(LoginItemError) {
        let service = SMAppService.mainApp
        let registered = service.status == .enabled || service.status == .requiresApproval
        if on != registered {
            do {
                if on { try service.register() } else { try service.unregister() }
            } catch {
                // The log keeps the real domain, code and status, so a check by hand can see
                // them.
                let failure = error as NSError
                let (domain, code, status) = (failure.domain, failure.code, service.status)
                let raw = status.rawValue
                Self.logger.error(
                    """
                    macOS refused the change of the login item: \(domain, privacy: .public) \
                    \(code, privacy: .public), status \(raw, privacy: .public).
                    """)
                throw LoginItemError(status: status, code: code)
            }
        }
        if on && service.status == .requiresApproval { throw .needsApproval }
    }

    // Open the Login Items of System Settings, where the user allows a login item that waits
    // for the approval. It registers nothing. Only the button of Settings > General calls it.
    package static func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}

// Which app may have a login item. A development build never becomes a login item (user
// decision, 2026-11-16), and neither does an app with a test home. So only a release identity
// with no test home uses SystemLoginItem.
public enum LoginItemRule {
    public static func allowed(identity: AppIdentity, testHome: Bool) -> Bool {
        identity.variant == .release && !testHome
    }
}
