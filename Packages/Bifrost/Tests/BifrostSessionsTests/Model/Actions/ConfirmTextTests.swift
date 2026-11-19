// The confirmation dialogs of Stop, Delete and Take control (docs/behaviour/actions.md,
// "Confirmations"): the texts for each row and check, and the click rule of the confirm button.
import BifrostFoundation
import BifrostTestSupport
import Testing

@testable import BifrostSessions

private let worktree = "/r/.claude/worktrees/fix-a"

private func row(
    name: String = "fix-a", claudeName: String? = nil, kind: SessionKind = .owned,
    cwd: String = worktree, state: SessionState = .idle,
    change: (inout SessionRow) -> Void = { _ in }
) -> SessionRow {
    var row = SessionRow.test(
        sessionId: "a", name: name, claudeName: claudeName, kind: kind, cwd: cwd, state: state)
    change(&row)
    return row
}

// A row with a local name, so each text names both names.
private let aliased = row(name: "my-alias", claudeName: "claude-a1") { $0.terminalApp = "Warp" }
private let bothNames = "my-alias (Claude Code name: claude-a1)"

private func check(
    branch: String? = "worktree-fix-a", changedFiles: UInt = 0, unmergedCommits: UInt = 0,
    worktree: String? = worktree
) -> WorktreeCheck {
    WorktreeCheck(
        branch: branch, changedFiles: changedFiles, unmergedCommits: unmergedCommits,
        worktree: worktree)
}

private func delete(
    _ check: DeleteCheck, _ row: SessionRow = row(), labels: LabelSet = .plain
) -> ConfirmText? {
    Confirm.text(.delete(check), row, labels)
}

// The sentence for changed files: claude rm keeps such a worktree.
private let keeps =
    "Claude Code keeps a worktree with changes that are not committed, so commit or discard them "
    + "first."
private let plainDelete = "Delete fix-a? This removes the session from Claude Code and Bifrost."

@Suite("the confirmation texts")
struct ConfirmTextTests {
    @Test func stopAsksOnlyForAWorkingSession() {
        for state in [SessionState.idle, .needsYou, .error, .parked] {
            #expect(Confirm.text(.stop, row(state: state), .plain) == nil)
        }
        #expect(
            Confirm.text(.stop, row(state: .working), .plain)
                == ConfirmText(
                    title: "Stop session",
                    body: "fix-a is working right now. Stop it anyway? The current turn will end.",
                    confirm: "Stop session"))
    }

    @Test func eachTextNamesBothNamesWhenALocalNameExists() {
        var working = aliased
        working.state = .working
        #expect(
            Confirm.text(.stop, working, .plain)?.body
                == "\(bothNames) is working right now. Stop it anyway? The current turn will end.")
        let delete = delete(.unchecked, aliased)
        #expect(
            delete?.body
                == "Delete \(bothNames)? This removes the session from Claude Code and Bifrost.")
        #expect(delete?.title == "Delete \(bothNames)")
        #expect(
            Confirm.text(.takeControl, aliased, .plain)?.body
                == "This closes the session \(bothNames) in Warp and moves it into Bifrost.")
    }

    @Test(arguments: [SessionState.idle, .working, .needsYou, .error, .parked])
    func deleteAlwaysAsks(state: SessionState) {
        #expect(delete(.unchecked, row(state: state)) != nil)
    }

    @Test func deleteWithNoUnmergedWorkGivesThePlainText() {
        let plain = ConfirmText(title: "Delete fix-a", body: plainDelete, confirm: "Delete session")
        #expect(delete(.unchecked) == plain)
        #expect(delete(.checked(check())) == plain)
        // A folder that is not a worktree has no unmerged work to show, whatever the counts.
        #expect(delete(.checked(check(changedFiles: 4, worktree: nil))) == plain)
    }

    @Test func deleteWithUnmergedWorkGivesTheCountsAndAsksAgain() {
        #expect(
            delete(.checked(check(changedFiles: 3, unmergedCommits: 2)))
                == ConfirmText(
                    title: "Delete fix-a",
                    body: "This session has 2 commits that are not merged and 3 changed files on "
                        + "worktree-fix-a. \(keeps) Are you sure you want to delete this?",
                    confirm: "Delete session", confirmAgain: "Delete anyway", openFolder: worktree))
    }

    @Test func theDeleteTitleNamesTheSessionForEachCheck() {
        let checks: [DeleteCheck] = [
            .unchecked, .failed, .shared, .checked(check()), .checked(check(unmergedCommits: 1)),
        ]
        for check in checks {
            #expect(delete(check)?.title == "Delete fix-a")
            #expect(delete(check)?.confirm == "Delete session")
        }
        let named = row(name: "bifrost-a1b2")
        #expect(delete(.unchecked, named)?.title == "Delete bifrost-a1b2")
        #expect(delete(.unchecked, named, labels: .space)?.title == "Self-destruct bifrost-a1b2")
        #expect(delete(.failed, named, labels: .space)?.title == "Self-destruct bifrost-a1b2")
    }

    @Test func deleteUsesTheSingularAndLeavesOutAZeroPart() {
        #expect(
            delete(.checked(check(unmergedCommits: 1)))?.body
                == "This session has 1 commit that is not merged on worktree-fix-a. Are you sure "
                + "you want to delete this?")
        #expect(
            delete(.checked(check(changedFiles: 1, unmergedCommits: 1)))?.body
                == "This session has 1 commit that is not merged and 1 changed file on "
                + "worktree-fix-a. \(keeps) Are you sure you want to delete this?")
        #expect(
            delete(.checked(check(changedFiles: 1)))?.body
                == "This session has 1 changed file on worktree-fix-a. \(keeps) Are you sure you "
                + "want to delete this?")
        #expect(
            delete(.checked(check(branch: nil, unmergedCommits: 1)))?.body
                == "This session has 1 commit that is not merged in its worktree. Are you sure you "
                + "want to delete this?")
    }

    @Test func deleteNamesTheKeptWorktreeOnlyForChangedFiles() {
        #expect(
            delete(.checked(check(changedFiles: 75, unmergedCommits: 1)))?.body
                == "This session has 1 commit that is not merged and 75 changed files on "
                + "worktree-fix-a. \(keeps) Are you sure you want to delete this?")
        let checks: [DeleteCheck] = [
            .checked(check(unmergedCommits: 3)), .checked(check()), .failed, .unchecked, .shared,
        ]
        for check in checks {
            #expect(delete(check)?.body.contains(keeps) == false)
        }
    }

    @Test func aFailedCheckSaysSoAndAsksAgain() {
        #expect(
            delete(.failed)
                == ConfirmText(
                    title: "Delete fix-a",
                    body: "Bifrost could not check this session for unmerged work. Are you sure "
                        + "you want to delete this?",
                    confirm: "Delete session", confirmAgain: "Delete anyway", openFolder: worktree))
        // A plain folder has no worktree to open.
        #expect(delete(.failed, row(cwd: "/p")) != nil)
        #expect(delete(.failed, row(cwd: "/p"))?.openFolder == nil)
    }

    // A stopped session reports its start folder, so the worktree comes from the stored one.
    @Test func aFailedCheckOpensTheStoredWorktreeOfAStoppedSession() {
        let stopped = row(cwd: "/r", state: .parked) {
            $0.branch = "main"
            $0.worktree = worktree
        }
        #expect(delete(.failed, stopped)?.openFolder == worktree)
    }

    // claude rm keeps the transcript file, so the text names only Claude Code and Bifrost.
    @Test func theDeleteTextDoesNotSayThatTheConversationGoes() {
        for check in [DeleteCheck.unchecked, .checked(check()), .shared] {
            #expect(delete(check)?.body.contains("conversation") == false)
        }
    }

    @Test func takeControlNamesTheTerminalApp() {
        let external = row(kind: .external) { $0.terminalApp = "Warp" }
        #expect(
            Confirm.text(.takeControl, external, .plain)
                == ConfirmText(
                    title: "Take control",
                    body: "This closes the session in Warp and moves it into Bifrost.",
                    confirm: "Take control"))
        for app in [nil, ""] {
            let unknown = row(kind: .external) { $0.terminalApp = app }
            #expect(
                Confirm.text(.takeControl, unknown, .plain)?.body
                    == "This closes the session in its terminal and moves it into Bifrost.")
        }
        #expect(Confirm.text(.takeControl, external, .space)?.title == "Commandeer")
        #expect(Confirm.text(.takeControl, external, .space)?.confirm == "Commandeer")
    }

    @Test func theBodiesUseTheVerbsOfTheLabelSet() {
        #expect(
            Confirm.text(.stop, row(state: .working), .space)?.body
                == "fix-a is working right now. Power it down anyway? The current turn will end.")
        let plain = "Self-destruct fix-a? This removes the session from Claude Code and Bifrost."
        #expect(delete(.unchecked, labels: .space)?.body == plain)
        #expect(delete(.checked(check()), labels: .space)?.body == plain)
        let unmerged = delete(.checked(check(unmergedCommits: 1)), labels: .space)
        #expect(
            unmerged?.body
                == "This session has 1 commit that is not merged on worktree-fix-a. Are you sure "
                + "you want to self-destruct this?")
        #expect(unmerged?.confirmAgain == "Self-destruct anyway")
        let failed = delete(.failed, labels: .space)
        #expect(
            failed?.body
                == "Bifrost could not check this session for unmerged work. Are you sure you want "
                + "to self-destruct this?")
        #expect(failed?.confirmAgain == "Self-destruct anyway")
    }

    // Another session uses the folder, so the Delete keeps it, runs no check and asks once.
    @Test func deleteInASharedFolderSaysThatBifrostKeepsIt() {
        let first = "Another session still uses this folder, so Bifrost keeps it."
        let later =
            "It goes from the list now, and Bifrost removes it from Claude Code when you delete "
            + "the last session in this folder."
        #expect(
            delete(.shared, aliased)
                == ConfirmText(
                    title: "Delete \(bothNames)", body: "\(first) Delete \(bothNames)? \(later)",
                    confirm: "Delete session"))
        #expect(
            delete(.shared, aliased, labels: .space)
                == ConfirmText(
                    title: "Self-destruct \(bothNames)",
                    body: "\(first) Self-destruct \(bothNames)? \(later)",
                    confirm: "Self-destruct"))
    }

    @Test func theConfirmLabelsUseTheLabelSet() {
        let working = row(name: "a", state: .working)
        #expect(Confirm.text(.stop, working, .space)?.confirm == "Power down")
        #expect(Confirm.text(.stop, working, .space)?.title == "Power down")
        #expect(delete(.unchecked, row(name: "a"), labels: .space)?.confirm == "Self-destruct")
        #expect(delete(.unchecked, row(name: "a"), labels: .space)?.title == "Self-destruct a")
    }

    // A bidi control could reverse the rest of the text, so the names, the branch and the
    // terminal app of a text lose the hidden characters of a name.
    @Test func aNameOrABranchShowsWithoutHiddenCharacters() {
        let tricky = row(name: "fix\u{202E}-a", claudeName: "claude\u{200B}-a1") {
            $0.kind = .external
            $0.terminalApp = "Wa\u{2066}rp"
        }
        let name = "fix-a (Claude Code name: claude-a1)"
        #expect(delete(.unchecked, tricky)?.title == "Delete \(name)")
        #expect(
            Confirm.text(.takeControl, tricky, .plain)?.body
                == "This closes the session \(name) in Warp and moves it into Bifrost.")
        #expect(
            delete(.checked(check(branch: "main\u{061C}", unmergedCommits: 1)))?.body
                == "This session has 1 commit that is not merged on main. Are you sure you want "
                + "to delete this?")
    }
}

@Suite("the confirm button")
struct ConfirmStepTests {
    private let once = ConfirmText(title: "Stop session", body: "b", confirm: "Stop session")
    private let twice = ConfirmText(
        title: "Delete fix-a", body: "b", confirm: "Delete session", confirmAgain: "Delete anyway")

    @Test func theSecondClickWaits500ms() {
        #expect(Confirm.againWait == .milliseconds(500))
    }

    @Test func aClickOnAPlainDialogConfirms() {
        let step = Confirm.step(.first, once, sinceAgain: .zero)
        #expect(step.label == "Stop session")
        #expect(step.resolve)
    }

    @Test func theFirstClickWithConfirmAgainChangesTheLabelAndDoesNotConfirm() {
        let step = Confirm.step(.first, twice, sinceAgain: .seconds(10))
        #expect(step.label == "Delete anyway")
        #expect(!step.resolve)
    }

    @Test func aSecondClickBefore500msDoesNotConfirm() {
        for wait in [Duration.zero, .milliseconds(499)] {
            let step = Confirm.step(.again, twice, sinceAgain: wait)
            #expect(step.label == "Delete anyway")
            #expect(!step.resolve)
        }
    }

    @Test func aSecondClickAt500msOrLaterConfirms() {
        for wait in [Duration.milliseconds(500), .seconds(2)] {
            let step = Confirm.step(.again, twice, sinceAgain: wait)
            #expect(step.label == "Delete anyway")
            #expect(step.resolve)
        }
    }

    @Test func theLabelOfEachStep() {
        #expect(Confirm.label(.first, twice) == "Delete session")
        #expect(Confirm.label(.again, twice) == "Delete anyway")
        #expect(Confirm.label(.first, once) == "Stop session")
        #expect(Confirm.label(.again, once) == "Stop session")
    }
}
