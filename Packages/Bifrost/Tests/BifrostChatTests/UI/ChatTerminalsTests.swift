import AppKit
import BifrostFoundation
import BifrostSessions
import BifrostTestSupport
import BifrostWindows
import Foundation
import SwiftTerm
import Testing

@testable import BifrostChat
@testable import BifrostLayout

// The set of chat terminals and their lifecycle, on real PTYs with the fake attach of
// scripts/fake-claude. The open chat panels of the layout decide which terminals exist. The
// window is never ordered front.
@Suite("chat terminals", .serialized, .timeLimit(.minutes(2)), .tags(.realProcess, .window))
@MainActor
struct ChatTerminalsTests {
    // The chats keep no copy of the rows: the attach check reads the session list. So it sees a
    // row in the turn that the registry adds it, before Observation tells the shell. The match
    // of a wait for the row runs in that turn, right after the registry sets its rows.
    @Test func theAttachCheckSeesARowThatTheRegistryAddsInTheSameTurn() async throws {
        let id: SessionID = "73b5ca76-a4a8-4f97-9764-e41657296414"
        let entry = AgentEntry(
            sessionId: id.text, cwd: "/tmp", isBackground: true, name: "alpha", status: .idle,
            pid: 5, id: "73b5ca76")
        let registry = RegistryService(
            registry: SessionRegistry(store: RegistryStore(), escalation: .seconds(600)),
            deps: FixedRegistryDeps(active: [entry]), clock: ManualClock(),
            log: Recorder<SessionsLogEvent>())
        defer { registry.stop() }
        let list = SessionListModel()
        list.read(from: registry)
        let chats = ChatTerminals(
            ptys: nil, sizes: SessionSizeReader(inspector: FakeProcessInspector()),
            rows: { list.rows }, clock: ManualClock(),
            links: LinkOpener(apps: NoDefaultApps()) { _ in }, pasteboard: .withUniqueName(),
            renderer: .metal)
        let view = PTYView.chat(id)
        #expect(throws: AttachRefusal.notOwnedAttach) {
            try chats.checkAttach(view, shortId: "73b5ca76")
        }
        let seen = SeenAttach()
        let found = Task {
            seen.waiting = true
            return try await registry.waitForRow(timeout: .seconds(10)) { row in
                guard row.sessionId == id.text else { return false }
                seen.checked = try? chats.checkAttach(view, shortId: "73b5ca76")
                return true
            }
        }
        // The wait is in place before the first poll, so the match runs in the turn of the
        // change.
        await waitUntil { seen.waiting }
        registry.start()
        _ = try await found.value
        #expect(seen.checked?.view == view)
        #expect(seen.checked?.directory == "/tmp")
    }

    // A stack, a tab change and a tear-back keep the terminal, its PTY and its one attach.
    @Test func aStackAndATabChangeKeepTheAttach() async throws {
        let chat = try ChatFixture()
        let frame = chat.open()
        let other = chat.openPanel(panel("watchlist"), at: rect(700, 0, 300, 300))
        try #require(await chat.waitForAttach())
        let terminal = try chat.terminal()
        let pid = try #require(chat.ptys.list().first?.pid)
        chat.model.apply(.stack(frame, onto: other))
        #expect(chat.model.layout.frames.count == 1)
        chat.model.apply(.activate(panel("watchlist")))
        #expect(!terminal.state.metal)
        chat.model.apply(.activate(chat.panel()))
        #expect(try chat.terminal() === terminal)
        #expect(terminal.view.window === chat.window)
        // A new attach closes the old one first, in the same turn: no close went.
        #expect(chat.spawner.log.signals.isEmpty)
        #expect(chat.ptys.list().map(\.pid) == [pid])
        #expect(chat.attachLines == ["FAKE ATTACH 5a0e0001"])
        #expect(terminal.state.attached)
        await chat.close()
    }

    // A close of the chat panel detaches: the attach child ends, and the terminal goes. A new
    // open makes a new terminal, which attaches again. The attached chats (the Bifrost icon of
    // the Overview) hold the session only while its chat attach runs.
    @Test func aClosedChatDetaches() async throws {
        let chat = try ChatFixture()
        let attached = chat.chats.attachedChats
        #expect(!attached.contains(FakeSession.first))
        chat.open()
        try #require(await chat.waitForAttach())
        let first = try chat.terminal()
        #expect(attached.sessions == [FakeSession.first])
        let child = try #require(chat.ptys.list().first?.pid)
        chat.model.apply(.close(chat.panel()))
        #expect(chat.chats.terminal(FakeSession.first) == nil)
        #expect(chat.ptys.list().isEmpty)
        #expect(attached.sessions.isEmpty)
        #expect(await waitUntil { kill(child, 0) != 0 }, "The attach child did not end.")
        #expect(!first.state.attached)
        chat.open()
        await waitUntil { chat.attachLines.count == 2 }
        let second = try chat.terminal()
        #expect(second !== first)
        await waitUntil { second.state.attached }
        #expect(attached.contains(FakeSession.first))
        await chat.close()
    }

    // A closed chat frees its terminal and its view (updateUiClosed releases the drivers and the
    // Metal renderer of SwiftTerm).
    @Test func aClosedChatFreesItsTerminalAndItsView() async throws {
        let chat = try ChatFixture()
        chat.open()
        try #require(await chat.waitForAttach())
        weak var terminal: ChatTerminal?
        weak var view: ChatTerminalView?
        do {
            let open = try chat.terminal()
            let shown = open.view
            #expect(shown.isUsingMetalRenderer)
            terminal = open
            view = shown
            chat.model.apply(.close(chat.panel()))
            // The release of the UI stops the Metal renderer of the closed view.
            await waitUntil { !shown.isUsingMetalRenderer }
        }
        await waitUntil { terminal == nil && view == nil }
        await chat.close()
    }

    // The agent view of the screen makes the window attach again. The reattach closes the old
    // attach first, and its spawn waits at a gate. The window closes during that spawn (C6):
    // when the spawn ends, the manager closes the new child. Each child gets one SIGHUP, by its
    // pid, and ends.
    @Test func aCloseDuringAReattachEndsTheOldAndTheNewChild() async throws {
        let chat = try ChatFixture()
        try chat.writeScreen(Self.agentView)
        let first = TestGate()
        defer { first.openAll() }
        let reattach = TestGate()
        defer { reattach.openAll() }
        chat.spawner.holdNext(first)
        chat.spawner.holdNext(reattach)
        chat.open()
        await first.waitUntilHolding()
        first.open()
        await reattach.waitUntilHolding()
        // The reattach closed the old attach before its spawn. The window still shows the
        // session, so the attached chats keep it until the close.
        let old = try #require(chat.spawner.log.pids.first)
        #expect(chat.spawner.log.signals.map(\.pid) == [old])
        #expect(chat.chats.attachedChats.contains(FakeSession.first))
        chat.model.apply(.close(chat.panel()))
        #expect(chat.chats.terminal(FakeSession.first) == nil)
        #expect(!chat.chats.attachedChats.contains(FakeSession.first))
        reattach.open()
        await waitUntil { chat.spawner.log.signals.count == 2 }
        let log = chat.spawner.log
        #expect(log.pids.count == 2)
        #expect(log.signals.map(\.pid) == log.pids)
        #expect(log.signals.allSatisfy { $0.signal == .hangup })
        #expect(chat.ptys.list().isEmpty)
        await waitUntil { log.pids.allSatisfy { kill($0, 0) != 0 } }
        await chat.close()
    }

    // The same close during a reattach, and a newer window of the session waits for the session
    // list. The end of the old spawn closes only its own child. The newer window then attaches
    // with its own PTY, and gets no signal (C6).
    @Test func aCloseDuringAReattachGivesNoEffectToANewerWindow() async throws {
        let chat = try ChatFixture()
        try chat.writeScreen(Self.agentView)
        let first = TestGate()
        defer { first.openAll() }
        let reattach = TestGate()
        defer { reattach.openAll() }
        chat.spawner.holdNext(first)
        chat.spawner.holdNext(reattach)
        chat.open()
        await first.waitUntilHolding()
        first.open()
        await reattach.waitUntilHolding()
        // The next attaches show a normal screen. The window closes, and a newer window of the
        // session waits for the session list.
        try chat.writeScreen("NORMAL SCREEN")
        chat.chats.sync(layout: WindowLayout(bounds: LayoutSize(w: 1200, h: 800)), loaded: true)
        chat.sync(loaded: false)
        let newer = try chat.terminal()
        #expect(!newer.state.attached)
        #expect(newer.state.note == AttachRefusal.waitingForList.message)
        reattach.open()
        await waitUntil { chat.spawner.log.signals.count == 2 }
        #expect(chat.ptys.list().isEmpty)
        let closed = chat.spawner.log.pids
        try #require(closed.count == 2)
        chat.sync()
        await waitUntil { newer.state.attached }
        let log = chat.spawner.log
        #expect(log.pids.count == 3)
        #expect(chat.ptys.list().map(\.pid) == [log.pids[2]])
        #expect(log.signals.map(\.pid) == closed)
        await waitUntil { closed.allSatisfy { kill($0, 0) != 0 } }
        #expect(kill(log.pids[2], 0) == 0)
        await chat.close()
    }

    // The spawn of the first open waits at a gate (a slow posix_spawn). A
    // close of the chat during the spawn: when the spawn ends, the manager closes the new child
    // (one SIGHUP, to its pid), and the chat has no PTY.
    @Test func aCloseDuringTheSpawnEndsTheNewChild() async throws {
        let chat = try ChatFixture()
        let gate = TestGate()
        defer { gate.openAll() }
        chat.spawner.holdNext(gate)
        chat.open()
        await gate.waitUntilHolding()
        let terminal = try chat.terminal()
        #expect(!terminal.state.attached)
        chat.model.apply(.close(chat.panel()))
        #expect(chat.chats.terminal(FakeSession.first) == nil)
        gate.open()
        await waitUntil { chat.spawner.log.signals.count == 1 }
        let log = chat.spawner.log
        try #require(log.pids.count == 1)
        #expect(log.signals.map(\.pid) == log.pids)
        #expect(log.signals.first?.signal == .hangup)
        #expect(chat.ptys.list().isEmpty)
        #expect(await waitUntil { kill(log.pids[0], 0) != 0 }, "The new child did not end.")
        #expect(!terminal.state.attached)
        await chat.close()
    }

    // A chat that closes in the same turn of the main actor as its open effect: its open task
    // finds the closed window and starts no spawn.
    @Test func aChatThatClosesBeforeItsOpenStartsSpawnsNothing() async throws {
        let chat = try ChatFixture()
        chat.open()
        let terminal = try chat.terminal()
        guard case .opening(let opening) = terminal.attachState else {
            Issue.record("The open effect started no open task: \(terminal.attachState)")
            return
        }
        chat.model.apply(.close(chat.panel()))
        #expect(chat.chats.terminal(FakeSession.first) == nil)
        // The open task ends when it finds the closed window.
        await opening.value
        #expect(chat.spawner.log.opens.isEmpty)
        #expect(chat.ptys.list().isEmpty)
        #expect(chat.attachLines.isEmpty)
        await chat.close()
    }

    // The first open waits at its gate, the chat closes, and a newer window of the session opens
    // and attaches before the old spawn ends. The end of the old spawn closes only its own child:
    // the newer window keeps its PTY, gets no signal, and its input reaches the session.
    @Test func aNewerWindowThatOpensDuringTheSpawnKeepsItsPTY() async throws {
        let chat = try ChatFixture()
        let gate = TestGate()
        defer { gate.openAll() }
        chat.spawner.holdNext(gate)
        chat.open()
        await gate.waitUntilHolding()
        chat.model.apply(.close(chat.panel()))
        chat.open()
        let newer = try chat.terminal()
        await waitUntil { newer.state.attached }
        try #require(await chat.waitForAttach())
        let kept = try #require(chat.ptys.list().first?.pid)
        gate.open()
        await waitUntil { chat.spawner.log.signals.count == 1 }
        let log = chat.spawner.log
        try #require(log.pids.count == 2)
        let old = try #require(log.pids.first { $0 != kept })
        #expect(log.signals.map(\.pid) == [old])
        #expect(chat.ptys.list().map(\.pid) == [kept])
        #expect(await waitUntil { kill(old, 0) != 0 }, "The old child did not end.")
        #expect(kill(kept, 0) == 0)
        #expect(newer.state.attached)
        #expect(!newer.state.ended)
        await waitUntil { chat.window.firstResponder === newer.view }
        chat.type("hi")
        await waitUntil { contains(chat.input(), bytes("hi")) }
        await chat.close()
    }

    private static let agentView =
        "\u{1b}[2J\u{1b}[H0 awaiting input · 0 working · 6 completed\r\n\r\n"
        + "enter to return · space to reply · ? for shortcuts\r\n"

    // The agent view of each attach makes the window attach again, 3 times in 60 seconds, then
    // give up. A new window of the session reads the same history: its first check gives up at
    // once, with no other attach.
    @Test func aNewWindowOfASessionKeepsItsAttachHistory() async throws {
        let chat = try ChatFixture()
        try chat.writeScreen(
            "\u{1b}[2J\u{1b}[H0 awaiting input · 0 working · 6 completed\r\n\r\n"
                + "enter to return · space to reply · ? for shortcuts\r\n")
        chat.open()
        let first = try chat.terminal()
        await waitUntil {
                first.state.note == ChatTerminal.giveUpText
            }
        #expect(chat.attachLines.count == 4)
        chat.model.apply(.close(chat.panel()))
        chat.open()
        let second = try chat.terminal()
        #expect(second !== first)
        await waitUntil {
                second.state.note == ChatTerminal.giveUpText
            }
        #expect(chat.attachLines.count == 5)
        #expect(second.state.blocked)
        await chat.close()
    }

    // A window close detaches each chat. A reopen syncs again, so each chat attaches again, in
    // the body that the canvas still shows.
    @Test func aWindowCloseDetachesAllAndAReopenAttachesAgain() async throws {
        let chat = try ChatFixture(rows: { folder in
            [
                FakeSession.row(folder: folder),
                FakeSession.row(FakeSession.second, folder: folder),
            ]
        })
        chat.open()
        chat.open(FakeSession.second, at: rect(650, 0, 400, 300))
        try #require(await chat.waitForAttach())
        try #require(await chat.waitForAttach(FakeSession.second))
        let children = chat.ptys.list().map(\.pid)
        #expect(children.count == 2)
        let bodies = try [chat.terminal().body, chat.terminal(FakeSession.second).body]
        #expect(chat.chats.attachedChats.sessions == [FakeSession.first, FakeSession.second])
        chat.chats.detachAll()
        #expect(chat.chats.terminal(FakeSession.first) == nil)
        #expect(chat.chats.terminal(FakeSession.second) == nil)
        #expect(chat.ptys.list().isEmpty)
        #expect(chat.chats.attachedChats.sessions.isEmpty)
        await waitUntil { children.allSatisfy { kill($0, 0) != 0 } }
        // The reopen.
        chat.sync()
        await waitUntil { chat.attachLines.count == 4 }
        #expect(chat.attachLines.sorted() == [
            "FAKE ATTACH 5a0e0001", "FAKE ATTACH 5a0e0001", "FAKE ATTACH 5a0e0002",
            "FAKE ATTACH 5a0e0002",
        ])
        let again = try [chat.terminal(), chat.terminal(FakeSession.second)]
        #expect(again[0].body === bodies[0])
        #expect(again[1].body === bodies[1])
        #expect(again.allSatisfy { $0.view.window === chat.window })
        await waitUntil { again.allSatisfy(\.state.attached) }
        // The chat of the top frame gets the keyboard focus again.
        await waitUntil { chat.window.firstResponder === again[1].view }
        await chat.close()
    }

    // The list of the chats and the focused chat, for the state and the keys of the debug test
    // port: the chat of the top frame has the keyboard focus. With the focus on the
    // window, no chat is focused.
    @Test func theTestPortSeesTheChatsAndTheFocusedChat() async throws {
        let chat = try ChatFixture(rows: { home in
            [FakeSession.row(folder: home), FakeSession.row(FakeSession.second, folder: home)]
        })
        #expect(chat.chats.sessionIds.isEmpty)
        #expect(chat.chats.focusedSession == nil)
        chat.open()
        chat.open(FakeSession.second, at: rect(650, 0, 400, 300))
        #expect(chat.chats.sessionIds == [FakeSession.first, FakeSession.second])
        await waitUntil { chat.chats.focusedSession == FakeSession.second }
        _ = chat.window.makeFirstResponder(nil)
        #expect(chat.chats.focusedSession == nil)
        await chat.close()
    }
}

// The check that the match of a wait for a row made, and true once the wait started.
@MainActor
private final class SeenAttach {
    var waiting = false
    var checked: CheckedAttach?
}
