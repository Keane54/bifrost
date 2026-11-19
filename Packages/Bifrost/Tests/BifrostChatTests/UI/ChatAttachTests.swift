import AppKit
import BifrostLayout
import BifrostSessions
import BifrostTestSupport
import BifrostWindows
import Foundation
import Observation
import SwiftTerm
import Synchronization
import Testing

@testable import BifrostChat

// The attach of one chat window (docs/behaviour/chat.md): the reasons of a window that waits,
// the end lines, no new try, the agent view guard and the restart. Each test uses the fake PTY
// and the manual clock of the fixture: no child process starts, and the test gives the output and
// the exit of each attach. The window is never ordered front.

// The footer and the counts line of the agent view.
@MainActor
private let agentScreen =
    "\u{1b}[2J\u{1b}[H0 awaiting input · 0 working · 6 completed\r\n\r\n"
    + "enter to return · space to reply · ? for shortcuts\r\n"
// A prompt of Claude Code with no agent view.
@MainActor
private let promptScreen = "\u{1b}[2J\u{1b}[H> hello\r\n  ? for shortcuts\r\n"

@Suite("chat attach", .serialized, .timeLimit(.minutes(1)), .tags(.window))
@MainActor
struct ChatAttachTests {
    // Open the chat of the first session, focused, and wait for its attach.
    private func attached(_ chat: ChatFixture) async throws -> (ChatTerminal, FakeChild) {
        chat.open()
        let terminal = try chat.terminal()
        try #require(await waitUntil { terminal.state.attached })
        return (terminal, try #require(chat.fakes.fakes.last))
    }

    // The newest attach shows the screen, and the screen gets quiet for the time of a check.
    private func show(_ screen: String, _ chat: ChatFixture) async throws {
        let terminal = try chat.terminal()
        let fed = terminal.benchOutput
        try #require(chat.fakes.fakes.last).emitData(screen)
        try #require(await waitUntil { terminal.benchOutput > fed })
        await chat.advance(by: AgentView.quiet)
    }

    // The times of the recent attaches of the session, after the start of the chats.
    private func history(_ chat: ChatFixture) -> [Duration] {
        let history = chat.chats.attachHistory[FakeSession.first] ?? []
        return history.map { chat.chats.start.duration(to: $0) }
    }

    @Test func eachReasonOfAWindowThatWaitsShows() async throws {
        let chat = try ChatFixture(rows: { _ in [] }, fakePTY: true)
        chat.open()
        let terminal = try chat.terminal()
        chat.sync(loaded: false)
        #expect(terminal.state.note == AttachRefusal.waitingForList.message)
        #expect(terminal.body.noteText == AttachRefusal.waitingForList.message)
        chat.sync()
        #expect(terminal.state.note == AttachRefusal.gone.message)
        let home = chat.home
        chat.rows = [FakeSession.row(folder: home, kind: .external)]
        chat.sync()
        #expect(terminal.state.note == AttachRefusal.external.message)
        chat.rows = [FakeSession.row(folder: home, state: .parked)]
        chat.sync()
        #expect(terminal.state.note == AttachRefusal.parked.message)
        var noId = FakeSession.row(folder: home)
        noId.shortId = nil
        chat.rows = [noId]
        chat.sync()
        #expect(terminal.state.note == AttachRefusal.waitingForID.message)
        await chat.advance(by: .seconds(1))
        #expect(chat.fakes.spawns.isEmpty)
        // A row that can attach: the window attaches in the folder of the row.
        chat.rows = [FakeSession.row(folder: home)]
        chat.sync()
        await waitUntil { terminal.state.attached }
        #expect(terminal.state.note == nil)
        #expect(terminal.body.noteText == nil)
        let spawn = try #require(chat.fakes.spawns.first)
        #expect(spawn.arguments == ["attach", FakeSession.shortId(FakeSession.first)])
        #expect(spawn.directory == home)
        #expect(chat.fakes.spawns.count == 1)
        await chat.close()
    }

    @Test func anExitShowsTheEndLineAndTheWindowDoesNotAttachAgain() async throws {
        let chat = try ChatFixture(fakePTY: true)
        let (terminal, child) = try await attached(chat)
        // A restart of a window that did not end does nothing.
        terminal.restart()
        child.emitExit(3)
        await waitUntil { terminal.state.ended }
        #expect(chat.screen().contains("[process ended: code 3]"))
        #expect(!terminal.state.attached)
        #expect(!terminal.hasPTY)
        #expect(terminal.isShowingText)
        // The rows, a focus change and the time open nothing.
        chat.sync()
        let other = chat.openPanel(panel("watchlist"), at: rect(700, 0, 300, 300))
        chat.model.apply(.focus(try #require(chat.model.layout.frame(of: chat.panel())).id))
        chat.model.apply(.focus(other))
        await chat.advance(by: .seconds(5))
        // A new attach leaves the end state in the turn of its start.
        #expect(terminal.state.ended)
        #expect(chat.fakes.spawns.count == 1)
        await chat.close()
    }

    // The attach closes with no exit code (a quit closes each attach). The window still counts as
    // attached, and its next write ends it.
    @Test func aWriteToAClosedAttachEndsTheWindow() async throws {
        let chat = try ChatFixture(fakePTY: true)
        let (terminal, child) = try await attached(chat)
        chat.ptys.closeAll()
        #expect(child.signals == [.hangup])
        await waitUntil { !terminal.hasPTY }
        #expect(terminal.state.attached)
        #expect(!terminal.hasPTY)
        terminal.terminalData(bytes("x"))
        #expect(terminal.state.ended)
        #expect(chat.screen().contains("[input failed: the attach ended]"))
        #expect(child.written.isEmpty)
        await chat.advance(by: .seconds(5))
        #expect(terminal.state.ended)
        #expect(chat.fakes.spawns.count == 1)
        await chat.close()
    }

    // A failed open has no new try: the user closes the window and opens it again.
    @Test func aFailedOpenEndsWithNoNewTry() async throws {
        let chat = try ChatFixture(fakePTY: true)
        let message = "Cannot start claude: No such file or directory."
        chat.fakes.failNext(PTYError(message: message))
        chat.open()
        let terminal = try chat.terminal()
        await waitUntil { terminal.state.ended }
        #expect(chat.screen().contains("[open failed: \(message)]"))
        #expect(terminal.isShowingText)
        chat.sync()
        chat.openPanel(panel("watchlist"), at: rect(700, 0, 300, 300))
        await chat.advance(by: .seconds(5))
        #expect(terminal.state.ended)
        #expect(chat.fakes.spawns.isEmpty)
        #expect(chat.ptys.list().isEmpty)
        await chat.close()
    }

    // The agent view blocks the input. The old attach closes after the wait for the session
    // input, just before the spawn of the new attach, and the new attach frees the input.
    @Test func theAgentViewBlocksTheInputAndAttachesAgain() async throws {
        let chat = try ChatFixture(fakePTY: true)
        let (terminal, first) = try await attached(chat)
        let gate = TestGate()
        defer { gate.openAll() }
        chat.fakes.holdNext(gate)
        first.emitData(agentScreen)
        await waitUntil { chat.screen().contains("enter to return") }
        let grid = terminal.view.terminalDimensions
        // No check before 250 ms of quiet.
        await chat.advance(by: AgentView.quiet - .milliseconds(1))
        #expect(!terminal.state.blocked)
        await chat.advance(by: .milliseconds(1))
        await gate.waitUntilHolding()
        #expect(terminal.state.blocked)
        #expect(!terminal.state.attached)
        #expect(first.signals == [.hangup])
        #expect(!chat.screen().contains("enter to return"))
        #expect(history(chat) == [AgentView.quiet])
        terminal.terminalData(bytes("a"))
        gate.open()
        await waitUntil { terminal.state.attached }
        #expect(!terminal.state.blocked)
        let second = try #require(chat.fakes.fakes.last)
        #expect(second !== first)
        // The new attach opens at the size of the terminal at the check.
        #expect(chat.fakes.spawns.last?.size == TerminalSize(cols: grid.cols, rows: grid.rows))
        terminal.terminalData(bytes("b"))
        #expect(second.written == [bytes("b")])
        #expect(first.written.isEmpty)
        await chat.close()
    }

    // 3 attaches in 60 seconds: the next agent view gives up and keeps the input blocked. The end
    // keeps the note. A restart starts a new guard but keeps the history of the session.
    @Test func theAgentViewGuardGivesUpAfter3AttachesIn60Seconds() async throws {
        let chat = try ChatFixture(fakePTY: true)
        let (terminal, _) = try await attached(chat)
        for count in 2...4 {
            try await show(agentScreen, chat)
            await waitUntil { chat.fakes.fakes.count == count && terminal.state.attached }
        }
        #expect(history(chat) == [250, 500, 750].map(Duration.milliseconds))
        try await show(agentScreen, chat)
        #expect(terminal.state.note == ChatTerminal.giveUpText)
        #expect(terminal.state.blocked)
        #expect(terminal.state.attached)
        // A window that gave up checks no more, and its input goes nowhere.
        try await show(agentScreen, chat)
        await chat.advance(by: .seconds(1))
        // A reattach leaves the attached state in the turn of the check.
        #expect(terminal.state.attached)
        #expect(chat.fakes.spawns.count == 4)
        let last = try #require(chat.fakes.fakes.last)
        terminal.terminalData(bytes("x"))
        #expect(last.written.isEmpty)
        last.emitExit(0)
        await waitUntil { terminal.state.ended }
        #expect(terminal.state.note == ChatTerminal.giveUpText)

        terminal.restart()
        await waitUntil { terminal.state.attached }
        #expect(terminal.state.note == nil)
        #expect(!terminal.state.blocked)
        #expect(!chat.screen().contains("[process ended"))
        try await show(agentScreen, chat)
        #expect(terminal.state.note == ChatTerminal.giveUpText)
        #expect(chat.fakes.spawns.count == 5)

        // After 60 seconds the history is empty, and the next agent view attaches again.
        try #require(chat.fakes.fakes.last).emitExit(0)
        await waitUntil { terminal.state.ended }
        await chat.advance(by: .seconds(60))
        terminal.restart()
        await waitUntil { chat.fakes.spawns.count == 6 && terminal.state.attached }
        try await show(agentScreen, chat)
        await waitUntil { chat.fakes.spawns.count == 7 }
        #expect(history(chat).count == 1)
        await chat.close()
    }

    // A narrow window wraps the counts line and the footer of the agent view into more than one
    // row. The check joins the wrapped rows, so it still finds the agent view.
    @Test func aWrappedAgentViewInANarrowWindowAttachesAgain() async throws {
        let chat = try ChatFixture(fakePTY: true)
        chat.open(at: rect(0, 0, 240, 400))
        let terminal = try chat.terminal()
        try #require(await waitUntil { terminal.state.attached })
        try #require(terminal.view.terminalDimensions.cols < 40)
        try await show(agentScreen, chat)
        await waitUntil { chat.fakes.spawns.count == 2 && terminal.state.attached }
        await chat.close()
    }

    // During continuous output (a spinner), the check comes 1 second after the first chunk.
    @Test func aCheckComesEachSecondDuringOutput() async throws {
        let chat = try ChatFixture(fakePTY: true)
        let (terminal, child) = try await attached(chat)
        let gate = TestGate()
        defer { gate.openAll() }
        chat.fakes.holdNext(gate)
        var fed = terminal.benchOutput
        child.emitData(agentScreen)
        for _ in 0..<9 {
            await waitUntil { terminal.benchOutput > fed }
            fed = terminal.benchOutput
            await chat.advance(by: .milliseconds(100))
            child.emitData("\u{1b}[H")
        }
        await waitUntil { terminal.benchOutput > fed }
        await chat.advance(by: .milliseconds(99))
        #expect(terminal.state.attached)
        #expect(!terminal.state.blocked)
        await chat.advance(by: .milliseconds(1))
        #expect(terminal.state.blocked)
        #expect(history(chat) == [.seconds(1)])
        await gate.waitUntilHolding()
        gate.open()
        await waitUntil { chat.fakes.spawns.count == 2 }
        await chat.close()
    }

    // While the row cannot attach, the agent view blocks the input and shows the reason. The
    // input starts again when the agent view closes. When the row can attach, the window checks
    // the screen at once.
    @Test func anAgentViewThatWaitsForTheRowShowsItsReason() async throws {
        let chat = try ChatFixture(fakePTY: true)
        let (terminal, first) = try await attached(chat)
        chat.rows = [FakeSession.row(folder: chat.home, state: .parked)]
        chat.sync()
        #expect(terminal.state.note == nil)
        try await show(agentScreen, chat)
        #expect(terminal.state.blocked)
        #expect(terminal.state.note == AttachRefusal.parked.message)
        #expect(history(chat).isEmpty)
        terminal.terminalData(bytes("a"))
        #expect(first.written.isEmpty)
        try await show(promptScreen, chat)
        #expect(!terminal.state.blocked)
        #expect(terminal.state.note == nil)

        try await show(agentScreen, chat)
        #expect(terminal.state.blocked)
        chat.rows = [FakeSession.row(folder: chat.home)]
        chat.sync()
        await waitUntil { chat.fakes.spawns.count == 2 }
        await waitUntil { terminal.state.attached && !terminal.state.blocked }
        await chat.close()
    }

    // The rows refuse the open of a reattach: the window ends, and its old attach closes.
    @Test func aRefusedReattachEndsTheWindowAndClosesTheOldAttach() async throws {
        let chat = try ChatFixture(fakePTY: true)
        let (terminal, first) = try await attached(chat)
        // A second row gets the short ID of the chat: the attach is not for one owned session.
        var twin = FakeSession.row(
            "0f0f0f0f-0000-4000-8000-00000000000f", folder: chat.home, kind: .external)
        twin.shortId = ShortID(FakeSession.shortId(FakeSession.first))
        chat.rows.append(twin)
        chat.sync()
        #expect(terminal.state.attached)
        try await show(agentScreen, chat)
        await waitUntil { terminal.state.ended }
        #expect(chat.screen().contains("[open failed: \(AttachRefusal.notOwnedAttach.message)]"))
        #expect(first.signals == [.hangup])
        #expect(chat.ptys.list().isEmpty)
        #expect(chat.fakes.spawns.count == 1)
        await chat.close()
    }

    // A window that is not focused reads the session size before it opens, and opens at it. A
    // close of the window (detachAll) during the read opens nothing.
    @Test func aWindowThatIsNotFocusedOpensAtTheSessionSize() async throws {
        let session = TerminalSize(cols: 250, rows: 60)
        let chat = try ChatFixture(size: session, rows: { _ in [] }, fakePTY: true)
        let read = TestGate()
        defer { read.openAll() }
        chat.sizes.holdNext(read)
        chat.open(at: rect(0, 0, 500, 300))
        let watchlist = chat.openPanel(panel("watchlist"), at: rect(600, 0, 300, 300))
        chat.rows = [FakeSession.row(folder: chat.home, pid: 4_000_000)]
        chat.sync()
        let closing = try chat.terminal()
        await read.waitUntilHolding()
        #expect(!closing.state.attached)
        #expect(closing.state.note == nil)
        // The close releases the task of the read, so the test keeps a copy of it.
        let sizeRead = try #require(closing.sizeRead)
        chat.chats.detachAll()
        read.open()
        // The read ends after the close: the device and the size were read.
        await waitUntil { chat.sizes.calls.count == 2 }
        // Wait for the end of the read task, then advance the clock: no fixed sleep.
        await sizeRead.value
        await chat.advance(by: .seconds(1))
        #expect(chat.fakes.spawns.isEmpty)
        #expect({ if case .closed = closing.attachState { true } else { false } }())

        chat.rows = []
        chat.sync()
        chat.model.apply(.close(chat.panel()))
        chat.open(at: rect(0, 0, 500, 300))
        chat.model.apply(.focus(watchlist))
        chat.rows = [FakeSession.row(folder: chat.home, pid: 4_000_000)]
        chat.sync()
        let terminal = try chat.terminal()
        await waitUntil { terminal.state.attached }
        #expect(chat.fakes.spawns.map(\.size) == [session])
        #expect(chat.sizes.calls.first == .terminalDevice(4_000_000))
        await chat.close()
    }

    // dispose() cancels the read of the session size that runs, and releases its task.
    @Test func aCloseCancelsTheReadOfTheSessionSize() async throws {
        let chat = try ChatFixture(
            size: TerminalSize(cols: 250, rows: 60), rows: { _ in [] }, fakePTY: true)
        let read = TestGate()
        defer { read.openAll() }
        chat.sizes.holdNext(read)
        chat.open(at: rect(0, 0, 500, 300))
        _ = chat.openPanel(panel("watchlist"), at: rect(600, 0, 300, 300))
        chat.rows = [FakeSession.row(folder: chat.home, pid: 4_000_000)]
        chat.sync()
        let closing = try chat.terminal()
        await read.waitUntilHolding()
        let sizeRead = try #require(closing.sizeRead)
        #expect(!sizeRead.isCancelled)
        closing.dispose()
        #expect(sizeRead.isCancelled)
        #expect(closing.sizeRead == nil)
        read.open()
        await sizeRead.value
        #expect(chat.fakes.spawns.isEmpty)
        await chat.close()
    }

    // The loader of Take control waits for the first text of an attach, or for the end line.
    @Test func theFirstTextOfEachAttachShowsOnce() async throws {
        let chat = try ChatFixture(fakePTY: true)
        let (terminal, child) = try await attached(chat)
        #expect(!terminal.isShowingText)
        let changes = Mutex(0)
        withObservationTracking {
            _ = terminal.isShowingText
        } onChange: {
            changes.withLock { $0 += 1 }
        }
        let fed = terminal.benchOutput
        child.emitData("\r\n   \r\n")
        await waitUntil { terminal.benchOutput > fed }
        #expect(!terminal.isShowingText)
        #expect(changes.withLock { $0 } == 0)
        child.emitData("hello")
        await waitUntil { terminal.isShowingText }
        #expect(changes.withLock { $0 } == 1)
        // A reattach is a new attach.
        try await show(agentScreen, chat)
        await waitUntil { chat.fakes.spawns.count == 2 && terminal.state.attached }
        #expect(!terminal.isShowingText)
        try #require(chat.fakes.fakes.last).emitExit(1)
        await waitUntil { terminal.state.ended }
        #expect(terminal.isShowingText)
        await chat.close()
    }
}
