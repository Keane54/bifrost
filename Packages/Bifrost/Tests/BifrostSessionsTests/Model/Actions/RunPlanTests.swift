// The plan of a session action (docs/behaviour/actions.md, "What an action does"): what the
// runner does for each action, the focus request of the send box, the open from a notification
// and the chat window after a failed Delete.
import BifrostFoundation
import BifrostTestSupport
import Testing

@testable import BifrostSessions

private func context(
    labels: LabelSet = .plain, running: Bool = false, slashFavourites: [String] = ["/compact"]
) -> ActionContext {
    ActionContext(
        chatOpen: true, folderShared: false,
        apps: [ProjectApp(id: .finder, label: "Finder"), ProjectApp(id: .warp, label: "Warp")],
        labels: labels, running: running, slashFavourites: slashFavourites, slashRecent: [])
}

private let infoId: SessionID = "0f8fad5b-d9cb-469f-a165-70867728950e"
private let owned = SessionRow.test(sessionId: "o", shortId: "abcd1234", name: "fix-a")
private let working = SessionRow.test(
    sessionId: "o", shortId: "abcd1234", name: "fix-a", state: .working)
private let external: SessionRow = {
    var row = SessionRow.test(
        sessionId: "e", shortId: nil, name: "ext-a", kind: .external, pid: 4242,
        cwd: "/Users/o/Developer/app")
    row.terminalApp = "Warp"
    return row
}()
private let parked = SessionRow.test(sessionId: "p", state: .parked)
private let redBox: SessionRow = {
    var row = SessionRow.test(sessionId: "r", shortId: "abcd1234", state: .needsYou)
    row.alert = .red(.prompt, since: 1)
    return row
}()

private func watched(_ colour: WatchColour) -> SessionRow {
    var row = owned
    row.watch = RowWatch(colour: colour, order: 0)
    return row
}

private func plan(
    _ id: ActionID, _ row: SessionRow?, _ ctx: ActionContext = context(), arg: MenuArg? = nil
) -> RunPlan {
    RunPlan.plan(id, row, ctx, arg: arg)
}

private func call(_ call: ApiCall) -> RunPlan {
    .call(call, confirm: nil, after: .none)
}

@Suite("the plan of an action")
struct RunPlanTests {
    @Test func aDisabledActionGivesNone() {
        #expect(plan(.sendMessage, redBox) == .none)
        #expect(plan(.stop, owned, context(running: true)) == .none)
        #expect(plan(.open, nil) == .none)
    }

    @Test func openAndCloseWindowChangeTheChatWindowAndRenameOpensTheDialog() {
        #expect(plan(.open, owned) == .openChat)
        #expect(plan(.closeWindow, owned) == .closeChat)
        #expect(plan(.rename, owned) == .rename)
    }

    @Test func sendMessageFocusesTheSendBoxWithNoText() {
        #expect(plan(.sendMessage, owned) == .focusSend(slash: false))
    }

    @Test func runSlashCommandWithNoCommandFocusesTheSendBoxWithASlash() {
        #expect(plan(.runSlash, owned) == .focusSend(slash: true))
        #expect(plan(.runSlash, owned, arg: .otherSlash) == .focusSend(slash: true))
        // A text that is not a command, or a slash alone, sends nothing.
        for arg: MenuArg in [.slash("/"), .slash("compact"), .slash(""), .app(.finder)] {
            #expect(plan(.runSlash, owned, arg: arg) == .focusSend(slash: true))
        }
    }

    @Test func runSlashCommandWithACommandSendsIt() {
        #expect(plan(.runSlash, owned, arg: .slash("/compact")) == .send("/compact"))
        #expect(plan(.runSlash, owned, arg: .slash("/review 12")) == .send("/review 12"))
    }

    // One click sends /compact, with no confirmation (user decision, 2026-11-10).
    @Test func compactSendsExactlySlashCompact() {
        #expect(RunPlan.compactCommand == "/compact")
        #expect(plan(.compact, owned) == .send("/compact"))
        #expect(plan(.compact, owned, context(slashFavourites: [])) == .send("/compact"))
        // An argument from a menu does not change the text.
        for arg: MenuArg in [.slash("/clear"), .otherSlash, .priority(.p2)] {
            #expect(plan(.compact, owned, arg: arg) == .send("/compact"))
        }
    }

    @Test func compactSendsNothingWhileTheSessionWorksWithAPromptOrForAnotherClass() {
        for row in [working, redBox, external, parked] {
            #expect(plan(.compact, row) == .none)
        }
        #expect(plan(.compact, nil) == .none)
    }

    // Hand over runs its call with no confirmation, and only for a row that it is on for.
    @Test func handOverPlansItsCallWithNoConfirmation() {
        #expect(plan(.handOver, owned) == .call(.handOver, confirm: nil, after: .none))
        for row in [working, external, parked] {
            #expect(plan(.handOver, row) == .none)
        }
    }

    @Test func stopOfAWorkingSessionAsksFirstAndStopOfAnIdleOneDoesNot() {
        #expect(
            plan(.stop, working)
                == .call(
                    .stop, confirm: Confirm.text(.stop, working, .plain), after: .closeWindow))
        guard case .call(_, let confirm?, _) = plan(.stop, working) else {
            Issue.record("Stop of a working session has no confirmation.")
            return
        }
        #expect(confirm.body.hasPrefix("fix-a is working right now."))
        #expect(plan(.stop, owned) == .call(.stop, confirm: nil, after: .closeWindow))
    }

    // The runner opens the chat window with the loader before the call, and restarts the chat
    // after it, because an ended terminal attaches again only after a restart.
    @Test func takeControlAsksWithTheTerminalNameAndRestartsTheChat() {
        let confirm = Confirm.text(.takeControl, external, .plain)
        #expect(
            plan(.takeControl, external)
                == .call(.takeControl, confirm: confirm, after: .restartChat))
        #expect(confirm?.body == "This closes the session in Warp and moves it into Bifrost.")
    }

    // The runner makes the final text after the check of the worktree.
    @Test func deleteAsksAndClosesTheChatWindowAfter() {
        let confirm = Confirm.text(.delete(.unchecked), owned, .plain)
        #expect(plan(.delete, owned) == .call(.remove, confirm: confirm, after: .closeChat))
        #expect(
            confirm?.body == "Delete fix-a? This removes the session from Claude Code and Bifrost.")
    }

    @Test(arguments: LabelSet.allCases)
    func takeControlAndDeleteAlwaysAsk(labels: LabelSet) {
        for (id, row) in [(ActionID.takeControl, external), (.delete, parked), (.delete, owned)] {
            guard case .call(_, let confirm, _) = plan(id, row, context(labels: labels)) else {
                Issue.record("\(id) plans no call.")
                continue
            }
            #expect(confirm != nil)
        }
    }

    @Test func resumeRestartsTheAttachOfAnOpenChatWindow() {
        #expect(plan(.resume, parked) == .call(.resume, confirm: nil, after: .restartChat))
    }

    @Test func showInfoOpensTheShowInfoPanelOfTheRow() {
        for var row in [owned, external, parked] {
            row.sessionId = infoId.text
            #expect(plan(.showInfo, row) == .showInfo(infoId))
        }
        #expect(plan(.showInfo, nil) == .none)
        // A row ID that is not a session ID has no Show Info panel.
        #expect(plan(.showInfo, owned) == .none)
    }

    @Test func newSessionAndResumeAllNeedNoRow() {
        #expect(plan(.newSession, owned) == .none)
        #expect(plan(.resumeAll, owned) == .none)
    }

    @Test func theOtherActionsCallWithNoConfirmation() {
        #expect(plan(.interrupt, working) == call(.interrupt))
        #expect(plan(.openInTerminal, external) == call(.openInTerminal))
        #expect(plan(.copyId, owned) == call(.copyId))
    }

    @Test func setPriorityCallsWithTheChosenPriority() {
        #expect(plan(.setPriority, owned, arg: .priority(.p2)) == call(.setPriority(.p2)))
        #expect(plan(.setPriority, owned, arg: .priority(nil)) == call(.setPriority(nil)))
        // No priority choice gives no call.
        #expect(plan(.setPriority, owned) == .none)
        #expect(plan(.setPriority, owned, arg: .colour(.red)) == .none)
    }

    @Test func openProjectCallsOnlyWithAnInstalledApp() {
        #expect(plan(.openProject, owned, arg: .app(.finder)) == call(.openProject(.finder)))
        #expect(plan(.openProject, owned, arg: .app(.zed)) == .none)
        #expect(plan(.openProject, owned) == .none)
    }

    @Test func theWatchActionsCallWithTheColour() {
        #expect(plan(.watchAdd, owned, arg: .colour(.lightBlue)) == call(.watchAdd(.lightBlue)))
        #expect(
            plan(.watchColour, watched(.red), arg: .colour(.darkBlue))
                == call(.watchColour(.darkBlue)))
        #expect(plan(.watchRemove, watched(.red)) == call(.watchRemove))
        #expect(plan(.watchAdd, watched(.red), arg: .colour(.lightBlue)) == .none)
        #expect(plan(.watchRemove, owned) == .none)
        // Change colour needs a colour.
        #expect(plan(.watchColour, watched(.red)) == .none)
    }

    // A button or a key gives no colour choice, so the session gets the default colour.
    @Test func addToWatchlistWithNoColourUsesLightBlue() {
        #expect(RunPlan.defaultWatchColour == .lightBlue)
        #expect(plan(.watchAdd, owned) == call(.watchAdd(.lightBlue)))
    }

    // Only no choice gets the default colour. A choice that is not a colour does not fit.
    @Test(arguments: [
        MenuArg.priority(.p1), .priority(nil), .app(.finder), .slash("/compact"), .otherSlash,
    ])
    func addToWatchlistWithAChoiceThatIsNotAColourGivesNone(arg: MenuArg) {
        #expect(plan(.watchAdd, owned, arg: arg) == .none)
    }
}


@Suite("the open from a notification")
struct NotifiedOpenTests {
    private let rows = [SessionRow.test(sessionId: "S1"), SessionRow.test(sessionId: "S2")]

    @Test func aSessionWithItsRowOpens() {
        #expect(RunPlan.notifiedOpenStep("S1", rows: rows, loaded: false) == .open)
        #expect(RunPlan.notifiedOpenStep("S1", rows: rows, loaded: true) == .open)
    }

    @Test func theOpenWaitsForTheRowUntilTheListHasLoaded() {
        #expect(RunPlan.notifiedOpenStep("S1", rows: [], loaded: false) == .wait)
        #expect(RunPlan.notifiedOpenStep("S9", rows: rows, loaded: false) == .wait)
    }

    @Test func theOpenStopsWhenTheListHasLoadedWithNoRow() {
        #expect(RunPlan.notifiedOpenStep("S9", rows: rows, loaded: true) == .drop)
        #expect(RunPlan.notifiedOpenStep("S1", rows: [], loaded: true) == .drop)
    }
}

@Suite("the chat window after a failed Delete")
struct FailedDeleteTests {
    // A deferred claude rm can fail after the registry forgot the row. Then the chat window
    // closes, as after a good Delete.
    @Test func theChatClosesWhenTheRowWentAndStaysWhenTheRowIsThere() {
        #expect(RunPlan.afterFailedDelete("o", rows: [.test(sessionId: "p")]) == .closeChat)
        #expect(RunPlan.afterFailedDelete("o", rows: []) == .closeChat)
        #expect(
            RunPlan.afterFailedDelete("o", rows: [.test(sessionId: "o"), .test(sessionId: "p")])
                == .none)
    }
}
