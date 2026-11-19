// The New session dialog (docs/behaviour/actions.md, "New session"): the form refuses a bad value
// with its reason, the worktree check box follows the folder check, and a failed check of the
// start keeps the dialog open with its reason. When claude --bg starts, the dialog closes at
// once, and the Overview shows the start as a Starting row until the session list has its row.
// A good start remembers the values, selects the new row and opens its chat, and a failed start
// removes the Starting row and shows its reason in the error line. The start runs the fake claude
// of FakeActionDeps on the manual clock, so no program runs.
import AppKit
import BifrostFoundation
import BifrostLayout
import BifrostSessions
import BifrostTestSupport
import Foundation
import SwiftUI
import Testing

@testable import BifrostWindows

// An Overview of the harness in a window that is never ordered front, with the runner linked to
// its model (ActionRunner.attach), so the table shows the Starting rows of the runner.
@MainActor
private final class StartingOverview {
    let window = MenuDriver.window()
    let driver = MenuDriver()
    let panels: OverviewPanels
    let body: OverviewPanel

    init(_ h: ActionsHarness) throws {
        let id = panel("overview:1")
        let model = OverviewModel(
            store: h.store, sessions: h.list, selection: h.selection, layout: h.layout,
            clock: h.clock, now: { Date(timeIntervalSince1970: 0) })
        panels = OverviewPanels(model: model, look: h.look, filter: { nil })
        h.layout.apply(.open(id))
        body = try #require(panels.body(for: id) as? OverviewPanel)
        let content = try #require(window.contentView)
        body.frame = content.bounds
        content.addSubview(body)
        h.runner.attach(model, menu: driver.menu)
    }

    var table: OverviewTable { body.rows.table }

    // Wait until the table has this number of rows and this number of Starting rows.
    func waitFor(rows count: Int, starting: Int) async {
        let (body, table) = (body, table)
        await waitUntil {
            table.numberOfRows == count && body.rows.input?.starting.count == starting
        }
        body.layoutSubtreeIfNeeded()
    }

    // The text of the cell of the row in the column, or nil for a cell with no text view.
    func text(row: Int, _ column: OverviewColumn) -> String? {
        let index = table.column(withIdentifier: NSUserInterfaceItemIdentifier(column.rawValue))
        let cell = table.view(atColumn: index, row: row, makeIfNecessary: true)
        return (cell as? OverviewTextCell)?.text
    }

    func close() {
        driver.menu.close()
        window.close()
    }
}

@Suite("the New session dialog", .serialized, .testTimeLimit, .tags(.window))
@MainActor
struct NewSessionDialogTests {
    @Test func theFormRefusesABadNameWithItsReason() async throws {
        let h = try await ActionsHarness()
        h.runner.runGlobal(.newSession)
        let model = try h.newSessionDialog()
        #expect(model.title == "New session")
        // The first value that fails gives the reason: the folder, then the name.
        model.apply(.name("-x"))
        await model.submit()
        #expect(model.reason == ActionRefusal.noFolder.message)
        model.apply(.cwd("/p"))
        #expect(model.reason == nil)
        await model.submit()
        #expect(model.reason == ActionRefusal.nameFlag.message)
        #expect(h.dialogs.isOpen)
        #expect(h.calls.claudeRuns.isEmpty)
    }

    @Test func theWorktreeBoxIsOffForAFolderWithNoGit() async throws {
        let h = try await ActionsHarness()
        h.calls.setNoGit("/p")
        h.runner.runGlobal(.newSession)
        let model = try h.newSessionDialog()
        #expect(model.worktree == .off(ActionRefusal.noFolder.message))
        model.apply(.cwd("/p"))
        #expect(model.worktree == .off(NewSessionRules.reasonChecking))
        // The check runs 300 ms after the last change of the folder.
        let check = try #require(model.checkTask)
        h.clock.advance(by: NewSessionDialogModel.checkDelay)
        await h.finish(check)
        #expect(model.worktree == .off(ActionRefusal.noGit.message))
        // A folder in a repository turns the box on.
        model.apply(.cwd("/q"))
        let next = try #require(model.checkTask)
        h.clock.advance(by: NewSessionDialogModel.checkDelay)
        await h.finish(next)
        #expect(model.worktree == .on)
    }

    // The dialog closes when claude --bg starts, and the Overview shows the start after its rows
    // as a Starting row. claude --bg gives the short ID, the start reads the list at once, and the
    // real row takes the place of the Starting row. The start ends when the row has a PID: the
    // history keeps the values, and the new row is selected with its chat open.
    @Test func aStartClosesTheDialogAtOnceAndShowsAStartingRow() async throws {
        let h = try await ActionsHarness(active: [Entry.running(s1)])
        let overview = try StartingOverview(h)
        defer { overview.close() }
        let gate = TestGate()
        defer { gate.openAll() }
        h.calls.hold(gate)
        h.calls.answerClaude { _ in startedOutput }
        h.runner.runGlobal(.newSession)
        let model = try h.newSessionDialog()
        model.apply(.cwd("/p"))
        model.apply(.name("bifrost-test-n"))
        model.apply(.model(.haiku))
        model.apply(.mode(.plan))
        await model.submit()
        #expect(!h.dialogs.isOpen)
        // claude --bg runs, and the start shows after the row of the tab.
        await gate.waitUntilHolding()
        #expect(h.runner.starting == [StartingSession(id: 1, name: "bifrost-test-n", cwd: "/p")])
        await overview.waitFor(rows: 2, starting: 1)
        #expect(overview.text(row: 1, .name) == "bifrost-test-n")
        #expect(overview.text(row: 1, .state) == CellContent.startingText)
        #expect(overview.text(row: 1, .project) == OverviewFormat.projectLabel("/p"))
        // Claude Code lists the new job with no PID when claude --bg ends.
        h.deps.lists.active = [Entry.running(s1), Entry.running(newId, pid: nil)]
        gate.openAll()
        await waitUntil { h.row(newId) != nil }
        #expect(h.runner.starting.map(\.shortId) == ["4cb23c30"])
        await overview.waitFor(rows: 2, starting: 0)
        #expect(Set(overview.body.rows.input?.rows.map(\.sessionId) ?? []) == [s1, newId])
        #expect(h.selection.selectedId == nil)
        #expect(!h.chatOpen(newId))
        // A later poll gives the PID, and the start ends.
        h.deps.lists.active = [Entry.running(s1), Entry.running(newId, pid: 5151)]
        await h.deps.poll()
        await h.settle()
        #expect(h.runner.starting.isEmpty)
        #expect(h.selection.selectedId == newId)
        #expect(h.chatOpen(newId))
        #expect(h.runner.error == nil)
        let history = h.runner.history
        #expect(history.recentDirs == ["/p"])
        #expect(history.model == .haiku)
        #expect(history.permissionMode == .plan)
    }

    // A start that fails after the close removes its Starting row, and the error line gives the
    // name and the reason. The dialog stays closed.
    @Test func aFailedStartRemovesTheStartingRowAndShowsTheReason() async throws {
        let h = try await ActionsHarness()
        let overview = try StartingOverview(h)
        defer { overview.close() }
        let gate = TestGate()
        defer { gate.openAll() }
        h.calls.hold(gate)
        h.calls.answerClaude { _ in ExecResult(.exited(1), stderr: "boom") }
        h.runner.runGlobal(.newSession)
        let model = try h.newSessionDialog()
        model.apply(.cwd("/p"))
        model.apply(.name("bifrost-test-n"))
        await model.submit()
        #expect(!h.dialogs.isOpen)
        await gate.waitUntilHolding()
        await overview.waitFor(rows: 1, starting: 1)
        gate.openAll()
        await h.settle()
        #expect(h.runner.starting.isEmpty)
        await overview.waitFor(rows: 0, starting: 0)
        let reason = ActionRefusal.claudeReported("boom").message
        #expect(h.runner.error == "bifrost-test-n didn't start. \(reason)")
        #expect(!h.dialogs.isOpen)
        #expect(h.selection.selectedId == nil)
    }

    // Two clicks start one session: the second submit does nothing. While the start runs, a new
    // dialog is refused by the lock of the starts with its reason, and runs no claude.
    @Test func aSecondClickStartsNoSecondSession() async throws {
        let h = try await ActionsHarness()
        let gate = TestGate()
        defer { gate.openAll() }
        h.calls.hold(gate)
        h.calls.answerClaude { _ in startedOutput }
        h.runner.runGlobal(.newSession)
        let model = try h.newSessionDialog()
        model.apply(.cwd("/p"))
        model.apply(.name("bifrost-test-n"))
        let first = Task { await model.submit() }
        let second = Task { await model.submit() }
        await h.finish(first)
        await h.finish(second)
        let start = try #require(h.runner.lastTask)
        #expect(!h.dialogs.isOpen)
        await gate.waitUntilHolding()
        h.runner.runGlobal(.newSession)
        let again = try h.newSessionDialog()
        again.apply(.cwd("/p"))
        again.apply(.name("bifrost-test-m"))
        await again.submit()
        #expect(again.reason == ActionRefusal.creating.message)
        #expect(!again.busy)
        #expect(h.dialogs.isOpen)
        again.cancel()
        h.deps.lists.active = [Entry.running(newId, pid: 5151)]
        gate.openAll()
        await h.finish(start)
        #expect(h.selection.selectedId == newId)
        #expect(h.calls.claudeRuns.count == 1)
        #expect(h.runner.starting.isEmpty)
    }

    // A failed check of the start keeps the dialog open with the reason, and the fields are on
    // again. No Starting row shows.
    @Test func aFailedStartShowsItsReason() async throws {
        let h = try await ActionsHarness()
        h.deps.claudeFound = false
        h.runner.runGlobal(.newSession)
        let model = try h.newSessionDialog()
        model.apply(.cwd("/p"))
        await model.submit()
        #expect(h.dialogs.isOpen)
        #expect(!model.busy)
        #expect(model.reason == ActionRefusal.claudeNotFound.message)
        #expect(h.runner.starting.isEmpty)
        model.cancel()
        #expect(!h.dialogs.isOpen)
    }

    // While the checks of the start run (here a slow git run of the folder check), Esc, a click
    // on the backdrop and Cancel do nothing, and no claude runs. When the checks pass, the dialog
    // closes.
    @Test func theChecksOfAStartKeepTheDialogOpen() async throws {
        let h = try await ActionsHarness()
        let gate = TestGate()
        defer { gate.openAll() }
        h.calls.holdGit(gate)
        h.runner.runGlobal(.newSession)
        let model = try h.newSessionDialog()
        model.apply(.cwd("/p"))
        let start = Task { await model.submit() }
        await gate.waitUntilHolding()
        #expect(model.busy)
        h.dialogs.escape()
        h.dialogs.backdropClick()
        model.cancel()
        #expect(h.dialogs.isOpen)
        // A change of a field does nothing either.
        model.apply(.name("other"))
        #expect(model.form.name != "other")
        #expect(h.calls.claudeRuns.isEmpty)
        gate.openAll()
        await h.finish(start)
        #expect(!h.dialogs.isOpen)
        await h.settle()
        #expect(h.calls.claudeRuns.count == 1)
    }

    // Only a plain Return with no marked text starts the session (the rules of the send key).
    @Test func onlyAPlainReturnStartsTheSession() {
        func action(
            shift: Bool = false, option: Bool = false, control: Bool = false,
            command: Bool = false, composing: Bool = false, multiline: Bool = false
        ) -> ReturnAction {
            NewSessionDialogModel.returnAction(
                shift: shift, option: option, control: control, command: command,
                composing: composing, multiline: multiline)
        }
        #expect(action() == .start)
        #expect(action(multiline: true) == .start)
        #expect(action(shift: true, multiline: true) == .newLine)
        #expect(action(shift: true) == .nothing)
        #expect(action(option: true) == .nothing)
        #expect(action(control: true, multiline: true) == .nothing)
        #expect(action(command: true) == .nothing)
        // A Return during a composition of the input method ends the composition only.
        #expect(action(composing: true) == .field)
        #expect(action(shift: true, composing: true, multiline: true) == .field)
        // Enter of the numeric keypad is a Return too.
        #expect(NewSessionDialogModel.startKeys == [.return, KeyEquivalent("\u{3}")])
    }

    // Choose... opens at the folder of the form with no white space at its ends.
    @Test func chooseStartsAtTheTrimmedFolder() async throws {
        let h = try await ActionsHarness()
        let starts = FolderStarts()
        h.dialogs.pickFolder = { _, start in
            starts.values.append(start)
            return "/q"
        }
        h.runner.runGlobal(.newSession)
        let model = try h.newSessionDialog()
        model.apply(.cwd("  /p  "))
        await model.browse()
        #expect(starts.values == ["/p"])
        #expect(model.form.cwd == "/q")
    }
}

// The start folders that Choose... gave the folder panel.
@MainActor
private final class FolderStarts {
    var values: [String?] = []
}
