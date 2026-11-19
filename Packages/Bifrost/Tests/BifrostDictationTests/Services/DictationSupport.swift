import BifrostFoundation
import BifrostKeyboard
import BifrostTestSupport
import Testing

@testable import BifrostDictation

// The test side of the dictation of a chat: the recorded PTY, the recorded calls to the service,
// the answer of the vim mode read and the typer driver.

// The text with its exact Unicode scalars. String == uses canonical equivalence (U+00E9 is equal
// to U+0065 U+0301), but the PTY gets the bytes. So the tests compare the UTF-8 bytes.
struct Exact: Equatable, CustomStringConvertible {
    let text: String

    init(_ text: String) { self.text = text }

    static func == (a: Exact, b: Exact) -> Bool { a.text.utf8.elementsEqual(b.text.utf8) }

    var description: String { text.debugDescription }
}

extension String {
    var exact: Exact { Exact(self) }
}

extension Array where Element == String {
    var exact: [Exact] { map(Exact.init) }
}

// The DELs at the start of a write, and the text after them.
func parts(_ data: String) -> (deletes: Int, text: String) {
    let deletes = data.unicodeScalars.prefix { $0 == "\u{7F}" }.count
    return (deletes, String(data.unicodeScalars.dropFirst(deletes)))
}

// The prompt of Claude, as a spike measured it: one DEL removes the last Character, and a DEL on
// an empty prompt does nothing.
func applyWrite(_ data: String, to prompt: inout String) {
    let (deletes, text) = parts(data)
    prompt = String(prompt.dropLast(deletes)) + text
}

// A seeded source of random numbers (SplitMix64), so each run makes the same texts.
struct SeededRandom: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    mutating func int(_ range: ClosedRange<Int>) -> Int { Int.random(in: range, using: &self) }

    mutating func chance(_ p: Double) -> Bool { Double.random(in: 0..<1, using: &self) < p }

    mutating func pick<T>(_ items: [T]) -> T { items[int(0...(items.count - 1))] }
}

// The recorded PTY of a chat: the prompt of Claude and each write with its time on the clock.
@MainActor
final class RecordedChat: DictationChat {
    private let clock: ManualClock
    var hasPTY = true
    // False when the chat has no attach or blocks its input: a send does not go.
    var takesInput = true
    var blocksDictation = false
    private(set) var prompt = ""
    private(set) var writes: [(at: Duration, data: String)] = []
    private(set) var views: [DictationView] = []
    private(set) var looks: [Double?] = []

    init(clock: ManualClock) {
        self.clock = clock
    }

    func send(_ text: String) -> Bool {
        guard takesInput else { return false }
        writes.append((clock.now.offset, text))
        applyWrite(text, to: &prompt)
        return true
    }

    func dictationViewChanged(_ view: DictationView) { views.append(view) }

    func dictationLookChanged(_ level: Double?) { looks.append(level) }
}

// The calls of the dictation to the service.
@MainActor
final class RecordedService: DictationControl {
    private(set) var starts = 0
    private(set) var stops = 0
    private(set) var warms = 0

    func start(chat: SessionID) { starts += 1 }

    func stop(chat: SessionID) { stops += 1 }

    func warm() { warms += 1 }
}

// The answer of the vim mode read. With no value, each read waits for answer(_:).
@MainActor
final class VimAnswer {
    var value: Bool?
    private var reads: [CheckedContinuation<Bool, Never>] = []
    // The reads that got an answer, and the reads that went on after it.
    private var answered = 0
    private var returned = 0

    init(_ value: Bool?) {
        self.value = value
    }

    // The reads that wait for an answer now.
    var waiting: Int { reads.count }
    // True when each answered read went on. The read then ran the rest of its check in the same
    // turn of the main actor.
    var answersDone: Bool { returned == answered }

    func read() async -> Bool {
        if let value { return value }
        let on = await withCheckedContinuation { reads.append($0) }
        returned += 1
        return on
    }

    // Answer the oldest read that waits.
    func answer(_ on: Bool) {
        guard !reads.isEmpty else { return }
        answered += 1
        reads.removeFirst().resume(returning: on)
    }
}

// The dictation of one chat with the recorded PTY, the recorded service and a manual clock.
@MainActor
final class DictationRig {
    static let session: SessionID = "cccccccc-cccc-4ccc-8ccc-cccccccccccc"

    let clock = ManualClock()
    let chat: RecordedChat
    let service = RecordedService()
    let vim: VimAnswer
    let dictation: ChatDictation

    // vim nil: each vim mode read waits for answerVim(_:). service false: the app has no speech
    // engine.
    init(vim: Bool? = false, service: Bool = true) {
        chat = RecordedChat(clock: clock)
        let answer = VimAnswer(vim)
        self.vim = answer
        dictation = ChatDictation(
            session: Self.session, chat: chat, service: service ? self.service : nil, clock: clock,
            vimMode: { await answer.read() })
    }

    var prompt: String { chat.prompt }
    var phase: DictationPhase { dictation.view.phase }
    var line: NoticeLine? { DictationNoticeText.line(dictation.view) }
    var starts: Int { service.starts }
    var stops: Int { service.stops }

    // A hold of the key: the vim mode read answers.
    func hold() async {
        dictation.start()
        await settled()
    }

    // Wait until the dictation can do nothing more by itself: the vim mode read of a hold ended
    // or waits for answerVim(_:), and each timer that runs sleeps on the clock. A timer whose
    // time came acts on the main actor, and it can start the next timer.
    func settled(sourceLocation: SourceLocation = #_sourceLocation) async {
        await waitUntil(every: .milliseconds(1), sourceLocation: sourceLocation) {
            (dictation.vimCheck == nil || vim.waiting > 0)
                && dictation.runningTimers == clock.sleeperCount
        }
    }

    // A hold of the dictation key through the chat input: the key goes down, and the hold time
    // passes. A fallback of the dictation then types the key.
    func holdKey() async {
        let space = KeyEvent(keyCode: KeyCode(.space), characters: " ")
        #expect(dictation.chatInput.key(space, dictationKey: KeyCode(.space)))
        await advance(Int(ChatInput.holdTime / .milliseconds(1)))
    }

    // A hold that the service answers with ready and a first level: the microphone is open.
    func listen() async {
        await hold()
        dictation.event(.ready(language: "en-US", fallback: false))
        dictation.event(.level(0.2))
    }

    // A released dictation whose final text needs many writes.
    func finishing(_ final: String) async {
        await listen()
        dictation.event(.text(final: "abcd", volatile: ""))
        dictation.stop()
        dictation.event(.end(final: final))
    }

    // Answer the oldest vim mode read, when the read of the hold waits. The read then ends its
    // check.
    func answerVim(_ on: Bool) async {
        await settled()
        vim.answer(on)
        await waitUntil(every: .milliseconds(1)) { vim.answersDone }
        await settled()
    }

    // Move the clock by the time. Each timer acts at its own time, in order.
    func advance(_ ms: Int) async {
        let end = clock.now.offset + .milliseconds(ms)
        await settled()
        while let next = clock.nextDeadline, next.offset <= end {
            clock.advance(by: next.offset - clock.now.offset)
            await settled()
        }
        clock.advance(by: end - clock.now.offset)
        await settled()
    }

    // A key down that the terminal handles: the input rules of the chat input run first, then
    // the terminal sends the data. The holds of these tests start the dictation with no key, so
    // the rig stops a hold at another key, as the hold key does. key is the letter of a US key or
    // the name of a named key ("Enter"), and data is the text of the key.
    func press(_ key: String, _ data: String, ctrl: Bool = false) {
        let named = KeyName(rawValue: key).map { KeyCode($0) }
        guard let code = named ?? key.first.flatMap({ KeyCode(us: $0) }) else {
            Issue.record("no key for \(key)")
            return
        }
        let event = KeyEvent(
            keyCode: code, characters: data, charactersIgnoringModifiers: named == nil ? key : data,
            modifiers: ctrl ? .control : [])
        if phase == .listening { dictation.cancel() }
        if !dictation.chatInput.key(event, dictationKey: nil) { dictation.chatInput.data(data) }
    }

    // A mouse down, a paste or a drop.
    func other() {
        dictation.chatInput.other()
    }

    // The data of the terminal, for example the arrow keys of a mouse wheel.
    func data(_ text: String) {
        dictation.chatInput.data(text)
    }
}

// The typer and a chat that writes its parts: one write at once, then the next write at each
// step (the end of the gap). A write that breaks a rule of the prompt of Claude is a problem.
@MainActor
struct TyperDriver {
    let typer = DictationTyper()
    let user: String
    // The last sent text of the chat that the typer reads.
    var lastSent: String
    // True when the last sent text becomes each write of the typer, as in the chat.
    var lastSentFollowsWrites = false
    private(set) var prompt: String
    private(set) var data: [String] = []
    private(set) var problems: [String] = []
    private var gap = false

    init(user: String = "", lastSent: String? = nil) {
        self.user = user
        self.lastSent = lastSent ?? user
        prompt = user
        typer.start(lastSent: self.lastSent)
    }

    // The text after the text of the user.
    var dictated: String {
        String(prompt.unicodeScalars.dropFirst(user.unicodeScalars.count))
    }

    mutating func update(_ final: String, _ volatile: String) {
        typer.give(final: final, volatile: volatile, end: false, lastSent: lastSent)
        if !gap { write() }
    }

    mutating func finish(_ final: String) {
        typer.give(final: final, volatile: "", end: true, lastSent: lastSent)
        if !gap { write() }
    }

    // The gap ends: the next write.
    mutating func step() {
        gap = false
        write()
    }

    mutating func runAll() {
        var count = 0
        while gap, count < 100_000 {
            count += 1
            step()
        }
    }

    private mutating func write() {
        guard let next = typer.nextWrite() else { return }
        let (write, deletes) = next
        gap = true
        data.append(write)
        let text = parts(write).text
        if write.isEmpty { problems.append("an empty write") }
        if text.unicodeScalars.contains("\u{7F}") { problems.append("a DEL after the text") }
        if text.unicodeScalars.contains(where: { $0.properties.generalCategory == .control }) {
            problems.append("a control character in the text")
        }
        if text.utf16.count > TypingRules.maxWriteText && text.count > 1 {
            problems.append("too much text")
        }
        if deletes > TypingRules.maxWriteDeletes { problems.append("too many DELs") }
        applyWrite(write, to: &prompt)
        if !prompt.unicodeScalars.starts(with: user.unicodeScalars) {
            problems.append("the text of the user changed")
        }
        if lastSentFollowsWrites { lastSent = write }
    }
}
