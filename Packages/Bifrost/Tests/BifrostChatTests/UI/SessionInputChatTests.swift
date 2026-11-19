// The session input with the chat terminals: the terminal model of a hidden
// attach, and the wiring of the chats. The tests use real PTYs with the
// fake attach of scripts/fake-claude and a fake size runner (FakeAttach.swift). No test runs the
// real claude or attaches to a real session. The window is never ordered front.
import AppKit
import BifrostSessions
import BifrostTestSupport
import BifrostWindows
import Foundation
import SwiftTerm
import Testing

@testable import BifrostChat
@testable import BifrostLayout
@testable import BifrostLook

@Suite("hidden terminal model", .testTimeLimit, .tags(.realProcess, .window))
@MainActor
struct HiddenTerminalModelTests {
    // A cursor position request (CSI 6 n) gets the report of the cursor (CSI row ; col R). The
    // report goes to the PTY, as the report of a chat terminal does.
    @Test func aHiddenTerminalAnswersACursorPositionRequest() {
        let terminal = HiddenTerminalModel(size: TerminalSize(cols: 97, rows: 41))
        #expect(terminal.feed(Array("\u{1b}[5;10H\u{1b}[6n".utf8)) == Array("\u{1b}[5;10R".utf8))
        // Output with no request gives no reply, and the replies of one feed come one time.
        #expect(terminal.feed(Array("hello\r\n".utf8)).isEmpty)
        // The model has the size of the session: the cursor stops at the last row and column.
        let corner = terminal.feed(Array("\u{1b}[999;999H\u{1b}[6n".utf8))
        #expect(corner == Array("\u{1b}[41;97R".utf8))
    }

    // A colour query (OSC 10 and OSC 11) gets the foreground and the background of a chat
    // terminal, as SwiftTerm gives them for the colours of the chat view. The background of the
    // theme is black, as the default of SwiftTerm, but the foreground is not the default.
    @Test func aColourQueryGetsTheColoursOfAChatTerminal() {
        let terminal = HiddenTerminalModel(size: TerminalSize(cols: 80, rows: 24))
        func reply(_ query: String) -> String {
            String(decoding: terminal.feed(Array(query.utf8)), as: UTF8.self)
        }
        func rgb(_ colour: Color) -> String {
            String(format: "rgb:%04x/%04x/%04x", colour.red, colour.green, colour.blue)
        }
        let foreground = reply("\u{1b}]10;?\u{07}")
        let background = reply("\u{1b}]11;?\u{07}")
        #expect(foreground.hasPrefix("\u{1b}]10;"))
        #expect(foreground.contains(rgb(Color(nsColor: ThemeTokens.text.nsColor))))
        #expect(background.hasPrefix("\u{1b}]11;"))
        #expect(background.contains(rgb(Color(nsColor: ThemeTokens.terminalBackground.nsColor))))
    }
}

extension HiddenTerminalModelTests {
    // The hidden terminal gives no answer to the query of the
    // kitty keyboard protocol. So
    // Claude Code keeps the legacy key form, and the raw ESC of an Interrupt is the Escape key.
    // The other replies of the same chunk still come.
    @Test func aHiddenTerminalGivesNoAnswerToTheKittyKeyboardQuery() {
        let terminal = HiddenTerminalModel(size: TerminalSize(cols: 80, rows: 24))
        #expect(terminal.feed(Array("\u{1b}[?u".utf8)).isEmpty)
        // A program that turns the protocol on asks again: still no answer.
        #expect(terminal.feed(Array("\u{1b}[>1u\u{1b}[?u".utf8)).isEmpty)
        let both = terminal.feed(Array("\u{1b}[?u\u{1b}[3;4H\u{1b}[6n".utf8))
        #expect(both == Array("\u{1b}[3;4R".utf8))
        // A plain SwiftTerm terminal, as the one of a chat window, answers the query (chat row
        // C17): the model drops that answer.
        let record = ReplyRecord()
        let plain = Terminal(delegate: record)
        plain.feed(byteArray: Array("\u{1b}[?u".utf8))
        #expect(record.bytes == Array("\u{1b}[?0u".utf8))
    }
}

// A delegate of a SwiftTerm terminal that keeps each reply.
@MainActor
private final class ReplyRecord: TerminalDelegate {
    var bytes: [UInt8] = []

    func send(source: Terminal, data: ArraySlice<UInt8>) {
        bytes += data
    }
}

// The chats of a ChatFixture with a session input on its PTY manager, as the shell wires them.
@MainActor
private func withInput(_ chat: ChatFixture) -> SessionInput {
    let input = SessionInput(
        ptys: chat.ptys, sizes: SessionSizeReader(inspector: chat.sizes),
        rows: { [weak chat] in chat?.rows ?? [] },
        makeTerminal: { HiddenTerminalModel(size: $0) }, clock: ContinuousClock())
    chat.chats.attach(ptys: chat.ptys, input: input)
    return input
}

// The reason of a refused Interrupt of the fake session, or nil.
@MainActor
private func interruptReason(_ input: SessionInput) async -> String? {
    do throws(InputRefusal) {
        try await input.interrupt(FakeSession.first)
        return nil
    } catch {
        return error.message
    }
}

// The reason of a refused send to the fake session, or nil.
@MainActor
private func sendReason(_ input: SessionInput, _ text: String) async -> String? {
    do throws(InputRefusal) {
        try await input.send(FakeSession.first, text)
        return nil
    } catch {
        return error.message
    }
}

// The reason of the agent view (InputRefusal.agentView of the session input).
@MainActor
private let agentViewReason =
    "The chat window shows the agent view. Close the window and open it again."

@Suite(
    "session input and chats", .serialized, .testTimeLimit, .tags(.realProcess, .window))
@MainActor
struct SessionInputChatTests {
    // An Interrupt of a session with a chat window writes one ESC into the attach of the chat:
    // the chat told the session input its attach. No hidden attach opens.
    @Test func anInterruptOfAChatSessionGoesThroughTheAttachOfTheChat() async throws {
        let chat = try ChatFixture()
        let input = withInput(chat)
        chat.open()
        try #require(await chat.waitForAttach())
        #expect(await interruptReason(input) == nil)
        await waitUntil { chat.input().contains(0x1b) }
        #expect(chat.input().filter { $0 == 0x1b }.count == 1)
        #expect(chat.spawner.log.pids.count == 1)
        #expect(chat.attachLines.count == 1)
        await chat.close()
    }

    // One attach serves each session: a chat that opens while an Interrupt runs through a
    // hidden attach waits until the hidden attach closed (SIGHUP to its child), then attaches.
    @Test func aChatOpenWaitsUntilTheHiddenAttachOfItsSessionClosed() async throws {
        let size = TerminalSize(cols: 97, rows: 41)
        let chat = try ChatFixture(size: size) { home in
            [FakeSession.row(folder: home, pid: 4242)]
        }
        let input = withInput(chat)
        let interrupting = Task { await interruptReason(input) }
        await waitUntil { chat.spawner.log.pids.count == 1 }
        let hidden = try #require(chat.spawner.log.pids.first)
        chat.open()
        let reason = await interrupting.value
        #expect(reason == nil, "The Interrupt was refused: \(reason ?? "")")
        try #require(await chat.waitForAttach())
        let events = Array(chat.spawner.log.events.prefix(3))
        #expect(events.count == 3)
        #expect(events.first == .spawn(size))
        #expect(events.dropFirst().first == .signal(hidden, .hangup))
        if case .spawn = events.last {} else {
            Issue.record("no chat spawn after the close: \(events)")
        }
        // The ESC of the Interrupt went through the hidden attach.
        #expect(chat.input().filter { $0 == 0x1b }.count == 1)
        await chat.close()
    }

    // An Interrupt during the spawn of the attach of a chat waits until the open
    // ends, then goes through the attach of the chat. No hidden attach opens beside it (it could
    // resize the session that the chat shows).
    @Test func anInterruptDuringTheSpawnOfAChatGoesThroughTheChat() async throws {
        let size = TerminalSize(cols: 97, rows: 41)
        let chat = try ChatFixture(size: size) { home in
            [FakeSession.row(folder: home, pid: 4242)]
        }
        let input = withInput(chat)
        let gate = TestGate()
        defer { gate.openAll() }
        chat.spawner.holdNext(gate)
        chat.open()
        await gate.waitUntilHolding()
        let interrupting = Task { await interruptReason(input) }
        gate.open()
        #expect(await interrupting.value == nil)
        try #require(await chat.waitForAttach())
        #expect(chat.spawner.log.opens.count == 1)
        await waitUntil { chat.input().contains(0x1b) }
        #expect(chat.input().filter { $0 == 0x1b }.count == 1)
        #expect(chat.attachLines.count == 1)
        await chat.close()
    }

    // A chat that closes during the spawn of its attach ends its open with no
    // attach. That frees the session input: an Interrupt then goes through a hidden attach.
    @Test func aChatThatClosesDuringItsSpawnFreesTheSessionInput() async throws {
        let size = TerminalSize(cols: 97, rows: 41)
        let chat = try ChatFixture(size: size) { home in
            [FakeSession.row(folder: home, pid: 4242)]
        }
        let input = withInput(chat)
        let gate = TestGate()
        defer { gate.openAll() }
        chat.spawner.holdNext(gate)
        chat.open()
        await gate.waitUntilHolding()
        chat.chats.sync(layout: WindowLayout(bounds: LayoutSize(w: 1200, h: 800)), loaded: true)
        gate.open()
        await waitUntil { chat.spawner.log.signals.count == 1 }
        var reason: String?? = .none
        Task { reason = .some(await interruptReason(input)) }
        await waitUntil { reason != nil }
        #expect(reason == .some(nil))
        // The spawn of the chat, then the hidden attach at the session size.
        #expect(chat.spawner.log.opens.count == 2)
        #expect(chat.spawner.log.opens.last == size)
        await waitUntil { chat.input().contains(0x1b) }
        await chat.close()
    }

    // A left arrow key in a chat can open the agent view, so a send to the chat waits 2 s after
    // it. The paste then comes after the key.
    @Test(.tags(.timing)) func aSendToAChatWaitsAfterALeftArrowKey() async throws {
        let chat = try ChatFixture()
        let input = withInput(chat)
        chat.open()
        try #require(await chat.waitForAttach())
        let terminal = try chat.terminal()
        #expect(chat.window.makeFirstResponder(terminal.view))
        chat.key("ArrowLeft")
        let keyAt = ContinuousClock.now
        await waitUntil { SessionInput.hasLeftKey(chat.input()) }
        #expect(await sendReason(input, "hi") == nil)
        #expect(ContinuousClock.now - keyAt >= .milliseconds(2000))
        let paste = bytes("\u{1b}[200~hi\u{1b}[201~\r")
        await waitUntil { contains(chat.input(), paste) }
        await chat.close()
    }

    // A chat that shows the agent view blocks the input: the session input then refuses a send
    // to the chat with the reason of the agent view.
    @Test func aSendToAChatThatShowsTheAgentViewIsRefused() async throws {
        let chat = try ChatFixture()
        let input = withInput(chat)
        try chat.writeScreen(
            "\u{1b}[2J\u{1b}[H0 awaiting input · 0 working · 6 completed\r\n\r\n  session one\r\n"
                + "enter to return · space to reply · hold space to speak · ? for shortcuts\r\n")
        chat.open()
        try #require(await chat.waitForAttach())
        let terminal = try chat.terminal()
        await waitUntil {
                terminal.state.note == ChatTerminal.giveUpText
            }
        #expect(terminal.state.blocked)
        #expect(await sendReason(input, "hi") == agentViewReason)
        #expect(chat.input().isEmpty)
        await chat.close()
    }
}
