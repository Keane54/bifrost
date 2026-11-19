// The sharer of the folder of a row (docs/behaviour/actions.md, "Worktrees"): another row in the
// same worktree, in any state. RuleEdgeTests has the cases of the worktree root of a path.
import BifrostTestSupport
import Testing

@testable import BifrostSessions

private let wt = "/r/.claude/worktrees/w1"

private func row(
    _ sessionId: String, cwd: String = "/r", state: SessionState = .idle, worktree: String? = nil
) -> SessionRow {
    var row = SessionRow.test(sessionId: sessionId, cwd: cwd, state: state)
    row.worktree = worktree
    return row
}

// A stopped worktree session reports its start folder as its cwd. The row keeps the worktree.
private let old = row("a", state: .parked, worktree: wt)

@Suite("the sharer of a folder")
struct FolderSharerTests {
    @Test func aRunningRowInTheWorktreeOfAParkedRowSharesTheFolder() {
        let other = row("b", cwd: "\(wt)/src", state: .working)
        #expect(folderSharer(of: old, in: [old, other]) == other)
    }

    @Test func aParkedRowAlsoSharesTheFolder() {
        let other = row("b", cwd: wt, state: .parked)
        #expect(folderSharer(of: old, in: [old, other]) == other)
    }

    @Test func theStoredWorktreeOfTheOtherRowCounts() {
        let stored = row("b", state: .parked, worktree: wt)
        #expect(folderSharer(of: old, in: [stored, old]) == stored)
    }

    @Test func theStateOfTheRowItselfDoesNotMatter() {
        let running = row("a", cwd: "\(wt)/src")
        let other = row("b", cwd: wt, state: .needsYou)
        #expect(folderSharer(of: running, in: [running, other]) == other)
    }

    @Test func theFirstSharerInTheOrderOfTheRowsComes() {
        let first = row("b", cwd: wt)
        let second = row("c", cwd: "\(wt)/docs")
        #expect(folderSharer(of: old, in: [old, first, second]) == first)
    }

    @Test func aPlainFolderHasNoSharer() {
        let plain = row("a", state: .parked)
        #expect(folderSharer(of: plain, in: [plain, row("b")]) == nil)
    }

    @Test func anotherWorktreeOfTheSameRepositoryIsNoSharer() {
        let other = row("b", cwd: "/r/.claude/worktrees/w2")
        #expect(folderSharer(of: old, in: [old, other]) == nil)
    }

    // A copy of the row that runs again has the same row ID, so it is the row itself.
    @Test func theRowItselfNeverCounts() {
        #expect(folderSharer(of: old, in: [old]) == nil)
        #expect(folderSharer(of: old, in: [row("a", cwd: wt)]) == nil)
    }
}
