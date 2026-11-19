// The attach rules (docs/behaviour/pty.md): the target of a chat window, the check of a PTY open,
// and the short ID that is the only argument of claude attach.
import BifrostFoundation
import BifrostTestSupport
import Testing

@testable import BifrostSessions

// An owned, idle session "alpha" with the short ID aaaaaaaa.
private func row(
    sessionId: String = "s1", shortId: ShortID? = "aaaaaaaa", kind: SessionKind = .owned,
    cwd: String = "/p", state: SessionState = .idle
) -> SessionRow {
    SessionRow(
        sessionId: sessionId, shortId: shortId, name: "alpha", claudeName: "alpha", kind: kind,
        cwd: cwd, status: .idle, state: state, lastActivity: 1, startedAt: 1)
}

private let sessionID: SessionID = "f3a9c2d1-4b5e-4c6d-8e7f-0a1b2c3d4e5f"
private let sessionS = sessionID.text
private let sessionT = "a1b2c3d4-0000-4000-8000-000000000000"

@Suite("the short ID")
struct ShortIDTests {
    @Test(
        "a short ID is 8 lower-case hex digits",
        arguments: [
            ("2f493bf0", true), ("00000000", true), ("abcdef12", true),
            ("ABCDEF12", false), ("2f493bf", false), ("2f493bf01", false), ("2f493bg0", false),
            ("", false), ("2f493bf0\n", false), (" 2f493bf0", false), ("٣٣٣٣٣٣٣٣", false),
            ("-2f493bf", false), ("--help00", false), ("-0000000", false),
        ])
    func form(text: String, expected: Bool) {
        // A String value, not a literal: the test support makes a literal a ShortID at once.
        #expect((ShortID(text) != nil) == expected)
        #expect(ShortID(text)?.text == (expected ? text : nil))
    }

    // A short ID is the only argument of claude attach after "attach". An id of claude agents
    // --json that starts with "-" is no short ID, so its row waits for a short ID and no PTY
    // opens: the text can never reach claude as an option.
    @Test(arguments: ["-rf", "--help", "-0000000", "--resume", "-", ""])
    func anIdThatIsNotAShortIDNeverReachesClaudeAttach(id: String) {
        let list = AgentList(output: 
            #"[{"sessionId":"\#(sessionS)","kind":"background","id":"\#(id)","pid":5}]"#)
        #expect(list.entries.first?.id == nil)
        var registry = SessionRegistry(store: RegistryStore(), escalation: .seconds(600))
        registry.applyAgents(list.entries, sampledAt: 1)
        let item = registry.rows().first
        #expect(item?.shortId == nil)
        #expect(AttachRules.target(item, loaded: true) == .refused(.waitingForID))
    }
}

@Suite("the check of a PTY open")
struct AttachCheckTests {
    private let rows = [
        row(sessionId: sessionS, shortId: "abcd1234"),
        row(sessionId: sessionT, shortId: "ef567890"),
    ]

    @Test func aChatAttachesToItsOwnSessionInTheFolderOfTheRow() throws {
        let checked = try AttachRules.check(rows, view: .chat(sessionID), shortId: "abcd1234")
        #expect(checked.view == .chat(sessionID))
        #expect(checked.shortId == "abcd1234")
        #expect(checked.directory == "/p")
    }

    // The hidden attach of the session input opens in the root folder.
    @Test func theHiddenAttachOfTheSessionInputOpensInTheRootFolder() throws {
        let checked = try AttachRules.check(rows, view: .input(sessionS), shortId: "abcd1234")
        #expect(checked.view == .input(sessionS))
        #expect(checked.directory == "/")
    }

    @Test func theShortIDOfAnotherSessionIsRefused() {
        for view in [PTYView.chat(sessionID), .input(sessionS)] {
            #expect(throws: AttachRefusal.otherSession) {
                try AttachRules.check(rows, view: view, shortId: "ef567890")
            }
        }
    }

    @Test func aParkedOrExternalRowOrAnUnknownShortIDIsRefused() {
        for changed in [
            row(sessionId: sessionS, shortId: "abcd1234", state: .parked),
            row(sessionId: sessionS, shortId: "abcd1234", kind: .external),
        ] {
            #expect(throws: AttachRefusal.notOwnedAttach) {
                try AttachRules.check([changed], view: .chat(sessionID), shortId: "abcd1234")
            }
        }
        #expect(throws: AttachRefusal.notOwnedAttach) {
            try AttachRules.check(rows, view: .chat(sessionID), shortId: "00000000")
        }
    }

    // Two rows with one short ID: no attach, because the input could go to either session.
    @Test func aShortIDOfTwoRowsIsRefused() {
        let shared = [
            row(sessionId: sessionS, shortId: "abcd1234"),
            row(sessionId: sessionT, shortId: "abcd1234"),
        ]
        #expect(throws: AttachRefusal.notOwnedAttach) {
            try AttachRules.check(shared, view: .chat(sessionID), shortId: "abcd1234")
        }
    }

    @Test func eachStateThatRunsAttachesAndAParkedRowDoesNot() throws {
        for state in [SessionState.idle, .working, .needsYou, .error] {
            let item = row(sessionId: sessionS, cwd: "/wt/a", state: state)
            let checked = try AttachRules.check([item], view: .chat(sessionID), shortId: "aaaaaaaa")
            #expect(checked.directory == "/wt/a")
        }
        let parked = row(sessionId: sessionS, state: .parked)
        #expect(throws: AttachRefusal.notOwnedAttach) {
            try AttachRules.check([parked], view: .chat(sessionID), shortId: "aaaaaaaa")
        }
    }

    @Test("a row without a cwd attaches in the root folder")
    func theRootFolder() throws {
        let item = row(sessionId: sessionS, cwd: "")
        let checked = try AttachRules.check([item], view: .chat(sessionID), shortId: "aaaaaaaa")
        #expect(checked.directory == "/")
    }
}

@Suite("the attach target of a chat window")
struct AttachTargetTests {
    @Test func aWindowWaitsForTheList() {
        #expect(AttachRules.target(nil, loaded: false) == .refused(.waitingForList))
    }

    @Test("each row that cannot attach gives its own reason")
    func theReasons() {
        let fail = { (row: SessionRow?) in AttachRules.target(row, loaded: true) }
        #expect(fail(nil) == .refused(.gone))
        #expect(fail(row(sessionId: "x", kind: .external)) == .refused(.external))
        #expect(fail(row(sessionId: "x", state: .parked)) == .refused(.parked))
        #expect(fail(row(sessionId: "x", shortId: nil)) == .refused(.waitingForID))
    }

    @Test func theShortIDAndTheFolderOfTheRow() {
        let ready = AttachRules.target(row(sessionId: "x", cwd: "/p"), loaded: true)
        #expect(ready == .ready(shortId: "aaaaaaaa", directory: "/p"))
        let root = AttachRules.target(row(sessionId: "x", cwd: ""), loaded: true)
        #expect(root == .ready(shortId: "aaaaaaaa", directory: "/"))
    }

    // A chat window shows these texts.
    @Test func theTextsOfTheReasons() {
        #expect(AttachRefusal.waitingForList.message == "Waiting for the session list.")
        #expect(AttachRefusal.gone.message == "This session isn't in the list any more.")
        #expect(
            AttachRefusal.external.message
                == "This session runs in another terminal, so Bifrost can only show its status.")
        #expect(AttachRefusal.parked.message == "This session is parked. Resume it first.")
        #expect(AttachRefusal.waitingForID.message == "Waiting for the session ID.")
        #expect(
            AttachRefusal.claudeNotFound.message
                == "Bifrost can't find Claude Code. Install it, then open Bifrost again.")
    }
}
