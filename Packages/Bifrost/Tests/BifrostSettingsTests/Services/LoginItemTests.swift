import ServiceManagement
import Testing

@testable import BifrostFoundation
@testable import BifrostSettings

// The rule of the login item and the reasons of a failed change. No test makes SystemLoginItem,
// so no test reads or changes the real login item of an app.

private func identity(_ bundleID: String) throws -> AppIdentity {
    try #require(AppIdentity(bundleID: bundleID))
}

@Suite("the login item")
struct LoginItemTests {
    // A development build saves Start at login and never registers a login item, with a test
    // home or with the real home.
    @Test func theDevBuildNeverRegistersALoginItem() throws {
        let development = try identity("com.example.app" + AppIdentity.developmentSuffix)
        #expect(!LoginItemRule.allowed(identity: development, testHome: false))
        #expect(!LoginItemRule.allowed(identity: development, testHome: true))
    }

    @Test func aReleaseIdentityWithATestHomeRegistersNothing() throws {
        #expect(!LoginItemRule.allowed(identity: try identity("com.example.app"), testHome: true))
    }

    @Test func onlyAReleaseIdentityWithNoTestHomeHasALoginItem() throws {
        #expect(LoginItemRule.allowed(identity: try identity("com.example.app"), testHome: false))
    }

    // The status of the login item after a failed change gives the reason. With no reason in the
    // status, the error code of the call gives it.
    @Test func theStatusAfterAFailedChangeGivesTheReason() {
        let deniedByUser = Int(kSMErrorLaunchDeniedByUser)
        let badSignature = Int(kSMErrorInvalidSignature)
        #expect(LoginItemError(status: .requiresApproval, code: badSignature) == .needsApproval)
        #expect(LoginItemError(status: .notFound, code: badSignature) == .notFound)
        #expect(LoginItemError(status: .notRegistered, code: deniedByUser) == .needsApproval)
        #expect(
            LoginItemError(status: .notRegistered, code: badSignature)
                == .failed(code: badSignature))
        #expect(LoginItemError(status: .enabled, code: badSignature) == .failed(code: badSignature))
    }

    @Test func eachReasonHasAFriendlyText() {
        #expect(
            LoginItemError.needsApproval.message
                == "To open Bifrost at login, allow it in System Settings > General > "
                + "Login Items & Extensions.")
        #expect(
            LoginItemError.notFound.message
                == "macOS can't find this copy of Bifrost, so it can't open it at login. Move "
                + "Bifrost to your Applications folder, open it from there, and try again.")
        #expect(
            LoginItemError.failed(code: 3).message
                == "Bifrost couldn't change its login item. Try again, or set it in System "
                + "Settings > General > Login Items & Extensions.")
    }
}
