// The action runner (docs/behaviour/actions.md, "The action runner"): it runs the plan of an
// action for the row of now, asks with the confirm dialog, runs the command and shows the result
// in the notice line or the error line. The session commands run on fake deps (ActionsHarness):
// no test runs a program, opens an app or signals a process.
import AppKit
import BifrostFoundation
import BifrostLayout
import BifrostSessions
import BifrostTestSupport
import Foundation
import Testing

@testable import BifrostWindows

@Suite("the action runner", .serialized, .timeLimit(.minutes(1)), .tags(.window))
@MainActor
struct ActionRunnerTests {
    // A Stop of a parked row and a Delete of an external row that runs are off: the run plans
    // none, so nothing shows and no command runs.
    @Test func aDisabledActionDoesNothing() async throws {
        let h = try await ActionsHarness(active: [Entry.interactive(s3)], all: [Entry.stopped(s1)])
        h.runner.run(.stop, s1)
        h.runner.run(.delete, s3)
        h.runner.run(.takeControl, s1)
        #expect(h.runner.lastTask == nil)
        #expect(!h.dialogs.isOpen)
        #expect(h.runner.notice == nil)
        #expect(h.runner.error == nil)
        #expect(h.calls.all.isEmpty)
    }

    // A Delete runs the check for unmerged work first, with its notice. The confirmation then
    // has the text of the check: the work, a second click and Open worktree.
    @Test func deleteChecksFirstThenConfirmsWithTheCheck() async throws {
        let h = try await ActionsHarness(active: [Entry.running(s1, cwd: wt)])
        let gate = TestGate()
        defer { gate.openAll() }
        h.calls.answerGit(worktreeGit)
        h.calls.holdGit(gate)
        h.runner.run(.delete, s1)
        await gate.waitUntilHolding()
        #expect(h.runner.notice == ActionRunner.checkingNotice)
        #expect(!h.dialogs.isOpen)
        // The session runs an action from the start of the check.
        #expect(h.runner.context(s1).running)
        gate.openAll()
        let model = try await h.confirmation()
        #expect(h.runner.notice == nil)
        let check = WorktreeCheck(
            branch: "worktree-w1", changedFiles: 1, unmergedCommits: 2, worktree: wt,
            head: headCommit)
        let row = try #require(h.row(s1))
        #expect(model.text == Confirm.text(.delete(.checked(check)), row, .plain))
        #expect(model.text.body.hasPrefix("This session has 2 commits that are not merged"))
        #expect(model.text.confirmAgain == "Delete anyway")
        #expect(model.showsOpenFolder)
        // Open worktree opens the worktree in Finder, and the dialog stays.
        model.openFolder()
        await waitUntil(within: .seconds(10)) { !h.opener.calls.isEmpty }
        #expect(h.dialogs.isOpen)
        model.cancel()
        await h.settle()
        #expect(!h.runner.context(s1).running)
        #expect(h.calls.claudeRuns.isEmpty)
    }

    // A confirmation cannot open while another dialog shows: the action does not run, and the
    // notice line says why.
    @Test func aSecondDialogGivesTheBusyNotice() async throws {
        let h = try await ActionsHarness(active: [Entry.running(s1, status: .busy)])
        h.runner.run(.rename, s1)
        #expect(h.dialogs.isOpen)
        h.runner.run(.stop, s1)
        await h.settle()
        #expect(h.runner.notice == ActionRunner.busyNotice)
        #expect(h.calls.claudeRuns.isEmpty)
        guard case .rename = h.dialogs.dialog else {
            Issue.record("The Rename dialog went.")
            return
        }
        // New session gives the same notice.
        h.runner.runGlobal(.newSession)
        guard case .rename = h.dialogs.dialog else {
            Issue.record("The New session dialog replaced the Rename dialog.")
            return
        }
    }

    @Test func theNoticeGoesAfter5s() async throws {
        let h = try await ActionsHarness(active: [Entry.running(s1)])
        h.runner.run(.rename, s1)
        h.runner.run(.rename, s1)
        #expect(h.runner.notice == ActionRunner.busyNotice)
        let timer = try #require(h.runner.noticeTimer)
        h.clock.advance(by: .milliseconds(4999))
        await Task.yield()
        #expect(h.runner.notice == ActionRunner.busyNotice)
        h.clock.advance(by: .milliseconds(1))
        await h.finish(timer)
        #expect(h.runner.notice == nil)
    }

    // While a Delete runs, its notice stays. A new notice waits, then shows after the end of the
    // Delete.
    @Test func aNoticeDuringADeleteWaitsForItsEnd() async throws {
        let h = try await ActionsHarness(active: [Entry.running(s2)], all: [Entry.stopped(s1)])
        let gate = TestGate()
        defer { gate.openAll() }
        h.calls.hold(gate)
        h.runner.run(.delete, s1)
        let delete = try #require(h.runner.lastTask)
        try await h.confirmation().pressConfirm()
        await gate.waitUntilHolding()
        #expect(h.runner.notice == ActionRunner.deletingNotice)
        h.runner.run(.rename, s2)
        h.runner.run(.rename, s2)
        #expect(h.runner.notice == ActionRunner.deletingNotice)
        gate.openAll()
        await h.finish(delete)
        #expect(h.row(s1) == nil)
        #expect(h.runner.notice == ActionRunner.busyNotice)
    }

    // Take control selects the row and opens its chat with the loader before the command. A
    // failure ends the loader, closes the chat and shows the reason.
    @Test func takeControlOpensTheChatWithTheLoaderAndClosesItAfterAFailure() async throws {
        let h = try await ActionsHarness(active: [Entry.interactive(s3)])
        let gate = TestGate()
        defer { gate.openAll() }
        h.calls.holdFolderReads(gate)
        h.runner.run(.takeControl, s3)
        try await h.confirmation().pressConfirm()
        await gate.waitUntilHolding()
        #expect(h.loaderSteps == ["start \(s3)"])
        #expect(h.chatOpen(s3))
        #expect(h.selection.selectedId == s3)
        gate.openAll()
        await h.settle()
        // The transcript folder of the test has no messages, so Take control stops there.
        #expect(h.loaderSteps == ["start \(s3)", "stop \(s3)"])
        #expect(!h.chatOpen(s3))
        #expect(h.runner.error == ActionRefusal.noMessages.message)
        #expect(h.calls.signals.isEmpty)
    }

    // A /rename sent from the send box or the menu clears the local name: the Claude Code name
    // changes. It does not go into the recent slash commands.
    @Test func aRenameSendClearsTheLocalName() async throws {
        let h = try await ActionsHarness(
            store: RegistryStore(aliases: [s1: "mine"]), active: [Entry.running(s1)])
        #expect(h.row(s1)?.name == "mine")
        try await h.quietChat(s1, shortId: short1)
        let send = Task {
            do throws(ActionRefusal) {
                try await h.runner.send(s1, "/rename fresh")
            } catch {
                Issue.record("The send failed: \(error.message)")
            }
        }
        await h.drive(send)
        #expect(h.typed.contains("/rename fresh"))
        #expect(h.row(s1)?.name == "bifrost-test-s")
        #expect(h.runner.history.recentSlash.isEmpty)
    }

    // A slash command that the runner sends goes first in the recent slash commands of the
    // history in ui-state.json.
    @Test func aSlashSendGoesIntoTheHistory() async throws {
        let h = try await ActionsHarness(active: [Entry.running(s1)])
        try await h.quietChat(s1, shortId: short1)
        let send = Task {
            do throws(ActionRefusal) {
                try await h.runner.send(s1, "  /clear ")
            } catch {
                Issue.record("The send failed: \(error.message)")
            }
        }
        await h.drive(send)
        #expect(h.runner.history.recentSlash == ["/clear"])
        #expect(h.store.state.dialogHistory.recentSlash == ["/clear"])
        // A message is not a slash command.
        let message = Task {
            do throws(ActionRefusal) {
                try await h.runner.send(s1, "Reply with OK")
            } catch {
                Issue.record("The send failed: \(error.message)")
            }
        }
        await h.drive(message)
        #expect(h.runner.history.recentSlash == ["/clear"])
    }

    // A deferred claude rm can fail after the registry forgot the row of the Delete. The chat
    // then closes, as after a good Delete, and the error stays.
    @Test func aFailedDeleteClosesTheChatWhenTheRowWent() async throws {
        let store = RegistryStore(
            deferred: [DeferredDelete(sessionId: s2, shortId: short2, worktree: wt)],
            worktrees: [s1: wt])
        let h = try await ActionsHarness(store: store, all: [Entry.stopped(s1, cwd: repo)])
        h.calls.answerClaude { args in
            args == ["rm", short2.text]
                ? ExecResult(.exited(1), stderr: "boom") : ExecResult(.exited(0))
        }
        h.calls.answerGit(worktreeGit)
        h.layout.openChat(s1)
        h.selection.selectedId = s1
        h.runner.run(.delete, s1)
        // The worktree has unmerged work, so the dialog asks twice.
        let model = try await h.confirmation()
        #expect(model.text.confirmAgain != nil)
        model.pressConfirm()
        h.clock.advance(by: Confirm.againWait)
        model.pressConfirm()
        await h.settle()
        #expect(h.row(s1) == nil)
        #expect(h.runner.error != nil)
        #expect(!h.chatOpen(s1))
        #expect(h.selection.selectedId == nil)
    }

    // A failed Delete of a row that stays keeps the chat open.
    @Test func aFailedDeleteKeepsTheChatWhenTheRowStays() async throws {
        let h = try await ActionsHarness(all: [Entry.stopped(s1)])
        h.calls.answerClaude { _ in ExecResult(.exited(1), stderr: "boom") }
        h.layout.openChat(s1)
        h.runner.run(.delete, s1)
        try await h.confirmation().pressConfirm()
        await h.settle()
        #expect(h.row(s1) != nil)
        #expect(h.runner.error == ActionRefusal.claudeReported("boom").message)
        #expect(h.chatOpen(s1))
    }

    // A refusal of Interrupt shows in the error line: a session with no process ID yet gets no
    // hidden attach.
    @Test func theInterruptRefusalShowsInTheErrorLine() async throws {
        let h = try await ActionsHarness(active: [Entry.running(s1, pid: nil)])
        h.runner.run(.interrupt, s1)
        await h.drive(try #require(h.runner.lastTask))
        #expect(h.runner.error == InputRefusal.noPid.message)
        #expect(h.typed.isEmpty)
        // An error stays until closeError.
        h.clock.advance(by: .seconds(60))
        await Task.yield()
        #expect(h.runner.error == InputRefusal.noPid.message)
        h.runner.closeError()
        #expect(h.runner.error == nil)
    }

    // The runner links the Overviews: a right-click on a row shows the row menu of the model on
    // the Bifrost menu, and a double-click runs Open.
    @Test func theRowMenuOfTheOverviewComesFromTheModel() async throws {
        let h = try await ActionsHarness(active: [Entry.running(s1)])
        let overviews = OverviewModel(
            store: h.store, sessions: h.list, selection: h.selection, layout: h.layout,
            clock: ManualClock(), now: { Date(timeIntervalSince1970: 0) })
        let driver = MenuDriver()
        let window = MenuDriver.window()
        defer {
            driver.menu.close()
            window.close()
        }
        let view = try #require(window.contentView)
        h.runner.attach(overviews, menu: driver.menu)
        let row = try #require(h.row(s1))
        overviews.showRowMenu(row, NSPoint(x: 40, y: 40), view)
        #expect(driver.menu.isOpen)
        #expect(try driver.root.list.state.rows == RowMenu.rows(row, runner: h.runner))
        let entries = RowMenuModel.entries(row, h.runner.context(s1))
        #expect(try driver.root.list.state.rows.count == entries.count)
        overviews.open(s1)
        #expect(h.chatOpen(s1))
    }

    // Run slash command with a command of the submenu plans a send, and the runner sends it with
    // its own send: the command reaches the session and the history.
    @Test func aSendPlanUsesTheSendOfTheRunner() async throws {
        let h = try await ActionsHarness(active: [Entry.running(s1)])
        try await h.quietChat(s1, shortId: short1)
        h.runner.run(.runSlash, s1, arg: .slash("/context"))
        let send = try #require(h.runner.lastTask)
        await h.drive(send)
        #expect(h.typed.contains("/context"))
        #expect(h.runner.history.recentSlash == ["/context"])
        #expect(h.runner.error == nil)
    }

    // Send message selects the row, opens the Selected Item panel and then focuses its send box
    // at once, each time. Run slash command asks for the "/" too.
    @Test func sendMessageFocusesTheSendBoxAfterTheOpen() async throws {
        let h = try await ActionsHarness(active: [Entry.running(s1)])
        h.runner.focusSendBox = { session, slash in
            #expect(h.selection.selectedId == session)
            #expect(h.layout.layout.frame(of: .selectedItem) != nil)
            h.record(SendBoxFocus(session: session, slash: slash))
        }
        h.runner.run(.sendMessage, s1)
        h.runner.run(.runSlash, s1)
        h.runner.run(.sendMessage, s1)
        #expect(
            h.sendBoxFocuses == [
                SendBoxFocus(session: s1, slash: false), SendBoxFocus(session: s1, slash: true),
                SendBoxFocus(session: s1, slash: false),
            ])
    }

    // The quit stops the runner: a run that did not end gets a cancel.
    @Test func stopCancelsTheRunsThatDidNotEnd() async throws {
        let h = try await ActionsHarness(active: [Entry.running(s1)])
        let gate = TestGate()
        defer { gate.openAll() }
        h.spawner.holdNext(gate)
        h.runner.run(.runSlash, s1, arg: .slash("/context"))
        let send = try #require(h.runner.lastTask)
        await gate.waitUntilHolding()
        #expect(!send.isCancelled)
        h.runner.stop()
        #expect(send.isCancelled)
        gate.openAll()
        await h.drive(send)
    }

    // Set priority runs with the choice of the menu, on the registry.
    @Test func setPriorityRunsWithTheChoice() async throws {
        let h = try await ActionsHarness(active: [Entry.running(s1)])
        h.runner.run(.setPriority, s1, arg: .priority(.p2))
        await h.settle()
        #expect(h.row(s1)?.priority == .p2)
        h.runner.run(.setPriority, s1, arg: .priority(nil))
        await h.settle()
        #expect(h.row(s1)?.priority == nil)
    }

    // The running mark is on at the click, before the call starts, so a second click on Stop
    // plans nothing.
    @Test func aCallMarksTheSessionAtOnce() async throws {
        let h = try await ActionsHarness(active: [Entry.running(s1, status: .busy)])
        h.runner.run(.stop, s1)
        #expect(h.runner.context(s1).running)
        let first = try #require(h.runner.lastTask)
        h.runner.run(.stop, s1)
        #expect(h.runner.lastTask == first)
        try await h.confirmation().cancel()
        await h.finish(first)
        #expect(!h.runner.context(s1).running)
        #expect(h.runner.notice == nil)
    }

    // A Delete in a folder that another session shares asks with the shared text and runs no
    // check. When the other session goes before the confirmation, the Delete would run claude rm,
    // so the runner runs the check and asks again with the work it finds.
    @Test func aSharedFolderThatIsNoLongerSharedAsksAgainWithTheCheck() async throws {
        let h = try await ActionsHarness(
            active: [Entry.running(s1, cwd: wt), Entry.interactive(s2, cwd: wt)])
        h.calls.answerGit(worktreeGit)
        #expect(h.runner.context(s1).folderShared)
        h.runner.run(.delete, s1)
        let shared = try await h.confirmation()
        #expect(shared.text.body.hasPrefix("Another session still uses this folder"))
        #expect(h.calls.all.isEmpty)
        await h.deps.show([Entry.running(s1, cwd: wt)]) { $0.count == 1 }
        shared.pressConfirm()
        await waitUntil(within: .seconds(10)) {
            if case .confirm(let next) = h.dialogs.dialog { next !== shared } else { false }
        }
        let checked = try await h.confirmation()
        let row = try #require(h.row(s1))
        let check = WorktreeCheck(
            branch: "worktree-w1", changedFiles: 1, unmergedCommits: 2, worktree: wt,
            head: headCommit)
        #expect(checked.text == Confirm.text(.delete(.checked(check)), row, .plain))
        checked.cancel()
        await h.settle()
        #expect(h.calls.claudeRuns.isEmpty)
        #expect(h.row(s1) != nil)
    }

    // The confirmed Delete passes the counts and the HEAD commit that the dialog showed. When
    // the HEAD moves after the dialog, claude rm keeps the worktree and nothing is discarded.
    @Test func aConfirmedDeletePassesTheHeadOfTheDialog() async throws {
        let h = try await ActionsHarness(
            store: RegistryStore(worktrees: [s1: wt]), all: [Entry.stopped(s1, cwd: repo)])
        h.calls.answerGit(gitOfWorktree(changed: false))
        h.calls.answerClaude { _ in keptOutput(short1) }
        h.runner.run(.delete, s1)
        let model = try await h.confirmation()
        #expect(model.text.confirmAgain != nil)
        model.pressConfirm()
        h.clock.advance(by: Confirm.againWait)
        // A new commit after the dialog.
        h.calls.answerGit(gitOfWorktree(head: String(repeating: "c", count: 40), changed: false))
        model.pressConfirm()
        await h.settle()
        #expect(h.runner.error == ActionRefusal.worktreeChanged.message)
        #expect(h.calls.claudeRuns == [["rm", short1.text]])
        #expect(h.row(s1) != nil)
    }

    // Take control that works restarts the chat, and the loader then waits for the first output.
    @Test func takeControlThatWorksFinishesTheLoader() async throws {
        let temp = try transcripts(s3)
        defer { temp.remove() }
        let h = try await ActionsHarness(active: [Entry.interactive(s3)], projects: temp.url)
        h.deps.inspector.identities = [
            5151: ProcessIdentity(
                command: "/Users/x/.local/bin/claude",
                started: ProcessStart(seconds: 100, microseconds: 5))
        ]
        h.calls.answerAlive { $0 == 6161 }
        h.runner.run(.takeControl, s3)
        try await h.confirmation().pressConfirm()
        // The terminal process ended, and the resume waits for its row.
        await h.clock.waitForSleepers(5)
        await h.deps.show([Entry.running(s3, pid: 6161)]) { rows in
            rows.contains { $0.sessionId == s3 && $0.kind == .owned }
        }
        await h.clock.waitForSleepers(5)
        h.clock.advance(by: SessionActions.resumeSettle)
        await h.settle()
        #expect(h.runner.error == nil)
        #expect(h.loaderSteps == ["start \(s3)", "finish \(s3)"])
        #expect(h.chatOpen(s3))
        #expect(h.selection.selectedId == s3)
        #expect(h.calls.signals == [.signal(5151, SIGTERM)])
    }

    // A Take control that the quit of the app cancels ends the loader and closes the chat.
    @Test func aCancelledTakeControlEndsTheLoaderAndClosesTheChat() async throws {
        let h = try await ActionsHarness(active: [Entry.interactive(s3)])
        let gate = TestGate()
        defer { gate.openAll() }
        h.calls.holdFolderReads(gate)
        h.runner.run(.takeControl, s3)
        try await h.confirmation().pressConfirm()
        await gate.waitUntilHolding()
        #expect(h.chatOpen(s3))
        h.actions.stop()
        gate.openAll()
        await h.settle()
        #expect(h.loaderSteps == ["start \(s3)", "stop \(s3)"])
        #expect(!h.chatOpen(s3))
        #expect(h.runner.error == ActionRefusal.cancelled.message)
        #expect(h.calls.signals.isEmpty)
    }

    // MARK: - Rows that only an --all read lists

    // Resume of a new row of the --all list checks the active list first. While the check runs,
    // the notice line says "Checking sessions...". Then Resume decides on the real state: the
    // active list has the entry with no pid, so the session starts, and Resume refuses it.
    @Test func theNoticeLineShowsTheCheckOfAnUnconfirmedRow() async throws {
        let h = try await ActionsHarness(all: [Entry.stopped(s1)], confirmAll: false)
        #expect(h.row(s1)?.listing == .unconfirmed)
        h.deps.lists.holdActive()
        h.runner.run(.resume, s1)
        await waitUntil { h.deps.lists.heldReads == 1 }
        #expect(h.runner.notice == "Checking sessions...")
        h.deps.lists.active = [Entry.running(s1, pid: nil, status: .unknown)]
        h.deps.lists.releaseActive()
        await h.settle()
        #expect(h.runner.notice == nil)
        #expect(h.runner.error == ActionRefusal.notParked.message)
        #expect(h.calls.claudeRuns.isEmpty)
    }

    // A Resume all whose check gives no list skips nothing in silence: the error line gives the
    // reason for the session, and the notice line shows no "Resumed 0 sessions.".
    @Test func aResumeAllWhoseCheckFailsGivesTheReasonAndNoCount() async throws {
        let h = try await ActionsHarness(
            store: RegistryStore(lastActive: [s1]), all: [Entry.stopped(s1)], confirmAll: false)
        h.deps.lists.activeFailure = .commandFailed(detail: "boom")
        h.runner.runGlobal(.resumeAll)
        await h.settle()
        #expect(h.runner.notice == nil)
        #expect(
            h.runner.error
                == "bifrost-test-s: Bifrost couldn't check that this session has stopped, "
                + "because Claude Code ran into a problem. Try again in a moment.")
        #expect(h.calls.claudeRuns.isEmpty)
    }

    // MARK: - Hand over

    // While a hand-over runs, the session counts as running, so Stop and a second Hand over are
    // off, and the notice line says that the note is on its way. A stop of the session ends the
    // hand-over with its reason, and the mark goes.
    @Test func aHandOverMarksTheSessionAsRunning() async throws {
        let projects = try transcripts(s1)
        defer { projects.remove() }
        let h = try await ActionsHarness(
            active: [Entry.running(s1)], projects: projects.url, handOver: true)
        try await h.quietChat(s1, shortId: short1)
        h.runner.run(.handOver, s1)
        #expect(h.runner.isRunning(s1))
        let ctx = h.runner.context(s1)
        #expect(ActionModel.state(.stop, h.row(s1), ctx) == .off(ActionReasons.running))
        #expect(ActionModel.state(.handOver, h.row(s1), ctx) == .off(ActionReasons.running))
        _ = try #require(await h.typedRequest())
        #expect(h.runner.notice == "Writing the hand-over note...")
        await h.deps.show([]) { $0.isEmpty }
        await h.settle()
        #expect(!h.runner.isRunning(s1))
        #expect(h.runner.error == HandOverFailure.stopped.message)
        #expect(h.runner.notice == nil)
        #expect(h.calls.claudeRuns.isEmpty)
    }

    // After a good hand-over, the chat of the old session shows the new session, the new row is
    // selected, the old session parks, and the notice names the new session.
    @Test func aGoodHandOverSelectsTheNewRow() async throws {
        let projects = try transcripts(s1)
        defer { projects.remove() }
        let h = try await ActionsHarness(
            active: [Entry.running(s1)], projects: projects.url, handOver: true)
        h.calls.answerClaude { args in
            args.first == "--bg" ? startedOutput : ExecResult(.exited(0))
        }
        try await h.quietChat(s1, shortId: short1)
        h.layout.openChat(s1)
        h.runner.run(.handOver, s1)
        let id = try #require(await h.typedRequest())
        let handle = try FileHandle(forWritingTo: projects.url.appending(path: "-p/\(s1).jsonl"))
        try handle.seekToEnd()
        let reply = HandOverLines.request(id) + HandOverLines.reply("n") + HandOverLines.turnEnd
        try handle.write(contentsOf: Data(reply.utf8))
        try handle.close()
        // The start waits for the row of the new session, and the Stop of the old session waits
        // for its park.
        await waitUntil(within: .seconds(10)) { h.calls.claudeRuns.contains { $0.first == "--bg" } }
        let started = AgentEntry(
            sessionId: newId, cwd: "/p", isBackground: true, startedAt: 1,
            name: "bifrost-test-s (2)", status: .idle, pid: 5151, id: "4cb23c30")
        await h.deps.show([Entry.running(s1), started])
        await waitUntil(within: .seconds(10)) {
            h.calls.claudeRuns.contains { $0 == ["stop", short1.text] }
        }
        await h.deps.show([started])
        await h.settle()
        #expect(h.selection.selectedId == newId)
        #expect(h.chatOpen(newId))
        #expect(!h.chatOpen(s1))
        #expect(h.runner.notice == "Handed over to bifrost-test-s (2).")
        #expect(h.runner.error == nil)
        #expect(!h.runner.isRunning(s1))
    }

    // The old session is busy again when the new session has started: the park check refuses,
    // so the old session keeps running and the error line says why. The new row is selected.
    @Test func aHandOverLeavesABusyOldSessionRunning() async throws {
        let projects = try transcripts(s1)
        defer { projects.remove() }
        let h = try await ActionsHarness(
            active: [Entry.running(s1)], projects: projects.url, handOver: true)
        h.calls.answerClaude { _ in startedOutput }
        try await h.quietChat(s1, shortId: short1)
        h.runner.run(.handOver, s1)
        let id = try #require(await h.typedRequest())
        let handle = try FileHandle(forWritingTo: projects.url.appending(path: "-p/\(s1).jsonl"))
        try handle.seekToEnd()
        let reply = HandOverLines.request(id) + HandOverLines.reply("n") + HandOverLines.turnEnd
        try handle.write(contentsOf: Data(reply.utf8))
        try handle.close()
        await waitUntil(within: .seconds(10)) { h.calls.claudeRuns.contains { $0.first == "--bg" } }
        let started = AgentEntry(
            sessionId: newId, cwd: "/p", isBackground: true, startedAt: 1,
            name: "bifrost-test-s (2)", status: .idle, pid: 5151, id: "4cb23c30")
        await h.deps.show([Entry.running(s1, status: .busy), started])
        await h.settle()
        #expect(h.selection.selectedId == newId)
        #expect(h.runner.error == ParkRefusal.busy.message)
        #expect(!h.calls.claudeRuns.contains { $0.first == "stop" })
        #expect(h.row(s1)?.state == .working)
        #expect(!h.runner.isRunning(s1))
    }
}
