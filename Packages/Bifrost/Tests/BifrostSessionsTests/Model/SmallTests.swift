import BifrostTestSupport
import Foundation
import Testing

@testable import BifrostFoundation
@testable import BifrostSessions

// The terminal app of a process. The edge cases are in RuleEdgeTests.

private let warp: ProcessTable = [
    63362: ProcessEntry(ppid: 931, comm: "claude"),
    931: ProcessEntry(ppid: 866, comm: "-zsh"),
    866: ProcessEntry(ppid: 1, comm: "/Applications/Warp.app/Contents/MacOS/stable"),
]

@Suite("the terminal app of a process")
struct TerminalAppTests {
    @Test("the terminal app finder finds Warp in the chain")
    func findsWarp() {
        #expect(
            warp.terminalApp(of: 63362)
                == TerminalApp(name: "Warp", bundle: "/Applications/Warp.app"))
    }

    @Test("the terminal app finder takes the outermost app of a helper path")
    func outermost() {
        let table: ProcessTable = [
            5: ProcessEntry(
                ppid: 1,
                comm: "/Applications/Visual Studio Code.app/Contents/Frameworks/"
                    + "Code Helper.app/Contents/MacOS/Code Helper")
        ]
        #expect(
            table.terminalApp(of: 5)
                == TerminalApp(
                    name: "Visual Studio Code", bundle: "/Applications/Visual Studio Code.app"))
    }

    @Test("the terminal app finder gives nothing without an app, for an unknown PID and for a loop")
    func nullCases() {
        let none: ProcessTable = [
            5: ProcessEntry(ppid: 4, comm: "claude"), 4: ProcessEntry(ppid: 1, comm: "-zsh"),
        ]
        #expect(none.terminalApp(of: 5) == nil)
        #expect(none.terminalApp(of: 99) == nil)
        let loop: ProcessTable = [
            2: ProcessEntry(ppid: 3, comm: "a"), 3: ProcessEntry(ppid: 2, comm: "b"),
        ]
        #expect(loop.terminalApp(of: 2) == nil)
    }
}

@Suite("branch from HEAD text")
struct BranchOfHeadTests {
    @Test("a branch, a detached head and other text are read")
    func reads() {
        #expect(branchOfHead("ref: refs/heads/feat/a\n") == "feat/a")
        #expect(branchOfHead(String(repeating: "a", count: 40) + "\n") == "HEAD")
        #expect(branchOfHead(String(repeating: "B", count: 64) + "\n") == "HEAD")
        #expect(branchOfHead("ref: refs/remotes/origin/x") == nil)
        #expect(branchOfHead("") == nil)
    }
}
