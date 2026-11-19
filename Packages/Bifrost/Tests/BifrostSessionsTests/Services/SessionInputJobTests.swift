// The jobs of the session input (docs/behaviour/input.md), with the fake spawner of the PTY
// tests, a fake size read and a manual clock. No program starts. The clock moves only when a
// test moves it. A test moves it only to the time of the next event, after the jobs sleep, so
// each sleep wakes at its own time.
import BifrostTestSupport
import Darwin
import Synchronization
import BifrostFoundation
import Testing

@testable import BifrostSessions

private let owner: SessionID = "f3a9c2d1-4b5e-4c6d-8e7f-0a1b2c3d4e5f"
private let S = owner.text
private let otherId = "0b1c2d3e-4f50-4a6b-8c7d-9e0f1a2b3c4d"
private let jobShortId: ShortID = "abcd1234"
private let termSize = TerminalSize(cols: 97, rows: 41)
private let chatView = PTYView.chat(owner)
private let pasted = "\u{1b}[200~Reply with OK\u{1b}[201~"
private let cr = "\r"
private let esc = "\u{1b}"
private let redBox = InputRefusal.prompt

private func row(_ change: (inout SessionRow) -> Void = { _ in }) -> SessionRow {
    var r = SessionRow.test(sessionId: S, shortId: jobShortId, name: "bifrost-test-s", pid: 4242)
    change(&r)
    return r
}

private func redPrompt(_ r: inout SessionRow) {
    r.alert = .red(.prompt, since: 1)
    r.state = .needsYou
}

// The terminal model of a hidden attach. It keeps each chunk. With replies, it answers "R".
@MainActor
private final class FakeModel: HiddenTerminal {
    let size: TerminalSize
    let replies: Bool
    private(set) var fed = 0

    init(size: TerminalSize, replies: Bool) {
        self.size = size
        self.replies = replies
    }

    func feed(_ bytes: [UInt8]) -> [UInt8] {
        fed += 1
        return replies ? Array("R".utf8) : []
    }
}

// The end of a job: the refusal or nil, and the time of the end since the base.
@MainActor
private final class Outcome {
    var at: Int?
    var refusal: InputRefusal?
    var done: Bool { at != nil }
}

// The session input with its fakes.
@MainActor
private final class Rig {
    let clock = ManualClock()
    let spawner = FakeSpawner()
    let sizes = FakeProcessInspector(size: termSize)
    let ptys: PTYManager
    let replies: Bool
    var rows = [row()]
    // The times of the tests count from the base.
    var base = 0
    private(set) var models: [FakeModel] = []
    let log = Recorder<SessionsLogEvent>()
    // The attach of the chat window, after openChat.
    private(set) var chat: PTYAttach?

    private(set) lazy var input = SessionInput(
        ptys: ptys, sizes: SessionSizeReader(inspector: sizes), rows: { [unowned self] in rows },
        makeTerminal: { [unowned self] size in
            let model = FakeModel(size: size, replies: replies)
            models.append(model)
            return model
        }, clock: clock, log: log)

    init(replies: Bool = false) {
        self.replies = replies
        let claude = ClaudeRunner(path: "/bin/claude", baseEnvironment: [:], runner: NoRunner())
        ptys = PTYManager(claude: claude, spawner: spawner)
    }

    var now: Int { Int(clock.now.offset / .milliseconds(1)) - base }

    // Move the clock to the time, when at least the number of sleeps wait on the clock. A test
    // then waits for the effect of the woken job (wrote, ended).
    func at(_ time: Int, sleepers: Int = 1) async {
        await clock.waitForSleepers(sleepers)
        clock.advance(by: .milliseconds(time - now))
    }

    func send(_ text: String = "Reply with OK", to session: String = S) -> Outcome {
        run { input throws(InputRefusal) in try await input.send(session, text) }
    }

    func interrupt(_ session: String = S) -> Outcome {
        run { input throws(InputRefusal) in try await input.interrupt(session) }
    }

    private func run(_ job: @escaping (SessionInput) async throws(InputRefusal) -> Void)
        -> Outcome
    {
        let outcome = Outcome()
        let input = self.input
        Task {
            do throws(InputRefusal) {
                try await job(input)
            } catch {
                outcome.refusal = error
            }
            outcome.at = now
        }
        return outcome
    }

    // Wait until the job ended.
    func ended(_ outcome: Outcome) async -> Bool {
        await waitUntil { outcome.done }
    }

    // The child of a spawn: 0 is the first spawn.
    func child(_ index: Int) async throws -> FakeChild {
        await waitUntil { spawner.fakes.count > index }
        return try #require(spawner.fakes.dropFirst(index).first)
    }

    func writes(_ child: FakeChild) -> [String] {
        child.written.map { String(decoding: $0, as: UTF8.self) }
    }

    // Wait until the child got these writes.
    func wrote(_ child: FakeChild, _ texts: [String]) async -> Bool {
        await waitUntil { writes(child) == texts }
    }

    // Give a chunk to the child of a hidden attach, and wait until the session input read it.
    func output(_ child: FakeChild) async {
        let fed = models.reduce(0) { $0 + $1.fed }
        child.emitData("x")
        await waitUntil { models.reduce(0) { $0 + $1.fed } > fed }
    }

    // Give the exit to the child of the hidden attach, and wait until its attach got it. The
    // exit goes to the attach in a later job of the main actor. A test that moves the clock
    // before that job can wake a sleep of the send first, and the send then writes to the attach.
    // After this wait, the attach refuses each write.
    func end(_ child: FakeChild) async {
        child.emitExit(0)
        await waitUntil { ptys.list().isEmpty }
    }

    // Open the attach of the chat window as the chat does: chatOpening, the open, opened.
    @discardableResult
    func openChat(shortId: ShortID = jobShortId) async throws -> FakeChild {
        await input.chatOpening(chat: owner)
        chat = try await ptys.open(.test(chatView, shortId: shortId), size: termSize)
        try #require(chat != nil)
        input.opened(chat: owner, shortId: shortId)
        return try #require(spawner.fakes.last)
    }

    // A chat with one chunk of output, 1.5 s ago: its output is quiet. The base is now.
    func quietChat() async throws -> FakeChild {
        let child = try await openChat()
        input.output(chat: owner)
        clock.advance(by: .milliseconds(1500))
        base += 1500
        return child
    }
}

@Suite("the texts of the session input", .testTimeLimit)
struct SessionInputTextTests {
    // The texts name the connection to the session, never the attach.
    @Test func theRefusalTextsNameTheConnectionAndNotTheAttach() {
        #expect(
            InputRefusal.endedBeforeReady.message
                == "The connection to the session ended before it was ready. Bifrost sent nothing.")
        #expect(
            InputRefusal.attachGone.message
                == "The connection to the session ended during the send.")
        #expect(
            InputRefusal.notReady.message
                == "The session did not get ready in 15 seconds. Bifrost sent nothing.")
        #expect(InputRefusal.chatGone.message == "The chat window closed during the send.")
        #expect(
            InputRefusal.agentView.message
                == "The chat window shows the agent view. Close the window and open it again.")
        let texts: [InputRefusal] = [
            .agentView, .attachGone, .chatGone, .endedBeforeReady, .noSize, .notReady, .oldAttach,
        ]
        for text in texts { #expect(!text.message.lowercased().contains("attach"), "\(text)") }
    }

    @Test func aLeftArrowKeyIsFoundInBothKeyModes() {
        #expect(SessionInput.hasLeftKey(Array("\u{1b}[D".utf8)))
        #expect(SessionInput.hasLeftKey(Array("ab\u{1b}ODc".utf8)))
        #expect(!SessionInput.hasLeftKey(Array("\u{1b}[C".utf8)))
        #expect(!SessionInput.hasLeftKey(Array("D".utf8)))
    }
}

@Suite("the sends of the session input", .testTimeLimit)
@MainActor
struct SessionInputSendTests {
    // The paste goes at once, and the cr 300 ms later. No hidden attach opens, and the chat
    // attach stays open.
    @Test func aSendTypesThePasteAndTheCRIntoTheChatAttach() async throws {
        let rig = Rig()
        let chat = try await rig.quietChat()
        let sent = rig.send()
        #expect(await rig.wrote(chat, [pasted]))
        await rig.at(299)
        #expect(rig.writes(chat) == [pasted])
        await rig.at(300)
        #expect(await rig.ended(sent))
        #expect(sent.refusal == nil)
        #expect(sent.at == 300)
        #expect(rig.writes(chat) == [pasted, cr])
        #expect(rig.spawner.spawns.count == 1)
        #expect(chat.signals.isEmpty)
    }

    // With no chat, the send opens "claude attach <short id>" in the root folder at the size of
    // the session. The attach is ready when its output was quiet for 1.5 s. It closes 1 s after
    // the cr, with SIGHUP to the attach child only.
    @Test func aSendWithNoChatTypesThroughAHiddenAttachAtTheSessionSize() async throws {
        let rig = Rig()
        let sent = rig.send()
        let child = try await rig.child(0)
        let spawn = try #require(rig.spawner.spawns.first)
        #expect(spawn.arguments == ["attach", jobShortId.text])
        #expect(spawn.directory == "/")
        #expect(spawn.size == termSize)
        #expect(rig.sizes.reads == [4242])
        await rig.output(child)
        #expect(rig.models.map(\.size) == [termSize])
        await rig.at(300)
        await rig.output(child)
        await rig.at(1799)
        #expect(rig.writes(child).isEmpty)
        await rig.at(1800)
        #expect(await rig.wrote(child, [pasted]))
        await rig.at(2100)
        #expect(await rig.wrote(child, [pasted, cr]))
        await rig.at(3099)
        #expect(!sent.done)
        #expect(child.signals.isEmpty)
        await rig.at(3100)
        #expect(await rig.ended(sent))
        #expect(sent.refusal == nil)
        #expect(sent.at == 3100)
        #expect(child.signals == [.hangup])
        #expect(rig.ptys.list().isEmpty)
        #expect(rig.log.values.isEmpty)
    }

    // A busy session never gets quiet. After 15 s the send ends, wrote nothing, and closed the
    // attach.
    @Test func aHiddenAttachThatNeverGetsQuietGetsNothingAfter15Seconds() async throws {
        let rig = Rig()
        let sent = rig.send()
        let child = try await rig.child(0)
        await rig.output(child)
        for time in stride(from: 500, through: 14_500, by: 500) {
            await rig.at(time)
            await rig.output(child)
        }
        await rig.at(14_999)
        #expect(!sent.done)
        await rig.at(15_000)
        #expect(await rig.ended(sent))
        #expect(sent.refusal == .notReady)
        #expect(sent.at == 15_000)
        #expect(rig.writes(child).isEmpty)
        #expect(child.signals == [.hangup])
    }

    // An end of the hidden attach before it is ready ends the send at once. An end between the
    // paste and the cr ends it at the check before the cr, and the cr does not go.
    @Test func anEndOfTheHiddenAttachEndsTheSend() async throws {
        let early = Rig()
        let first = early.send()
        let child = try await early.child(0)
        await early.output(child)
        await early.at(500)
        child.emitExit(0)
        #expect(await early.ended(first))
        #expect(first.refusal == .endedBeforeReady)
        #expect(first.at == 500)
        #expect(early.writes(child).isEmpty)
        #expect(early.ptys.list().isEmpty)

        let late = Rig()
        let second = late.send()
        let other = try await late.child(0)
        await late.output(other)
        await late.at(1500)
        #expect(await late.wrote(other, [pasted]))
        await late.at(1600)
        await late.end(other)
        await late.at(1800)
        #expect(await late.ended(second))
        #expect(second.refusal == .attachGone)
        #expect(second.at == 1800)
        #expect(late.writes(other) == [pasted])
    }

    // A failed spawn ends the send, and the error text goes to the log.
    @Test func aFailedSpawnEndsTheSendAndLogsTheError() async throws {
        let rig = Rig()
        rig.spawner.failNext(PTYError(message: "The spawn failed."))
        let sent = rig.send()
        #expect(await rig.ended(sent))
        #expect(sent.refusal == .endedBeforeReady)
        #expect(rig.log.values == [.hiddenAttachFailed(message: "The spawn failed.")])
        #expect(rig.ptys.list().isEmpty)
    }

    // A failed size read and a size that a PTY refuses give no size, and no attach opens.
    @Test func aSendWithNoValidSessionSizeOpensNothing() async throws {
        let rig = Rig()
        for size in [nil, TerminalSize(cols: 1001, rows: 40)] {
            rig.sizes.answer(size)
            let sent = rig.send()
            #expect(await rig.ended(sent))
            #expect(sent.refusal == .noSize)
        }
        #expect(rig.spawner.spawns.isEmpty)
    }

    // Input goes only to an owned session that runs, with a short ID that "claude attach"
    // accepts. The hidden path also needs the process ID.
    @Test func aSendIsRefusedForARowThatIsNotAnOwnedSessionThatRuns() async throws {
        let rig = Rig()
        let cases: [[SessionRow]] = [
            [row { $0.kind = .external }],
            [
                row {
                    $0.pid = nil
                    $0.state = .parked
                }
            ],
            [row { $0.sessionId = otherId }],
            [],
            [row { $0.shortId = nil }],
            [row(), row { $0.sessionId = otherId }],
        ]
        for rows in cases {
            rig.rows = rows
            let sent = rig.send()
            #expect(await rig.ended(sent))
            #expect(sent.refusal == .notOwned, "\(rows)")
        }
        rig.rows = [row { $0.pid = nil }]
        let noPid = rig.send()
        #expect(await rig.ended(noPid))
        #expect(noPid.refusal == .noPid)
        let empty = rig.send(" \u{1b} ")
        #expect(await rig.ended(empty))
        #expect(empty.refusal == .empty)
        #expect(rig.sizes.reads.isEmpty)
        #expect(rig.spawner.spawns.isEmpty)
    }

    // A red box of a prompt blocks a send before the size read. A yellow box and an error box
    // do not block. A red box with no known reason blocks.
    @Test func onlyARedBoxThatCanBeAPromptBlocksASend() async throws {
        let rig = Rig()
        rig.rows = [row(redPrompt)]
        let hidden = rig.send()
        #expect(await rig.ended(hidden))
        #expect(hidden.refusal == redBox)
        #expect(rig.sizes.reads.isEmpty)
        rig.rows = [row()]
        let chat = try await rig.quietChat()
        for reason in [SessionBoxReason.escalated, .error] {
            rig.rows = [
                row { $0.alert = .red(reason, since: 1) }
            ]
            let sent = rig.send()
            await rig.at(rig.now + 300)
            #expect(await rig.ended(sent))
            #expect(sent.refusal == nil)
        }
        for change in [redPrompt] as [(inout SessionRow) -> Void] {
            rig.rows = [row(change)]
            let sent = rig.send()
            #expect(await rig.ended(sent))
            #expect(sent.refusal == redBox)
        }
        #expect(rig.writes(chat) == [pasted, cr, pasted, cr])
    }

    // The rows can change during the wait. The send checks them again before its first write:
    // it writes nothing, and the attach closes.
    @Test func aSendChecksTheRowAgainBeforeItsFirstWrite() async throws {
        let changes: [((inout SessionRow) -> Void, InputRefusal)] = [
            (redPrompt, redBox),
            (
                {
                    $0.pid = nil
                    $0.state = .parked
                }, .notOwned
            ),
        ]
        for (change, refusal) in changes {
            let rig = Rig()
            let sent = rig.send()
            let child = try await rig.child(0)
            await rig.output(child)
            await rig.at(1000)
            rig.rows = [row(change)]
            await rig.at(1500)
            #expect(await rig.ended(sent))
            #expect(sent.refusal == refusal)
            #expect(sent.at == 1500)
            #expect(rig.writes(child).isEmpty)
            #expect(child.signals == [.hangup])
        }
    }

    // Live state is a hint, not an authority: a session that the session list shows as waiting
    // on a prompt blocks a send also when a line of the mod cleared its box.
    @Test func aSessionThatTheListShowsWaitingOnAPromptBlocksASend() async throws {
        let rig = Rig()
        rig.rows = [
            row {
                $0.status = .waiting
                $0.waitingFor = "permission"
                $0.state = .idle
                $0.alert = .none
            }
        ]
        let hidden = rig.send()
        #expect(await rig.ended(hidden))
        #expect(hidden.refusal == redBox)
        #expect(rig.sizes.reads.isEmpty)
    }

    // A prompt that opens after the paste stops the cr, so the cr cannot answer the prompt.
    @Test func aPromptAfterThePasteStopsTheCR() async throws {
        let rig = Rig()
        let chat = try await rig.quietChat()
        let sent = rig.send()
        #expect(await rig.wrote(chat, [pasted]))
        await rig.at(100)
        rig.rows = [row(redPrompt)]
        await rig.at(300)
        #expect(await rig.ended(sent))
        #expect(sent.refusal == redBox)
        #expect(sent.at == 300)
        #expect(rig.writes(chat) == [pasted])
        #expect(chat.signals.isEmpty)
    }

    // A chat that shows the agent view refuses a send. Only a chat view of a session ID of a
    // chat panel can block, and a new attach of the chat clears the block.
    @Test func aChatThatShowsTheAgentViewRefusesASend() async throws {
        let rig = Rig()
        let chat = try await rig.quietChat()
        rig.input.setBlocked(chat: owner, true)
        let blocked = rig.send()
        #expect(await rig.ended(blocked))
        #expect(blocked.refusal == .agentView)
        rig.input.setBlocked(chat: owner, false)
        let sent = rig.send()
        await rig.at(300)
        #expect(await rig.ended(sent))
        #expect(sent.refusal == nil)
        rig.input.setBlocked(chat: owner, true)
        rig.input.opened(chat: owner, shortId: jobShortId)
        rig.input.output(chat: owner)
        let again = rig.send()
        await rig.at(1800)
        #expect(await rig.wrote(chat, [pasted, cr, pasted]))
        await rig.at(2100)
        #expect(await rig.ended(again))
        #expect(again.refusal == nil)
    }

    // A new chat attach is ready when its output was quiet for 1.5 s, not before its output.
    @Test func aSendWaitsForTheQuietOutputOfANewChat() async throws {
        let rig = Rig()
        let chat = try await rig.openChat()
        let sent = rig.send()
        await rig.at(200)
        rig.input.output(chat: owner)
        await rig.at(1699)
        #expect(rig.writes(chat).isEmpty)
        await rig.at(1700)
        #expect(await rig.wrote(chat, [pasted]))
        await rig.at(2000)
        #expect(await rig.ended(sent))
        #expect(sent.at == 2000)
        #expect(rig.writes(chat) == [pasted, cr])
    }

    // A chat that closes during the send ends it: at once while it waits for quiet output, and
    // at the failed write of the cr.
    @Test func aChatThatClosesDuringASendEndsIt() async throws {
        let waiting = Rig()
        try await waiting.openChat()
        let first = waiting.send()
        await waiting.at(200)
        waiting.input.ended(chat: owner)
        #expect(await waiting.ended(first))
        #expect(first.refusal == .chatGone)
        #expect(first.at == 200)

        let writing = Rig()
        let chat = try await writing.quietChat()
        let second = writing.send()
        #expect(await writing.wrote(chat, [pasted]))
        await writing.at(100)
        writing.chat?.close()
        await writing.at(300)
        #expect(await writing.ended(second))
        #expect(second.refusal == .chatGone)
        #expect(writing.writes(chat) == [pasted])
    }

    // The chat must show the attach of the short ID of the row, and it must have told the
    // session input its attach.
    @Test func aChatOfAnOldShortIdOrThatGaveNoOpenRefusesASend() async throws {
        let old = Rig()
        let chat = try await old.quietChat()
        old.rows = [row { $0.shortId = "ffff0000" }]
        let sent = old.send()
        #expect(await old.ended(sent))
        #expect(sent.refusal == .oldAttach)
        #expect(old.writes(chat).isEmpty)

        let untold = Rig()
        _ = try await untold.ptys.open(.test(chatView, shortId: jobShortId), size: termSize)
        let other = untold.send()
        #expect(await untold.ended(other))
        #expect(other.refusal == .chatGone)
        #expect(untold.spawner.spawns.count == 1)
    }

    // The jobs of a session run in call order. The attach of a job closes before the next job
    // opens its attach, and idle returns after the last job. A failed send does not stop the
    // next one.
    @Test func theJobsOfASessionRunOneAfterTheOther() async throws {
        let rig = Rig()
        rig.sizes.answer(nil, termSize)
        let failed = rig.send()
        let first = rig.send()
        let second = rig.send()
        let a = try await rig.child(0)
        #expect(await rig.ended(failed))
        #expect(failed.refusal == .noSize)
        await rig.output(a)
        await rig.at(1500)
        await rig.at(1800)
        await rig.at(2800)
        #expect(await rig.ended(first))
        #expect(first.at == 2800)
        let b = try await rig.child(1)
        #expect(a.signals == [.hangup])
        await rig.output(b)
        let idle = Task { @MainActor in
            await rig.input.idle(S)
            return rig.now
        }
        await rig.at(4300)
        await rig.at(4600)
        await rig.at(5600)
        #expect(await rig.ended(second))
        #expect(second.at == 5600)
        #expect(await idle.value == 5600)
        #expect(rig.writes(a) == [pasted, cr])
        #expect(rig.writes(b) == [pasted, cr])
    }

    // A left arrow key in a chat can open the agent view. A send to the chat waits 2 s after the
    // key, and each new key starts the wait again, for at most 15 s. A block that comes during
    // the wait refuses the send.
    @Test func aSendWaitsTwoSecondsAfterALeftArrowKey() async throws {
        let rig = Rig()
        let chat = try await rig.quietChat()
        rig.input.leftKey(chat: owner)
        let sent = rig.send()
        await rig.at(1999)
        #expect(rig.writes(chat).isEmpty)
        await rig.at(2000)
        #expect(await rig.wrote(chat, [pasted]))
        await rig.at(2300)
        #expect(await rig.ended(sent))

        rig.base += 2300
        rig.input.leftKey(chat: owner)
        let blocked = rig.send()
        await rig.at(800)
        rig.input.setBlocked(chat: owner, true)
        await rig.at(2000)
        #expect(await rig.ended(blocked))
        #expect(blocked.refusal == .agentView)
        #expect(blocked.at == 2000)

        rig.base += 2000
        rig.input.setBlocked(chat: owner, false)
        rig.input.leftKey(chat: owner)
        let late = rig.send()
        for time in stride(from: 1000, through: 14_000, by: 1000) {
            await rig.at(time)
            // The send checked the key time and sleeps again: the next key comes after it.
            await rig.clock.waitForSleepers(1)
            rig.input.leftKey(chat: owner)
        }
        await rig.at(15_000)
        #expect(await rig.ended(late))
        #expect(late.refusal == .notReady)
        #expect(late.at == 15_000)
        #expect(rig.writes(chat) == [pasted, cr])
    }

    // A chat window that opens during the size read takes the job: no hidden attach opens beside
    // it.
    @Test func aChatThatOpensDuringTheSizeReadTakesTheJob() async throws {
        let rig = Rig()
        let gate = TestGate()
        defer { gate.openAll() }
        rig.sizes.holdNext(gate)
        let sent = rig.send()
        await gate.waitUntilHolding()
        _ = try await rig.ptys.open(.test(chatView, shortId: jobShortId), size: termSize)
        rig.input.opened(chat: owner, shortId: jobShortId)
        rig.input.output(chat: owner)
        gate.open()
        await rig.at(1500)
        let child = try await rig.child(0)
        #expect(await rig.wrote(child, [pasted]))
        await rig.at(1800)
        #expect(await rig.ended(sent))
        #expect(rig.spawner.spawns.count == 1)
        #expect(rig.sizes.reads.count == 1)
    }
}

@Suite("the Interrupt of the session input", .testTimeLimit)
@MainActor
struct SessionInputInterruptTests {
    // One Esc goes into a chat with output at once. A red box does not block it. A session that
    // Bifrost does not own gets nothing.
    @Test func anInterruptSendsOneEscIntoTheChat() async throws {
        let rig = Rig()
        let chat = try await rig.quietChat()
        rig.rows = [row(redPrompt)]
        let stop = rig.interrupt()
        #expect(await rig.ended(stop))
        #expect(stop.refusal == nil)
        #expect(stop.at == 0)
        #expect(rig.writes(chat) == [esc])
        rig.rows = [row { $0.kind = .external }]
        await rig.at(2000, sleepers: 0)
        let refused = rig.interrupt()
        #expect(await rig.ended(refused))
        #expect(refused.refusal == .notOwned)
        #expect(rig.writes(chat) == [esc])
    }

    // A working session shows a spinner and never gets quiet. So the Esc goes 300 ms after the
    // first output of the hidden attach, and the attach closes 1 s later. The replies of the
    // terminal model go to the attach until the Esc, and nowhere after it.
    @Test func anInterruptThroughAHiddenAttachSendsTheEscAfterTheFirstOutput() async throws {
        let rig = Rig(replies: true)
        let stop = rig.interrupt()
        let child = try await rig.child(0)
        await rig.at(100)
        await rig.output(child)
        #expect(await rig.wrote(child, ["R"]))
        await rig.at(200)
        await rig.output(child)
        await rig.at(399)
        #expect(rig.writes(child) == ["R", "R"])
        await rig.at(400)
        #expect(await rig.wrote(child, ["R", "R", esc]))
        await rig.output(child)
        await rig.at(1399)
        #expect(!stop.done)
        await rig.at(1400)
        #expect(await rig.ended(stop))
        #expect(stop.refusal == nil)
        #expect(stop.at == 1400)
        #expect(rig.writes(child) == ["R", "R", esc])
        #expect(child.signals == [.hangup])
    }

    // With no output in 15 s, the Interrupt writes nothing.
    @Test func anInterruptWithNoOutputWritesNothing() async throws {
        let rig = Rig()
        let stop = rig.interrupt()
        let child = try await rig.child(0)
        await rig.at(14_999)
        #expect(!stop.done)
        await rig.at(15_000)
        #expect(await rig.ended(stop))
        #expect(stop.refusal == .notReady)
        #expect(rig.writes(child).isEmpty)
        #expect(child.signals == [.hangup])
    }

    // Two Esc open the rewind menu. An Interrupt while one waits or runs ends at once, and an
    // Interrupt within 1.5 s of an Esc writes nothing.
    @Test func aSecondInterruptWithinOneAndAHalfSecondsHasNoEffect() async throws {
        let rig = Rig()
        let chat = try await rig.quietChat()
        let first = rig.interrupt()
        let second = rig.interrupt()
        #expect(await rig.ended(first))
        #expect(await rig.ended(second))
        #expect(first.refusal == nil)
        #expect(second.refusal == nil)
        #expect(rig.writes(chat) == [esc])
        await rig.at(1000, sleepers: 0)
        let early = rig.interrupt()
        #expect(await rig.ended(early))
        #expect(early.refusal == nil)
        #expect(rig.writes(chat) == [esc])
        await rig.at(1600, sleepers: 0)
        let later = rig.interrupt()
        #expect(await rig.ended(later))
        #expect(rig.writes(chat) == [esc, esc])
    }

    // An Interrupt behind a send that wrote its paste waits for the send. A new Interrupt then
    // ends at once. The Esc goes through a new hidden attach after the close of the first one.
    @Test func anInterruptBehindASendThatWroteWaitsForIt() async throws {
        let rig = Rig()
        let sent = rig.send()
        let a = try await rig.child(0)
        await rig.output(a)
        await rig.at(1500)
        await rig.at(1600)
        let stop = rig.interrupt()
        let again = rig.interrupt()
        #expect(await rig.ended(again))
        #expect(again.at == 1600)
        #expect(!stop.done)
        await rig.at(1800)
        await rig.at(2800)
        #expect(await rig.ended(sent))
        #expect(sent.refusal == nil)
        let b = try await rig.child(1)
        await rig.output(b)
        await rig.at(3100)
        #expect(await rig.wrote(b, [esc]))
        await rig.at(4100)
        #expect(await rig.ended(stop))
        #expect(stop.at == 4100)
        #expect(rig.writes(a) == [pasted, cr])
    }

    // An Interrupt cancels each send of the session that did not write yet: the send that waits
    // for quiet output and the send behind it. The Esc goes at once. A send after the Esc waits
    // 200 ms.
    @Test func anInterruptCancelsTheSendsThatDidNotWrite() async throws {
        let rig = Rig()
        let chat = try await rig.openChat()
        for time in stride(from: 0, through: 1000, by: 100) {
            await rig.at(time, sleepers: 0)
            rig.input.output(chat: owner)
        }
        rig.base = 1000
        let first = rig.send()
        let second = rig.send("/compact")
        let stop = rig.interrupt()
        #expect(await rig.ended(first))
        #expect(await rig.ended(second))
        #expect(await rig.ended(stop))
        #expect(first.refusal == .cancelled)
        #expect(second.refusal == .cancelled)
        #expect(first.at == 0)
        #expect(second.at == 0)
        #expect(stop.refusal == nil)
        #expect(rig.writes(chat) == [esc])
        rig.input.output(chat: owner)
        let later = rig.send()
        await rig.at(1500)
        await rig.at(1800)
        #expect(await rig.ended(later))
        #expect(later.refusal == nil)
        #expect(rig.writes(chat) == [esc, pasted, cr])
    }

    // An Interrupt cancels a send in a busy hidden attach. That attach closes before the attach
    // of the Interrupt opens, so one attach serves the session at a time.
    @Test func anInterruptCancelsAHiddenSendAndTheAttachesDoNotOverlap() async throws {
        let rig = Rig()
        let sent = rig.send()
        let a = try await rig.child(0)
        await rig.output(a)
        for time in stride(from: 500, through: 3000, by: 500) {
            await rig.at(time)
            await rig.output(a)
        }
        let stop = rig.interrupt()
        #expect(await rig.ended(sent))
        #expect(sent.refusal == .cancelled)
        #expect(sent.at == 3000)
        let b = try await rig.child(1)
        #expect(a.signals == [.hangup])
        await rig.at(3100)
        await rig.output(b)
        await rig.at(3400)
        #expect(await rig.wrote(b, [esc]))
        await rig.at(4400)
        #expect(await rig.ended(stop))
        #expect(stop.at == 4400)
        #expect(rig.writes(a).isEmpty)
    }

    // A send that wrote its paste is not cancelled: the cr goes, then the Esc. A left arrow key
    // can delay the cr, and the Esc waits for it.
    @Test func anInterruptKeepsASendThatWroteItsPaste() async throws {
        let rig = Rig()
        let chat = try await rig.quietChat()
        let sent = rig.send()
        #expect(await rig.wrote(chat, [pasted]))
        await rig.at(100)
        let stop = rig.interrupt()
        await rig.at(300)
        #expect(await rig.ended(stop))
        #expect(sent.refusal == nil)
        #expect(stop.refusal == nil)
        #expect(rig.writes(chat) == [pasted, cr, esc])

        await rig.at(2000, sleepers: 0)
        rig.base += 2000
        let keyed = rig.send()
        #expect(await rig.wrote(chat, [pasted, cr, esc, pasted]))
        await rig.at(100)
        rig.input.leftKey(chat: owner)
        await rig.at(150)
        let held = rig.interrupt()
        await rig.at(300)
        await rig.at(2100)
        #expect(await rig.ended(held))
        #expect(keyed.refusal == nil)
        #expect(keyed.at == 2100)
        #expect(held.at == 2100)
        #expect(rig.writes(chat) == [pasted, cr, esc, pasted, cr, esc])
    }

    // A send that waits after a left arrow key did not write yet: the Interrupt cancels it.
    @Test func anInterruptCancelsASendThatWaitsAfterALeftArrowKey() async throws {
        let rig = Rig()
        let chat = try await rig.quietChat()
        rig.input.leftKey(chat: owner)
        let sent = rig.send()
        await rig.at(500)
        let stop = rig.interrupt()
        #expect(await rig.ended(stop))
        #expect(sent.refusal == .cancelled)
        #expect(sent.at == 500)
        #expect(stop.at == 500)
        #expect(rig.writes(chat) == [esc])
    }

    // An Interrupt of another session does not cancel the send.
    @Test func anInterruptOfAnotherSessionDoesNotCancelTheSend() async throws {
        let rig = Rig()
        let sent = rig.send()
        let other = rig.interrupt(otherId)
        let child = try await rig.child(0)
        #expect(await rig.ended(other))
        #expect(other.refusal == .notOwned)
        await rig.output(child)
        await rig.at(1500)
        await rig.at(1800)
        await rig.at(2800)
        #expect(await rig.ended(sent))
        #expect(sent.refusal == nil)
        #expect(rig.writes(child) == [pasted, cr])
    }

    // A cancel during the size read ends the send when the read returns. The send opens no
    // attach, and the Interrupt then opens its own.
    @Test func aCancelDuringTheSizeReadOpensNoAttachForTheSend() async throws {
        let rig = Rig()
        let gate = TestGate()
        defer { gate.openAll() }
        rig.sizes.holdNext(gate)
        let sent = rig.send()
        await gate.waitUntilHolding()
        let stop = rig.interrupt()
        gate.open()
        #expect(await rig.ended(sent))
        #expect(sent.refusal == .cancelled)
        let child = try await rig.child(0)
        await rig.output(child)
        await rig.at(300)
        #expect(await rig.wrote(child, [esc]))
        await rig.at(1300)
        #expect(await rig.ended(stop))
        #expect(rig.spawner.spawns.count == 1)
        #expect(rig.sizes.reads == [4242, 4242])
    }

    // After an Esc, the next write waits 200 ms, so the session does not read the Esc and the
    // paste as one key.
    @Test func aSendAfterAnEscWaitsTheEscGap() async throws {
        let rig = Rig()
        let chat = try await rig.quietChat()
        let stop = rig.interrupt()
        let sent = rig.send()
        #expect(await rig.ended(stop))
        await rig.at(199)
        #expect(rig.writes(chat) == [esc])
        await rig.at(200)
        #expect(await rig.wrote(chat, [esc, pasted]))
        await rig.at(500)
        #expect(await rig.ended(sent))
        #expect(sent.refusal == nil)
        #expect(rig.writes(chat) == [esc, pasted, cr])
    }

    // A left arrow key does not delay an Interrupt.
    @Test func aLeftArrowKeyDoesNotDelayAnInterrupt() async throws {
        let rig = Rig()
        let chat = try await rig.quietChat()
        rig.input.leftKey(chat: owner)
        let stop = rig.interrupt()
        #expect(await rig.ended(stop))
        #expect(stop.at == 0)
        #expect(rig.writes(chat) == [esc])
    }
}

@Suite("the session input and a chat open", .testTimeLimit)
@MainActor
struct SessionInputChatOpenTests {
    // While the chat of the session opens, a job waits: no size read and no hidden attach. When
    // the open ends with an attach, the job goes through the chat.
    @Test func aJobWaitsWhileTheChatOfItsSessionOpens() async throws {
        let rig = Rig()
        await rig.input.chatOpening(chat: owner)
        let stop = rig.interrupt()
        await rig.at(5000, sleepers: 0)
        #expect(!stop.done)
        #expect(rig.sizes.reads.isEmpty)
        #expect(rig.spawner.spawns.isEmpty)
        _ = try await rig.ptys.open(.test(chatView, shortId: jobShortId), size: termSize)
        rig.input.opened(chat: owner, shortId: jobShortId)
        rig.input.output(chat: owner)
        await rig.at(5300)
        let child = try await rig.child(0)
        #expect(await rig.wrote(child, [esc]))
        #expect(await rig.ended(stop))
        #expect(stop.at == 5300)
        #expect(rig.spawner.spawns.count == 1)
    }

    // A chat open that ends with no attach frees the job. The job then starts again and takes a
    // hidden attach.
    @Test func aFailedChatOpenFreesTheJob() async throws {
        let rig = Rig()
        await rig.input.chatOpening(chat: owner)
        let stop = rig.interrupt()
        await rig.at(1000, sleepers: 0)
        rig.input.chatOpenFailed(chat: owner)
        let child = try await rig.child(0)
        await rig.output(child)
        await rig.at(1300)
        #expect(await rig.wrote(child, [esc]))
        await rig.at(2300)
        #expect(await rig.ended(stop))
        #expect(stop.at == 2300)
    }

    // An Interrupt cancels a send that waits for a chat open at once.
    @Test func anInterruptCancelsASendThatWaitsForAChatOpen() async throws {
        let rig = Rig()
        await rig.input.chatOpening(chat: owner)
        let sent = rig.send()
        await rig.at(100, sleepers: 0)
        let stop = rig.interrupt()
        #expect(await rig.ended(sent))
        #expect(sent.refusal == .cancelled)
        #expect(sent.at == 100)
        #expect(!stop.done)
        _ = try await rig.ptys.open(.test(chatView, shortId: jobShortId), size: termSize)
        rig.input.opened(chat: owner, shortId: jobShortId)
        rig.input.output(chat: owner)
        await rig.at(400)
        #expect(await rig.ended(stop))
        #expect(stop.at == 400)
        #expect(rig.writes(try await rig.child(0)) == [esc])
    }

    // A chat open waits until the session has no job. With no job, idle returns at once.
    @Test func aChatOpenWaitsUntilTheSessionHasNoJob() async throws {
        let rig = Rig()
        await rig.input.idle(S)
        let stop = rig.interrupt()
        let child = try await rig.child(0)
        let opening = Task { @MainActor in
            await rig.input.chatOpening(chat: owner)
            return rig.now
        }
        await rig.output(child)
        await rig.at(300)
        await rig.at(1300)
        #expect(await rig.ended(stop))
        #expect(await opening.value == 1300)
        #expect(child.signals == [.hangup])
    }
}
