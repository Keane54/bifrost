// The rules of the Rename dialog (docs/behaviour/actions.md, "Rename"): the controls for a row,
// the plan of a save, the note when the check box cannot act, and what a send of /rename does.
import BifrostFoundation
import BifrostTestSupport
import Testing

@testable import BifrostSessions

private let owned = SessionRow.test(sessionId: "o", shortId: "abcd1234")
private let external = SessionRow.test(sessionId: "e", shortId: nil, kind: .external)
private let parked = SessionRow.test(sessionId: "p", state: .parked)
private let redBox: SessionRow = {
    var row = SessionRow.test(sessionId: "r", state: .needsYou)
    row.alert = .red(.prompt, since: 1)
    return row
}()

private func named(_ row: SessionRow, _ name: String) -> SessionRow {
    var row = row
    row.name = name
    return row
}

@Suite("the controls of the Rename dialog")
struct RenameControlsTests {
    @Test func theDialogTexts() {
        #expect(RenameRules.nameFieldLabel == "Name in Bifrost")
        #expect(RenameRules.claudeBoxLabel == "Also rename it in Claude Code")
        #expect(RenameRules.resetLabel == "Use the Claude Code name")
        #expect(
            RenameRules.lostNoteText
                == "Bifrost can't rename it in Claude Code right now. Save keeps the name in "
                + "Bifrost only.")
    }

    @Test func theClaudeCodeBoxShowsOnlyForAnOwnedRowThatIsNotParked() {
        #expect(RenameRules.controls(owned).claudeBox == .enabled)
        #expect(RenameRules.controls(external).claudeBox == .hidden)
        #expect(RenameRules.controls(parked).claudeBox == .hidden)
    }

    @Test func aRedBoxOfAPromptTurnsTheBoxOffWithItsReason() {
        let box = RenameRules.controls(redBox).claudeBox
        #expect(box == .disabled(.input(.prompt)))
        #expect(box.reason == "Answer the prompt in the chat window first.")
        // An escalated box or an error box does not block the rename.
        var escalated = redBox
        escalated.alert = .red(.escalated, since: 1)
        #expect(RenameRules.controls(escalated).claudeBox == .enabled)
    }

    @Test func theBoxIsOffWhileTheShortIdIsMissing() {
        let box = RenameRules.controls(.test(sessionId: "n", shortId: nil)).claudeBox
        #expect(box == .disabled(.noShortId))
        #expect(box.reason == "Waiting for the session ID.")
        #expect(RenameControls.Box.enabled.reason == nil)
        #expect(RenameControls.Box.hidden.reason == nil)
    }

    @Test func theResetButtonShowsOnlyForALocalName() {
        #expect(!RenameRules.controls(owned).showReset)
        #expect(RenameRules.controls(named(owned, "Work")).showReset)
        #expect(RenameRules.controls(named(external, "Work")).showReset)
    }
}

@Suite("the plan of a rename")
struct RenamePlanTests {
    @Test func aSaveKeepsATrimmedLocalName() {
        #expect(
            RenameRules.plan(owned, name: "  Work  ", alsoClaude: false)
                == .success(.local(alias: "Work")))
    }

    @Test func anEmptyNameClearsTheLocalName() {
        #expect(
            RenameRules.plan(external, name: "   ", alsoClaude: false)
                == .success(.local(alias: nil)))
    }

    @Test func aLocalNameRefusesHiddenCharactersAndALongName() {
        #expect(
            RenameRules.plan(owned, name: "a\u{1b}b", alsoClaude: false)
                == .failure(.alias(.control)))
        let long = RenameRules.plan(
            owned, name: String(repeating: "x", count: 65), alsoClaude: false)
        #expect(long == .failure(.alias(.tooLong)))
        #expect(
            ActionRefusal.alias(.tooLong).message
                == "The name is too long. The maximum is 64 characters.")
        // The limit counts Characters, so 64 emoji fit.
        #expect(
            RenameRules.plan(owned, name: String(repeating: "🚀", count: 64), alsoClaude: false)
                == .success(.local(alias: String(repeating: "🚀", count: 64))))
    }

    // The Claude Code name changes, so the local name goes.
    @Test func alsoRenameSendsRenameAndClearsTheLocalName() {
        #expect(
            RenameRules.plan(named(owned, "Old"), name: "Work", alsoClaude: true)
                == .success(.claude(send: "/rename Work")))
    }

    @Test func alsoRenameNeedsAName() {
        #expect(
            RenameRules.plan(owned, name: " ", alsoClaude: true)
                == .failure(.input(.noName)))
        #expect(
            RenameRules.plan(owned, name: String(repeating: "x", count: 65), alsoClaude: true)
                == .failure(.input(.nameTooLong)))
    }

    @Test func alsoRenameGivesTheReasonOfAHiddenBox() {
        #expect(RenameRules.plan(parked, name: "Work", alsoClaude: true) == .failure(.parked))
        #expect(RenameRules.plan(external, name: "Work", alsoClaude: true) == .failure(.external))
    }

    @Test func alsoRenameGivesTheReasonOfABoxThatIsOff() {
        #expect(
            RenameRules.plan(redBox, name: "Work", alsoClaude: true)
                == .failure(.input(.prompt)))
        #expect(
            RenameRules.plan(.test(shortId: nil), name: "Work", alsoClaude: true)
                == .failure(.noShortId))
    }
}

@Suite("the check box that cannot act")
struct RenameLostNoteTests {
    @Test func theBoxCountsOnlyWhenItIsOnAndUsable() {
        #expect(RenameRules.effectiveAlsoClaude(owned, alsoClaude: true))
        #expect(!RenameRules.effectiveAlsoClaude(owned, alsoClaude: false))
        #expect(!RenameRules.effectiveAlsoClaude(redBox, alsoClaude: true))
        #expect(!RenameRules.effectiveAlsoClaude(parked, alsoClaude: true))
    }

    @Test func theNoteShowsWhenTheBoxWasOnButCannotActNow() {
        #expect(RenameRules.lostNote(redBox, alsoClaude: true) == RenameRules.lostNoteText)
        #expect(RenameRules.lostNote(redBox, alsoClaude: false) == nil)
        #expect(RenameRules.lostNote(owned, alsoClaude: true) == nil)
    }
}

// A /rename changes the Claude Code name, so it clears the local name, as the check box of the
// Rename dialog does (ruling of 2026-11-06). It does not go into the recent slash commands,
// because a click on it in the submenu would give its name to another session.
@Suite("a send of /rename")
struct AfterSendTests {
    @Test(arguments: ["/rename work", "  /rename work  ", "/rename", "/rename\twork"])
    func aRenameClearsTheLocalNameAndIsNotRemembered(text: String) {
        let after = RenameRules.afterSend(text)
        #expect(after.clearAlias)
        #expect(!after.rememberSlash)
    }

    @Test(arguments: ["/renamex", "/compact", "please /rename it", "hello", "/rename\u{301}"])
    func anyOtherSendKeepsTheLocalNameAndIsRemembered(text: String) {
        let after = RenameRules.afterSend(text)
        #expect(!after.clearAlias)
        #expect(after.rememberSlash)
    }
}
