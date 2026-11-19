// The chats of a bench run. The runner writes Ctrl+C and
// Return into the PTY of a chat. Before the fake claude runs "stty raw", the terminal still
// has ISIG, so a Ctrl+C is a SIGINT and the fake ends. The fake prints its first output only
// after "stty raw". So a chat is ready for the input of the bench after its attach and its first
// output. At the end of each phase, each chat must still be attached and not ended.
//
// Safety: the test uses the fake attach of scripts/fake-claude in a test home, on a real PTY. The
// window is never ordered front.
import BifrostSessions
import BifrostTestSupport
import Foundation
import Testing

@testable import BifrostApp
@testable import BifrostChat

@Suite("bench chats", .serialized, .timeLimit(.minutes(2)), .tags(.realProcess, .window))
@MainActor
struct BenchChatTests {
    // A chat is ready after its attach and its first output. Then a Ctrl+C is a byte of the
    // input of the fake (the input log has it), and the chat stays attached.
    @Test func aChatGetsTheKeysOfTheBenchOnlyAfterItsFirstOutput() async throws {
        let chat = try ChatFixture()
        chat.open()
        let terminal = try chat.terminal()
        #expect(!BenchRunner.isReady(terminal.state, output: terminal.benchOutput))
        await waitUntil { BenchRunner.isReady(terminal.state, output: terminal.benchOutput) }
        #expect(terminal.benchOutput > 0)
        #expect(chat.ptys.attach(FakeSession.chatView())?.write([0x03]) == true)
        await waitUntil { chat.input().contains(0x03) }
        // A later byte is the marker: the attach still takes input after the Ctrl+C.
        #expect(chat.ptys.attach(FakeSession.chatView())?.write([0x61]) == true)
        await waitUntil { chat.input().last == 0x61 }
        #expect(terminal.state.attached)
        #expect(!terminal.state.ended)
        #expect(BenchRunner.lostChat([(FakeSession.first, terminal.state)], phase: .quiet) == nil)
        await chat.close()
    }

    // The rules of the readiness and of the check at the end of a phase.
    @Test func aChatThatEndedOrDetachedFailsTheRun() {
        let attached = ChatTerminalState(
            attached: true, ended: false, blocked: false, note: nil, metal: true)
        var ended = attached
        ended.ended = true
        var detached = attached
        detached.attached = false
        #expect(BenchRunner.isReady(attached, output: 1))
        #expect(!BenchRunner.isReady(attached, output: 0))
        #expect(!BenchRunner.isReady(detached, output: 10))
        #expect(!BenchRunner.isReady(ended, output: 10))
        #expect(!BenchRunner.isReady(nil, output: 10))
        #expect(BenchRunner.lostChat([("a", attached), ("b", attached)], phase: .drag) == nil)
        let lost = BenchRunner.lostChat(
            [("a", attached), ("b", ended), ("c", detached)], phase: .drag)
        #expect(lost == "Chat 2 of 3 ended in the phase drag.")
        #expect(
            BenchRunner.lostChat([("a", detached)], phase: .stream)
                == "Chat 1 of 1 is not attached at the end of the phase stream.")
        #expect(
            BenchRunner.lostChat([("a", nil)], phase: .idle)
                == "Chat 1 of 1 has no terminal at the end of the phase idle.")
    }

    // A failed check of the display or of the window gives no result. Another failure is a
    // failure of the harness. The state of the test port shows which.
    @Test func aFailedDisplayCheckIsACheckFailure() {
        #expect(BenchRunner.displayFailure([]).check)
        #expect(BenchRunner.displayFailure([]).reason == "The window got 1 display frames in 2 s.")
        let slow = BenchRunner.displayFailure(Array(repeating: 1.0 / 60, count: 100))
        #expect(slow.check)
        #expect(slow.reason == "The display period is 16.67 ms, not 8.33 ms within 2 %.")
        #expect(BenchRunner.lostChat([("a", nil)], phase: .idle) != nil)
        #expect(!BenchFailure("Some chats did not attach.").check)
        #expect(BenchFailure(check: "The screen is off.").check)
    }
}
