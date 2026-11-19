import BifrostFoundation
import Foundation

// Reads the access token of the Claude Code login from the macOS Keychain
// (docs/behaviour/usage.md, "The account values"). SECURITY: the read never logs, stores or
// returns the Keychain text. It gives the access token only to its caller, in memory. It uses
// only the access token and never keeps the refresh token. A test gives a fake runner, so no
// test reads the Keychain.
package enum AccessToken {
    package static let securityPath = "/usr/bin/security"
    // The Keychain item of the Claude Code login.
    package static let keychainService = "Claude Code-credentials"
    // Fixed arguments. -w prints the secret text, and the read keeps it in memory only.
    package static let arguments = ["find-generic-password", "-s", keychainService, "-w"]
    package static let timeout = Duration.seconds(10)
    // A token that ends within this time could expire during the request, so it counts as
    // expired.
    package static let expiryMargin = Duration.seconds(60)

    // The access token, or nil for "no token". nil covers a failed command, bad JSON, a missing
    // field and a token that has expired. The read never throws and logs nothing, so no error
    // text can hold the Keychain data.
    package static func read(_ runner: any CommandRunner, now: Date) async -> String? {
        let result = await runner.run(securityPath, arguments, timeout: timeout)
        guard result.succeeded else { return nil }
        return token(in: result.stdout, now: now)
    }

    // The access token in the JSON of the login, or nil.
    private static func token(in text: String, now: Date) -> String? {
        guard
            let json = try? JSONDecoder().decode(JSONValue.self, from: Data(text.utf8)),
            let login = json.object?["claudeAiOauth"]?.object,
            let token = login["accessToken"]?.string, !token.isEmpty,
            // A token with no expiry time is another shape.
            let expiresAt = login["expiresAt"]?.finiteNumber
        else { return nil }
        // The expiry time is in milliseconds since 1970. The compare uses Double, so a far time
        // cannot overflow.
        let nowMs = now.timeIntervalSince1970 * 1000
        guard expiresAt > nowMs + expiryMargin / .milliseconds(1) else { return nil }
        return token
    }
}
