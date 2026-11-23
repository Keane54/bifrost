// Take control with its open chat window (docs/behaviour/chat.md, "The Take control loader"): the
// action runner on the fake session commands (ActionsHarness), and the chats on the fake PTY in a
// window that is never ordered front (ChatFixture). The chats follow the rows of the registry, as
// the shell does. No test runs a program, attaches to a real session or signals a process.
import AppKit
import BifrostFoundation
import BifrostLayout
import BifrostSessions
import BifrostTestSupport
import Foundation
import Observation
import Testing

@testable import BifrostChat
@testable import BifrostWindows

@Suite("Take control and its chat", .serialized, .testTimeLimit, .tags(.window))
@MainActor
struct TakeControlChatTests {
    // The row of the session in the rows that the chats got last.
    private func row(_ chat: ChatFixture) -> SessionRow? {
        chat.rows.first { $0.sessionId == s3 }
    }

    // The open chat attaches to the session after the move, with no close and no new open. While
    // Take control runs, the row already reads as an owned session that runs. But the chat makes
    // no attach, because the move is not done until Take control checks that the new process
    // stays. After the good Take control, the chat attaches by itself. Its first output ends the
    // loader.
    @Test func theOpenChatAttachesToTheSessionAfterTakeControl() async throws {
        let temp = try transcripts(s3)
        defer { temp.remove() }
        let chat = try ChatFixture(rows: { _ in [] }, fakePTY: true)
        let h = try await ActionsHarness(
            active: [Entry.interactive(s3)], projects: temp.url, chats: chat.chats,
            layout: chat.model)
        let registry = h.deps.registry
        let follow = Task {
            for await rows in Observations({ registry.rows }) {
                chat.rows = rows
                chat.sync()
            }
        }
        defer { follow.cancel() }
        chat.open(s3)
        await waitUntil { row(chat)?.kind == .external }
        let terminal = try chat.terminal(s3)
        #expect(terminal.state.note == AttachRefusal.external.message)
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
        #expect(chat.chats.showsLoader(s3))
        await h.deps.show([Entry.running(s3, pid: 6161)])
        await waitUntil { row(chat)?.kind == .owned && row(chat)?.pid == 6161 }
        // The row can attach now, but Take control still runs: the window waits.
        #expect(row(chat)?.shortId == ShortID("1c2d3e4f"))
        #expect({ if case .waiting = terminal.attachState { true } else { false } }())
        #expect(chat.fakes.spawns.isEmpty)
        #expect(chat.chats.showsLoader(s3))
        await h.clock.waitForSleepers(5)
        h.clock.advance(by: SessionActions.resumeSettle)
        await h.settle()
        #expect(h.runner.error == nil)
        // The good Take control: the same window attaches to the moved session.
        #expect(chat.chats.terminal(s3) === terminal)
        try #require(await chat.waitForAttach(s3))
        #expect(chat.fakes.spawns.map(\.arguments) == [["attach", "1c2d3e4f"]])
        await waitUntil { !chat.chats.showsLoader(s3) }
        #expect(terminal.isShowingText)
        #expect(chat.screen(s3).contains("FAKE ATTACH 1c2d3e4f"))
        await chat.close()
    }
}
