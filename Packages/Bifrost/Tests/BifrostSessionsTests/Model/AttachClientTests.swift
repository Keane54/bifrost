import BifrostTestSupport
import Darwin
import Testing

@testable import BifrostSessions

// The "claude attach" clients of the background sessions (AttachClient) with fake process data,
// and the choice of the terminal app of an owned row from the clients (applyAttachClients).

private let warp = TerminalApp(name: "Warp", bundle: "/Applications/Warp.app")
private let iterm = TerminalApp(name: "iTerm", bundle: "/Applications/iTerm.app")
private let claude = "/Users/x/.local/bin/claude"

private func start(_ seconds: UInt64, _ microseconds: UInt64 = 0) -> ProcessStart {
    ProcessStart(seconds: seconds, microseconds: microseconds)
}

// A client process of "claude attach <argument>".
private func client(
    _ argument: String, ppid: pid_t, started: ProcessStart = start(100)
) -> ProcessEntry {
    ProcessEntry(
        ppid: ppid, comm: claude, arguments: [claude, "attach", argument], started: started)
}

@Suite("the attach client of a process")
struct AttachClientTests {
    // The app is PID 50. A shell of Warp runs a client, and the app runs two clients of its own:
    // one as its direct child and one below a shell. tmux runs a client with no app.
    private static let own: pid_t = 50
    private static let table: ProcessTable = [
        2: ProcessEntry(ppid: 1, comm: "/Applications/Warp.app/Contents/MacOS/stable"),
        3: ProcessEntry(ppid: 2, comm: "-zsh"),
        4: client("b72dc96f", ppid: 3, started: start(200, 5)),
        50: ProcessEntry(ppid: 1, comm: "/Applications/Bifrost.app/Contents/MacOS/Bifrost"),
        51: client("b72dc96f", ppid: own),
        52: ProcessEntry(ppid: own, comm: "/bin/sh"),
        53: client("c0ffee00", ppid: 52),
        60: ProcessEntry(ppid: 1, comm: "tmux"),
        61: client("d00d0000", ppid: 60),
        70: ProcessEntry(ppid: 3, comm: claude, arguments: [claude, "agents", "--json"]),
        71: ProcessEntry(ppid: 3, comm: "-zsh", arguments: ["-zsh"]),
    ]

    @Test func aClientInWarpGivesTheWarpApp() {
        let clients = Self.table.attachClients(own: Self.own)
        let inWarp = AttachClient(
            pid: 4, started: start(200, 5), argument: .idStart("b72dc96f"), app: warp)
        let inTmux = AttachClient(
            pid: 61, started: start(100), argument: .idStart("d00d0000"), app: nil)
        // The two clients of the app are not clients of a terminal, and the other commands are
        // not clients.
        #expect(clients == [inWarp, inTmux])
    }

    @Test func noProcessGivesNoClient() {
        #expect(ProcessTable().attachClients(own: Self.own).isEmpty)
    }

    @Test(
        "the argument of claude attach, as Claude Code reads it",
        arguments: [
            ([claude, "attach", "b72dc96f"], AttachArgument?.some(.idStart("b72dc96f"))),
            (["claude", "attach", "B72DC96F"], .some(.idStart("b72dc96f"))),
            (
                ["claude", "attach", "2f493bf0-1598-4b3b-b419-8acb9cb11bcb"],
                .some(.idStart("2f493bf0-1598-4b3b-b419-8acb9cb11bcb"))
            ),
            (["claude", "attach", "b72d"], .some(.idStart("b72d"))),
            (["claude", "attach", "fix login"], .some(.name("fix login"))),
            (["claude", "attach", "--verbose", "b72dc96f"], .some(.idStart("b72dc96f"))),
            ([" /opt/claude ", "attach", "b72dc96f"], .some(.idStart("b72dc96f"))),
        ])
    func argument(arguments: [String], expected: AttachArgument?) {
        #expect(AttachClient.argument(of: arguments) == expected)
    }

    @Test(
        "another command line has no argument of claude attach",
        arguments: [
            [claude, "attach"],
            [claude, "attach", "--verbose"],
            [claude, "attach", "one", "two"],
            [claude, "attach", ""],
            [claude, "agents", "b72dc96f"],
            ["/usr/bin/node", "attach", "b72dc96f"],
            ["claude/", "attach", "b72dc96f"],
            ["claude-dev", "attach", "b72dc96f"],
            [claude, "--resume", "b72dc96f"],
            [claude, "attach", "b72dc96f", "-a", "-b", "-c", "-d", "-e", "-f"],
            [],
        ])
    func noArgument(arguments: [String]) {
        #expect(AttachClient.argument(of: arguments) == nil)
    }

    // A walk that reaches the app ends at once, also when no app bundle comes before it.
    @Test func aClientBelowTheAppWithNoBundleIsNotAClient() {
        let table: ProcessTable = [
            9: ProcessEntry(ppid: 1, comm: "/usr/bin/swift-run"),
            10: ProcessEntry(ppid: 9, comm: "/tmp/build/Bifrost"),
            11: client("b72dc96f", ppid: 10),
        ]
        #expect(table.attachClients(own: 10).isEmpty)
        #expect(table.attachClients(own: 0).map(\.pid) == [11])
    }
}

@Suite("the attach app of an owned row")
struct AttachAppTests {
    private func clientOf(
        _ argument: AttachArgument, pid: pid_t = 40, started: ProcessStart = start(100),
        app: TerminalApp? = warp
    ) -> AttachClient {
        AttachClient(pid: pid, started: started, argument: argument, app: app)
    }

    private func running() -> SessionRegistry {
        var r = registry()
        r.applyAgents(
            [
                bg(id: "aaaaaaaa", name: "alpha", pid: 5, sessionId: "aaaaaaaa-1111"),
                bg(id: "bbbbbbbb", name: "fix login", pid: 6, sessionId: "bbbbbbbb-2222"),
                bg(id: nil, background: false, name: "term", pid: 7, sessionId: "e1"),
            ], sampledAt: 100)
        return r
    }

    @Test func aClientInWarpGivesTheRowTheWarpApp() {
        var r = running()
        let changed = r.applyAttachClients([clientOf(.idStart("aaaaaaaa"))])
        #expect(changed)
        #expect(r.terminalOf("aaaaaaaa-1111") == warp)
        #expect(r.row("aaaaaaaa-1111")?.terminalApp == "Warp")
        #expect(r.terminalOf("bbbbbbbb-2222") == nil)
        #expect(r.row("bbbbbbbb-2222")?.terminalApp == nil)
        // The same scan again changes nothing.
        let again = r.applyAttachClients([clientOf(.idStart("aaaaaaaa"))])
        #expect(!again)
    }

    @Test func theNewestClientWithAnAppWins() {
        var r = running()
        r.applyAttachClients([
            clientOf(.idStart("aaaaaaaa"), pid: 40, started: start(100), app: warp),
            clientOf(.idStart("aaaaaaaa"), pid: 41, started: start(100, 1), app: iterm),
            // A newer client with no app (tmux) does not hide the newest app.
            clientOf(.idStart("aaaaaaaa"), pid: 42, started: start(300), app: nil),
        ])
        #expect(r.terminalOf("aaaaaaaa-1111") == iterm)
        // Two clients with the same start: the higher PID wins.
        r.applyAttachClients([
            clientOf(.idStart("aaaaaaaa"), pid: 44, started: start(100), app: warp),
            clientOf(.idStart("aaaaaaaa"), pid: 43, started: start(100), app: iterm),
        ])
        #expect(r.terminalOf("aaaaaaaa-1111") == warp)
    }

    @Test func aScanWithNoClientRemovesTheApp() {
        var r = running()
        r.applyAttachClients([clientOf(.idStart("aaaaaaaa"))])
        let removed = r.applyAttachClients([])
        #expect(removed)
        #expect(r.terminalOf("aaaaaaaa-1111") == nil)
        #expect(r.row("aaaaaaaa-1111")?.terminalApp == nil)
        let again = r.applyAttachClients([])
        #expect(!again)
    }

    @Test func theArgumentMatchesAnIDStartOrTheClaudeCodeName() {
        var r = running()
        r.applyAttachClients([clientOf(.name("fix login"))])
        #expect(r.terminalOf("bbbbbbbb-2222") == warp)
        r.applyAttachClients([clientOf(.idStart("aaaaaaaa-1111"))])
        #expect(r.terminalOf("aaaaaaaa-1111") == warp)
        r.applyAttachClients([clientOf(.idStart("bb"))])
        #expect(r.terminalOf("bbbbbbbb-2222") == warp)
    }

    // Claude Code refuses an argument of more than one session, and an external row has no
    // attach, so these clients give no app.
    @Test func anArgumentOfNoRowOrOfTwoRowsGivesNoApp() {
        var r = running()
        r.applyAttachClients([
            clientOf(.idStart("cccccccc")), clientOf(.name("term")), clientOf(.idStart("e1")),
        ])
        #expect(r.rows().allSatisfy { $0.terminalApp == nil })
        var two = registry()
        two.applyAgents(
            [
                bg(id: "abcd0001", name: "one", pid: 5, sessionId: "abcd0001-1"),
                bg(id: "abcd0002", name: "one", pid: 6, sessionId: "abcd0002-2"),
            ], sampledAt: 100)
        two.applyAttachClients([clientOf(.idStart("abcd")), clientOf(.name("one"))])
        #expect(two.rows().allSatisfy { $0.terminalApp == nil })
    }

    @Test func aParkedRowHasNoAttachApp() {
        var r = registry()
        r.applyAgents([], sampledAt: 300, turn: 2)
        r.applyAllAgents([bg(pid: nil, status: .unknown)], complete: true, turn: 1)
        #expect(r.row("s1")?.state == .parked)
        #expect(r.hasOwnedSession)
        r.applyAttachClients([clientOf(.idStart("aaaaaaaa"))])
        #expect(r.terminalOf("s1") == nil)
        #expect(r.row("s1")?.terminalApp == nil)
    }

    @Test func onlyAnOwnedSessionNeedsTheScan() {
        var r = registry()
        #expect(!r.hasOwnedSession)
        r.applyAgents([bg(id: nil, background: false, pid: 7, sessionId: "e1")], sampledAt: 100)
        #expect(!r.hasOwnedSession)
        r.applyAgents([bg()], sampledAt: 200)
        #expect(r.hasOwnedSession)
    }
}
