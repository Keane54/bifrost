// The arguments of the claude commands that start a session (docs/behaviour/actions.md, "The
// session commands"). The expected lists are literal, so the tests do not repeat the code.
import BifrostFoundation
import BifrostTestSupport
import Foundation
import Testing

@testable import BifrostSessions

// The row ID. A /clear made `now` the current ID. `job` is the original ID of the job, which
// starts with its short ID.
private let rowId = "f3a9c2d1-4b5e-4c6d-8e7f-0a1b2c3d4e5f"
private let now = "0b1c2d3e-4f50-4a6b-8c7d-9e0f1a2b3c4d"
private let job = "abcd1234-5061-4b7c-9d8e-0f1a2b3c4d5e"

private let settings = #"{"statusLine":{"type":"command","command":"true"}}"#

private func resumeArgs(_ id: String) -> [String] { ["--bg", "--resume", id] }

private func takeControlArgs(_ id: String) -> [String] {
    ["--bg", "--settings", settings, "--resume", id]
}

private func row(
    kind: SessionKind, currentId: String? = nil, resumeId: String? = nil
) -> SessionRow {
    var row = SessionRow.test(sessionId: rowId, kind: kind, state: .parked)
    row.currentId = currentId
    row.resumeId = resumeId
    return row
}

private func spec(
    name: String = "bifrost-test-n", model: ModelChoice = .haiku, mode: PermissionMode? = nil,
    prompt: String = "", worktree: Bool = false
) throws -> NewSessionSpec {
    try NewSessionSpec.check(
        cwd: "/p", name: name, model: model, permissionMode: mode, prompt: prompt,
        worktree: worktree
    ).get()
}

private func refusal(_ row: SessionRow) -> ActionRefusal? {
    do throws(ActionRefusal) {
        _ = try SessionCommandArgs.resume(row)
        return nil
    } catch {
        return error
    }
}

@Suite("the arguments of the session commands")
struct SessionCommandArgsTests {
    // A flag on a stopped background session starts a copy with a new session ID.
    @Test func resumeOfAnOwnedRowAddsNoFlag() throws {
        let owned = row(kind: .owned, resumeId: rowId)
        #expect(try SessionCommandArgs.resume(owned) == resumeArgs(rowId))
    }

    // A failed Take control parks a session that ran in the foreground. It has no saved options,
    // so the flag keeps the same session ID.
    @Test func resumeOfAParkedExternalRowUsesTheTakeControlArguments() throws {
        #expect(try SessionCommandArgs.resume(row(kind: .external)) == takeControlArgs(rowId))
    }

    @Test func takeControlHidesTheStatusline() {
        #expect(SessionCommandArgs.takeControl(SessionID(rowId)!) == takeControlArgs(rowId))
        #expect(SessionCommandArgs.noStatusLineSettings == settings)
    }

    // The ID of each command after a /clear: an owned row resumes its job, not the row ID or the
    // current ID, and an external row resumes its current ID.
    @Test func afterAClearResumePassesTheResumeIdOfAnOwnedRow() throws {
        let owned = row(kind: .owned, currentId: now, resumeId: job)
        #expect(try SessionCommandArgs.resume(owned) == resumeArgs(job))
    }

    @Test func afterAClearResumeOfAnExternalRowPassesTheCurrentId() throws {
        let external = row(kind: .external, currentId: now)
        #expect(try SessionCommandArgs.resume(external) == takeControlArgs(now))
    }

    // A resume by another ID would start a second job, so an owned row waits for its resume ID.
    @Test func anOwnedRowWithNoResumeIdIsRefused() {
        #expect(refusal(row(kind: .owned, currentId: now)) == .noResumeId)
    }

    // The ID goes into an argument, so it must be a session ID.
    @Test func anIdThatIsNotASessionIdIsRefused() {
        #expect(refusal(row(kind: .owned, resumeId: "abc")) == .badSessionId)
        #expect(refusal(row(kind: .owned, resumeId: "--help")) == .badSessionId)
        #expect(refusal(row(kind: .external, currentId: "-p")) == .badSessionId)
    }

    @Test func aNewSessionPutsTheFlagsFirstAndThePromptLast() throws {
        let full = try spec(name: "n1", mode: .plan, prompt: "Reply", worktree: true)
        #expect(
            SessionCommandArgs.newSession(full) == [
                "--bg", "--settings", settings, "--worktree", "n1", "--model", "haiku",
                "--permission-mode", "plan", "--name", "n1", "Reply",
            ])
        let plain = try spec(name: "n1", model: .standard)
        let expected = ["--bg", "--settings", settings, "--name", "n1"]
        #expect(SessionCommandArgs.newSession(plain) == expected)
    }

    @Test func theWorktreeNameComesFromTheSessionName() throws {
        let named = try spec(name: "My Name", model: .standard, worktree: true)
        #expect(
            SessionCommandArgs.newSession(named) == [
                "--bg", "--settings", settings, "--worktree", "my-name", "--name", "My Name",
            ])
    }

    // The statusline override is one argument, and every new session gets it.
    @Test func aNewSessionAlwaysHidesTheStatuslineWithOneArgument() throws {
        for model in ModelChoice.allCases {
            let args = SessionCommandArgs.newSession(try spec(model: model, prompt: "Reply"))
            #expect(Array(args.prefix(3)) == ["--bg", "--settings", settings])
            #expect(args.filter { $0 == "--settings" }.count == 1)
        }
        let json = try JSONSerialization.jsonObject(with: Data(settings.utf8)) as? [String: Any]
        let line = json?["statusLine"] as? [String: String]
        #expect(line == ["type": "command", "command": "true"])
    }

    // Each permission mode gives its flag. bypassPermissions is not a mode of the type.
    @Test(arguments: PermissionMode.allCases)
    func eachPermissionModeGivesItsFlag(mode: PermissionMode) throws {
        let args = SessionCommandArgs.newSession(try spec(model: .standard, mode: mode))
        #expect(
            args == [
                "--bg", "--settings", settings, "--permission-mode", mode.rawValue, "--name",
                "bifrost-test-n",
            ])
        #expect(!args.contains("bypassPermissions"))
    }

    // A prompt that holds a command name and more words is a prompt.
    @Test func aPromptWithACommandNameAndMoreWordsGoesLast() throws {
        let args = SessionCommandArgs.newSession(try spec(prompt: "update the docs"))
        #expect(args.last == "update the docs")
    }
}
