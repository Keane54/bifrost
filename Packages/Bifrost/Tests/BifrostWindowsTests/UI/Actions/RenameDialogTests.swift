// The Rename dialog (docs/behaviour/actions.md, "Rename"): the check box "Also rename it in Claude
// Code" shows only for an owned row that runs, the lost note shows when the box is on but the row
// cannot take /rename now, and a save then keeps the name in Bifrost only. The dialog reads the
// row of now at each step.
import BifrostSessions
import BifrostTestSupport
import Testing

@testable import BifrostWindows

@Suite("the Rename dialog", .serialized, .testTimeLimit, .tags(.window))
@MainActor
struct RenameDialogTests {
    @Test func theBoxIsHiddenForAnExternalRow() async throws {
        let h = try await ActionsHarness(active: [Entry.interactive(s3), Entry.running(s1)])
        h.runner.run(.rename, s3)
        let external = try h.renameDialog()
        #expect(external.title == "Rename")
        #expect(external.name == "bifrost-test-x")
        #expect(external.controls?.claudeBox == .hidden)
        #expect(!external.showsClaudeBox)
        external.cancel()
        #expect(!h.dialogs.isOpen)
        h.runner.run(.rename, s1)
        let owned = try h.renameDialog()
        #expect(owned.controls?.claudeBox == .enabled)
        #expect(owned.showsClaudeBox)
    }

    @Test func theLostNoteShowsWhenTheBoxCannotAct() async throws {
        let h = try await ActionsHarness(active: [Entry.running(s1)])
        h.runner.run(.rename, s1)
        let model = try h.renameDialog()
        model.alsoClaude = true
        #expect(model.lostNote == nil)
        // A prompt comes up: typed text could answer it, so the box cannot act now.
        await h.deps.show([Entry.running(s1, status: .waiting, waitingFor: "permission")]) {
            $0.first?.alert.blocksPrompt == true
        }
        #expect(model.controls?.claudeBox == .disabled(.input(.prompt)))
        #expect(model.lostNote == RenameRules.lostNoteText)
        // The save keeps the name in Bifrost only, and types nothing.
        model.name = "  mine  "
        await model.submit()
        #expect(!h.dialogs.isOpen)
        #expect(h.row(s1)?.name == "mine")
        #expect(h.spawner.spawns.isEmpty)
    }

    // A save with the check box types /rename and the name into the session. The send clears the
    // local name, and the dialog closes.
    @Test func aSaveWithTheBoxTypesRenameAndClearsTheLocalName() async throws {
        let h = try await ActionsHarness(
            store: RegistryStore(aliases: [s1: "mine"]), active: [Entry.running(s1)])
        try await h.quietChat(s1, shortId: short1)
        h.runner.run(.rename, s1)
        let model = try h.renameDialog()
        model.alsoClaude = true
        model.name = "fresh"
        let save = Task { await model.submit() }
        await h.drive(save)
        #expect(h.typed.contains("/rename fresh"))
        #expect(model.reason == nil)
        #expect(!h.dialogs.isOpen)
        #expect(h.row(s1)?.name == "bifrost-test-s")
    }

    // A name that the rules refuse keeps the dialog open with the reason. Use the Claude Code
    // name clears the local name.
    @Test func aRefusedNameShowsItsReasonAndResetClearsTheName() async throws {
        let h = try await ActionsHarness(
            store: RegistryStore(aliases: [s1: "mine"]), active: [Entry.running(s1)])
        h.runner.run(.rename, s1)
        let model = try h.renameDialog()
        #expect(model.name == "mine")
        #expect(model.controls?.showReset == true)
        model.name = String(repeating: "a", count: 65)
        await model.submit()
        #expect(h.dialogs.isOpen)
        #expect(model.reason == ActionRefusal.alias(.tooLong).message)
        model.reset()
        #expect(!h.dialogs.isOpen)
        #expect(h.row(s1)?.name == "bifrost-test-s")
    }

    // A click on the backdrop closes the Rename dialog with no change.
    @Test func aClickOnTheBackdropClosesTheDialog() async throws {
        let h = try await ActionsHarness(active: [Entry.running(s1)])
        h.runner.run(.rename, s1)
        let model = try h.renameDialog()
        model.name = "other"
        h.dialogs.backdropClick()
        #expect(!h.dialogs.isOpen)
        #expect(h.row(s1)?.name == "bifrost-test-s")
    }

    // While a save runs, Esc, a click on the backdrop and Cancel do nothing.
    @Test func aSaveThatRunsKeepsTheDialogOpen() async throws {
        let h = try await ActionsHarness(active: [Entry.running(s1)])
        let gate = TestGate()
        defer { gate.openAll() }
        h.runner.run(.rename, s1)
        let model = try h.renameDialog()
        model.alsoClaude = true
        h.spawner.holdNext(gate)
        h.spawner.failNext(PTYError(message: "The spawn failed."))
        let save = Task { await model.submit() }
        await gate.waitUntilHolding()
        #expect(model.busy)
        h.dialogs.escape()
        h.dialogs.backdropClick()
        model.cancel()
        #expect(h.dialogs.isOpen)
        gate.openAll()
        await h.finish(save)
        #expect(!model.busy)
        #expect(h.dialogs.isOpen)
        model.cancel()
        #expect(!h.dialogs.isOpen)
    }
}
