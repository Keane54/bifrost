// The read of the access token (docs/behaviour/usage.md, "The account values"). Safety: each
// test gives a fake runner, so no test runs security or reads the Keychain. Each token is fake.
import BifrostFoundation
import BifrostSessions
import BifrostTestSupport
import Foundation
import Testing

private let now = Date(timeIntervalSince1970: 1_794_016_800)
private let nowMs = 1_794_016_800_000
private let fakeToken = "fake-access-token-for-tests"

// The output of the Keychain read: the JSON of the login and a line end, as security -w prints
// it. A nil expiresAt leaves the field out.
private func keychainText(
    token: JSONValue = .string(fakeToken), expiresAt: JSONValue? = .int(nowMs + 3_600_000)
) throws -> String {
    var login: [String: JSONValue] = [
        "accessToken": token, "refreshToken": "fake-refresh-token", "scopes": ["user:inference"],
    ]
    if let expiresAt { login["expiresAt"] = expiresAt }
    let json = JSONValue.object(["claudeAiOauth": .object(login)])
    return String(decoding: try JSONEncoder().encode(json), as: UTF8.self) + "\n"
}

private func read(_ text: String, end: ExecEnd = .exited(0)) async -> String? {
    await AccessToken.read(FakeRunner(ExecResult(end, stdout: text)), now: now)
}

private let later: JSONValue = .int(nowMs + 3_600_000)

// Logins of another shape: a token and an expiry time. nil leaves the expiry time out.
private let badLogins: [(JSONValue, JSONValue?)] = [
    // The token must be a text that is not empty.
    (.string(""), later), (.int(5), later), (.null, later), (["t"], later),
    // A token with no expiry time is another shape.
    (.string(fakeToken), nil), (.string(fakeToken), .null),
    (.string(fakeToken), .string("\(nowMs + 3_600_000)")), (.string(fakeToken), .bool(true)),
    (.string(fakeToken), ["n": 1]),
]

@Suite("access token")
struct AccessTokenTests {
    @Test func theReadRunsSecurityWithFixedArguments() async throws {
        let runner = FakeRunner(ExecResult(.exited(0), stdout: try keychainText()))
        _ = await AccessToken.read(runner, now: now)
        #expect(
            runner.calls == [
                FakeRunner.Call(
                    file: "/usr/bin/security",
                    args: ["find-generic-password", "-s", "Claude Code-credentials", "-w"],
                    timeout: .seconds(10))
            ])
        #expect(runner.commands.first?.input == nil)
        #expect(runner.commands.first?.environment == nil)
        #expect(AccessToken.expiryMargin == .seconds(60))
    }

    @Test func aGoodLoginGivesTheAccessToken() async throws {
        #expect(await read(try keychainText()) == fakeToken)
        // An expiry time with a fraction is still a number.
        #expect(await read(try keychainText(expiresAt: .double(1_794_020_400_000.5))) == fakeToken)
    }

    @Test(arguments: [
        ExecEnd.exited(1), .exited(44), .timedOut, .overflow, .cancelled, .notStarted, .signal(9),
    ])
    func aFailedReadGivesNoToken(end: ExecEnd) async throws {
        #expect(await read(try keychainText(), end: end) == nil)
    }

    @Test(arguments: [
        "", "\n", "not json", "null", "[]", "\"text\"", "{}", "{\"claudeAiOauth\":null}",
        "{\"claudeAiOauth\":[]}", "{\"claudeAiOauth\":\"x\"}", "{\"claudeAiOauth\":{}}",
        // A number that a Double cannot hold makes the whole text bad JSON.
        "{\"claudeAiOauth\":{\"accessToken\":\"t\",\"expiresAt\":1e400}}",
    ])
    func textThatIsNotALoginGivesNoToken(text: String) async {
        #expect(await read(text) == nil)
    }

    @Test(arguments: badLogins)
    func aLoginOfAnotherShapeGivesNoToken(token: JSONValue, expiresAt: JSONValue?) async throws {
        #expect(await read(try keychainText(token: token, expiresAt: expiresAt)) == nil)
    }

    // A token that ends within the margin could expire during the request.
    @Test func aTokenThatEndsWithinAMinuteHasExpired() async throws {
        #expect(await read(try keychainText(expiresAt: .int(nowMs + 60_001))) == fakeToken)
        #expect(await read(try keychainText(expiresAt: .int(nowMs + 60_000))) == nil)
        #expect(await read(try keychainText(expiresAt: .int(nowMs))) == nil)
        #expect(await read(try keychainText(expiresAt: .int(nowMs - 1))) == nil)
        #expect(await read(try keychainText(expiresAt: .double(-1e300))) == nil)
        #expect(await read(try keychainText(expiresAt: .double(1e300))) == fakeToken)
    }
}
