// The chat input of a chat: the hold key of dictation and the input rules. The rig gives the
// keys to a real chat input with a dictation that records each call, and moves a manual clock.
// A key that the chat input does not take goes to the terminal, which sends a printable key as
// data. So the text shows a lost, a doubled or a moved space. The last suite runs the chat input
// of a real ChatDictation.
import BifrostKeyboard
import BifrostTestSupport
import Testing

@testable import BifrostDictation
@testable import BifrostSessions

// One call of the chat input to the dictation.
enum DictationCall: Equatable {
    case start, stop, cancel, interrupt, block, warm
    case input(String)
}

// The dictation of the chat input in a test: each call goes to the log, and each input goes to
// the text.
@MainActor
final class RecordedInputDictation: ChatInputDictation {
    var canStart = true
    var heard = true
    var waits = false
    // The value of waits after a cancel, or nil to keep it.
    var waitsAfterCancel: Bool?
    private(set) var log: [DictationCall] = []
    private(set) var text = ""

    func start() { log.append(.start) }
    func stop() { log.append(.stop) }

    func cancel() {
        log.append(.cancel)
        if let waitsAfterCancel { waits = waitsAfterCancel }
    }

    func interrupt() { log.append(.interrupt) }
    func block() { log.append(.block) }
    func warm() { log.append(.warm) }

    func input(_ data: String) {
        log.append(.input(data))
        text += data
    }
}

// The hold time in milliseconds.
let holdMs = Int(ChatInput.holdTime / .milliseconds(1))

// A typed key: it stops a dictation, then its text goes as input.
let typedSpace: [DictationCall] = [.interrupt, .input(" ")]

@MainActor
final class InputRig {
    let clock = ManualClock()
    let dictation = RecordedInputDictation()
    let input: ChatInput
    var dictationKey: KeyCode?

    // dictationKey nil: the dictation key is Off.
    init(dictationKey: KeyCode? = KeyCode(.space), holdTime: Duration = ChatInput.holdTime) {
        self.dictationKey = dictationKey
        input = ChatInput(dictation: dictation, clock: clock, holdTime: holdTime)
    }

    var log: [DictationCall] { dictation.log }
    var text: String { dictation.text }
    // The calls that start and stop dictation, in order.
    var holds: [DictationCall] { log.filter { [.start, .stop, .cancel].contains($0) } }

    @discardableResult
    func down(_ key: String, _ mods: Mods = Mods()) -> Bool {
        let event = ev(.keydown, key, mods)
        let taken = input.key(event, dictationKey: dictationKey)
        if !taken && !mods.meta && !mods.ctrl && key.unicodeScalars.count == 1 {
            input.data(key)
        }
        return taken
    }

    @discardableResult
    func up(_ key: String, _ mods: Mods = Mods()) -> Bool {
        input.key(ev(.keyup, key, mods), dictationKey: dictationKey)
    }

    func blur() { input.focus(false, dictationKey: dictationKey) }

    // Move the clock. A hold timer that is due runs before the call returns.
    func advance(_ ms: Int) async {
        await timerSettles()
        clock.advance(by: .milliseconds(ms))
        await timerSettles()
    }

    // Wait until a hold timer sleeps on the clock. At the limit the wait records an issue and
    // gives false, so a broken timer fails the test and does not hang it.
    @discardableResult
    func timerSleeps() async -> Bool {
        await clock.waitForSleepers(1)
    }

    // Wait until the hold timer sleeps on the clock or has run.
    private func timerSettles() async {
        var turns = 0
        while input.holdTimer != nil, clock.sleeperCount == 0, turns < 10_000 {
            turns += 1
            await Task.yield()
        }
    }
}

@Suite("the hold key of dictation", .testTimeLimit)
@MainActor
struct HoldKeyTests {
    @Test func theHoldTimeIs250ms() {
        #expect(ChatInput.holdTime == .milliseconds(250))
    }

    @Test func aTapShorterThanTheHoldTimeTypesOneSpace() async {
        let t = InputRig()
        #expect(t.down(" "))
        await t.advance(holdMs - 1)
        #expect(t.text == "")
        #expect(t.up(" "))
        await t.advance(1000)
        // A new press makes the speech engine ready.
        #expect(t.log == [.warm] + typedSpace)
    }

    // While a final text types, the key types its text with no stop of the typer.
    @Test func aTapWhileAFinalTextTypesDoesNotStopTheTyper() {
        let t = InputRig()
        t.dictation.waits = true
        t.down(" ")
        t.up(" ")
        #expect(t.log == [.warm, .input(" ")])
    }

    @Test func aHoldStartsDictationAndTypesNoSpace() async {
        let t = InputRig()
        t.down(" ")
        await t.advance(holdMs)
        #expect(t.holds == [.start])
        #expect(t.up(" "))
        #expect(t.log == [.warm, .start, .stop])
        #expect(t.text == "")
    }

    @Test func anotherKeyDuringTheWaitTypesTheSpaceFirst() async {
        let t = InputRig()
        t.down(" ")
        await t.advance(100)
        #expect(!t.down("b"))
        #expect(t.text == " b")
        await t.advance(1000)
        #expect(t.up(" "))
        #expect(t.holds.isEmpty)
        #expect(t.text == " b")
    }

    @Test func fastTypingWithRolloverKeepsEachSpaceInPlace() async {
        let t = InputRig()
        let text = "The quick Brown fox, jumps over the lazy dog. Then it runs."
        // Each key goes down 40 ms after the last key. After every second word, the next key
        // goes down before Space goes up. A capital letter has Shift first.
        let words = text.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        for (index, word) in words.enumerated() {
            for (at, char) in word.enumerated() {
                let key = String(char)
                let upper = key != key.lowercased()
                if upper { t.down("Shift", Mods(shift: true)) }
                t.down(key, Mods(shift: upper))
                if index > 0 && at == 0 && index % 2 == 0 {
                    // Rollover: the first key of the word went down while Space is still down.
                    await t.advance(30)
                    t.up(" ")
                }
                await t.advance(40)
                t.up(key, Mods(shift: upper))
                if upper { t.up("Shift") }
            }
            if index == words.count - 1 { break }
            t.down(" ")
            await t.advance(60)
            if index % 2 == 0 { t.up(" ") }
        }
        await t.advance(1000)
        #expect(t.text == text)
        #expect(t.holds.isEmpty)
    }

    // Before the first level or text, no green shows: the user typed a slow space.
    @Test(arguments: ["a release", "another key"])
    func beforeTheFirstLevelTheKeyTypesItsSpace(_ end: String) async {
        let t = InputRig()
        t.dictation.heard = false
        t.down(" ")
        await t.advance(holdMs + 400)
        if end == "a release" {
            #expect(t.up(" "))
            #expect(t.log == [.warm, .start] + typedSpace + [.stop])
            #expect(t.text == " ")
        } else {
            #expect(!t.down("w"))
            #expect(t.log == [.warm, .start] + typedSpace + [.cancel, .interrupt, .input("w")])
            #expect(t.text == " w")
            #expect(t.up(" "))
            #expect(t.holds == [.start, .cancel])
        }
    }

    // After the first level or text, or while the chat shows the download, the key types
    // nothing.
    @Test func afterTheFirstLevelTheKeyTypesNoSpace() async {
        let release = InputRig()
        release.down(" ")
        await release.advance(holdMs)
        release.up(" ")
        #expect(release.holds == [.start, .stop])
        let other = InputRig()
        other.down(" ")
        await other.advance(holdMs)
        other.down("w")
        #expect(other.holds == [.start, .cancel])
        #expect(other.text == "w")
    }

    @Test func theRepeatsOfTheHeldKeyDoNothing() async {
        let t = InputRig()
        t.down(" ")
        #expect(t.down(" ", Mods(isRepeat: true)))
        await t.advance(holdMs)
        for _ in 0..<5 { #expect(t.down(" ", Mods(isRepeat: true))) }
        t.up(" ")
        #expect(t.log == [.warm, .start, .stop])
        #expect(t.text == "")
    }

    @Test(
        "Space with a modifier is a normal key",
        arguments: [
            ("Shift", Mods(shift: true)), ("Control", Mods(ctrl: true)),
            ("Option", Mods(alt: true)), ("Cmd", Mods(meta: true)),
        ])
    func modifiers(name: String, mods: Mods) async {
        let t = InputRig()
        #expect(!t.down(" ", mods), "\(name)")
        #expect(t.input.holdTimer == nil)
        await t.advance(1000)
        #expect(!t.up(" ", mods))
        #expect(t.holds.isEmpty)
        #expect(!t.log.contains(.warm))
    }

    // The key "Process" is a key of a composition. The native event of each key of a
    // composition has isComposing (MacKeys.keyEvent).
    @Test func spaceDuringACompositionIsANormalKey() async {
        let t = InputRig()
        #expect(!t.down(" ", Mods(isComposing: true)))
        #expect(!t.down("Process", Mods(isComposing: true)))
        await t.advance(1000)
        #expect(t.holds.isEmpty)
        #expect(t.input.holdTimer == nil)
    }

    @Test func aBlockedChatTypesTheSpaceAndNeverStarts() async {
        let t = InputRig()
        t.dictation.canStart = false
        // A normal key: the terminal types it at once, with its key repeat.
        #expect(!t.down(" "))
        #expect(!t.down(" ", Mods(isRepeat: true)))
        await t.advance(1000)
        #expect(!t.up(" "))
        #expect(t.holds.isEmpty)
        #expect(t.text == "  ")
    }

    @Test func aBlockDuringTheWaitTypesTheSpaceAtTheHoldTime() async {
        let t = InputRig()
        t.down(" ")
        t.dictation.canStart = false
        await t.advance(holdMs)
        #expect(t.log == [.warm] + typedSpace)
        #expect(t.down(" ", Mods(isRepeat: true)))
        #expect(t.up(" "))
        #expect(t.log == [.warm] + typedSpace)
    }

    @Test(arguments: ["another key", "a blur", "a close", "a modifier key"])
    func dictationStopsEarly(at stop: String) async {
        let t = InputRig()
        t.down(" ")
        await t.advance(holdMs)
        switch stop {
        case "another key": #expect(!t.down("a"))
        case "a blur": t.blur()
        case "a close": t.input.close()
        default: #expect(!t.down("Meta", Mods(meta: true)))
        }
        #expect(t.holds == [.start, .cancel])
        // The key up and the repeats do nothing more.
        t.down(" ", Mods(isRepeat: true))
        t.up(" ")
        #expect(t.holds == [.start, .cancel])
    }

    @Test func aBlurDuringTheWaitTypesTheSpaceAndACloseTypesNothing() async {
        let blur = InputRig()
        blur.down(" ")
        blur.blur()
        await blur.advance(1000)
        #expect(blur.log == [.warm] + typedSpace)
        let close = InputRig()
        close.down(" ")
        close.input.close()
        await close.advance(1000)
        #expect(close.log == [.warm])
    }

    // macOS sends no key up for a key that goes up while Cmd is down.
    @Test func aNewPressStartsAgainWhenTheKeyUpNeverCame() async {
        let t = InputRig()
        t.down(" ")
        t.down("Meta", Mods(meta: true))
        #expect(t.text == " ")
        t.down(" ")
        await t.advance(holdMs)
        #expect(t.holds == [.start])
        #expect(t.text == " ")
    }

    @Test func aFallbackTypesTheHeldKeyOneTime() async {
        let t = InputRig()
        t.down(" ")
        await t.advance(holdMs)
        t.input.fallback()
        t.input.fallback()
        #expect(t.log == [.warm, .start] + typedSpace)
        t.up(" ")
        t.input.fallback()
        #expect(t.log == [.warm, .start] + typedSpace)
    }

    @Test func spaceIsANormalKeyWhenTheDictationKeyIsOff() async {
        let t = InputRig(dictationKey: nil)
        #expect(!t.down(" "))
        #expect(t.input.holdTimer == nil)
        await t.advance(1000)
        #expect(!t.up(" "))
        #expect(t.log == [.interrupt, .input(" ")])
    }

    @Test func anotherDictationKeyTypesItsOwnText() async {
        let t = InputRig(dictationKey: KeyCode(us: "/"))
        #expect(!t.down(" "))
        #expect(t.down("/"))
        t.up("/")
        #expect(t.text == " /")
        t.down("/")
        await t.advance(holdMs)
        #expect(t.holds == [.start])
    }

    // A sleep can end after the end of its wait. A tap ends the wait of its key down, and a new
    // key down starts a new wait. The old timer wakes late: it must not start a dictation. Only
    // the new timer starts it, at its own time.
    @Test func aLateTimerOfAnEndedWaitStartsNoDictation() async throws {
        let t = InputRig()
        #expect(t.down(" "))
        let first = try #require(t.input.holdTimer)
        #expect(await t.timerSleeps())
        // The time of the first timer comes. Its task wakes, but it runs only at the next
        // suspension. Before that, the key goes up (a tap) and down again.
        t.clock.advance(by: ChatInput.holdTime)
        #expect(t.up(" "))
        #expect(t.down(" "))
        await first.value
        #expect(t.holds.isEmpty)
        #expect(t.text == " ")
        #expect(await t.timerSleeps())
        t.clock.advance(by: .milliseconds(249))
        await Task.yield()
        #expect(t.holds.isEmpty)
        let second = try #require(t.input.holdTimer)
        t.clock.advance(by: .milliseconds(1))
        await second.value
        #expect(t.holds == [.start])
    }

    // The clock moves before the task of the timer starts. The hold still starts at the time of
    // the key down plus the hold time.
    @Test func theHoldTimeCountsFromTheKeyDown() async throws {
        let t = InputRig()
        #expect(t.down(" "))
        let timer = try #require(t.input.holdTimer)
        t.clock.advance(by: ChatInput.holdTime)
        await timer.value
        #expect(t.holds == [.start])
    }

    // The real clock of the app. The limit is generous: a busy host can be slow.
    @Test(.tags(.timing)) func aHoldStartsDictationOnTheContinuousClock() async throws {
        let dictation = RecordedInputDictation()
        let input = ChatInput(dictation: dictation, clock: ContinuousClock())
        let space = { (edge: Edge) in
            input.key(ev(edge, " "), dictationKey: KeyCode(.space))
        }
        #expect(space(.keydown))
        let timer = try #require(input.holdTimer)
        let start = ContinuousClock.now
        await timer.value
        #expect(ContinuousClock.now - start >= .milliseconds(240))
        #expect(space(.keyup))
        #expect(dictation.log == [.warm, .start, .stop])
        // A tap types its space, and its timer stops.
        #expect(space(.keydown))
        #expect(space(.keyup))
        #expect(input.holdTimer == nil)
        #expect(dictation.text == " ")
    }
}

// MARK: - The edge cases of the hold key

// The timer after a step: no timer, a new timer, or the timer of the step before.
private enum TimerAfter: Sendable { case none, started, same }

private enum HoldStep: Sendable {
    // A key event: the result of the call and the calls of the dictation.
    case down(String, Mods = Mods(), takes: Bool, log: [DictationCall], timer: TimerAfter)
    case up(String, Mods = Mods(), takes: Bool, log: [DictationCall], timer: TimerAfter)
    // The clock reaches the hold time of the first key down.
    case holdTime(log: [DictationCall])
    case fallback(log: [DictationCall], timer: TimerAfter)
    case blocked(Bool)
}

private struct HoldCase: Sendable, CustomTestStringConvertible {
    let name: String
    let steps: [HoldStep]
    var testDescription: String { name }
}

private let repeated = Mods(isRepeat: true)
private let withCtrl = Mods(ctrl: true)

private let holdCases: [HoldCase] = [
    HoldCase(
        name: "a key repeat at idle is not taken, and starts no timer",
        steps: [.down(" ", repeated, takes: false, log: [.interrupt], timer: .none)]),
    HoldCase(
        name: "a second key down of the own key while waiting is taken and starts no timer",
        steps: [
            .down(" ", takes: true, log: [.warm], timer: .started),
            .down(" ", takes: true, log: [.warm], timer: .same),
            .holdTime(log: [.start]),
        ]),
    HoldCase(
        name: "a second key down of the own key while holding is taken and starts no timer",
        steps: [
            .down(" ", takes: true, log: [.warm], timer: .started),
            .holdTime(log: [.start]),
            .down(" ", takes: true, log: [.warm], timer: .none),
            .up(" ", takes: true, log: [.stop], timer: .none),
        ]),
    HoldCase(
        name: "a key up of another key while waiting is not taken, and the wait goes on",
        steps: [
            .down(" ", takes: true, log: [.warm], timer: .started),
            .up("a", takes: false, log: [], timer: .same),
            .holdTime(log: [.start]),
        ]),
    HoldCase(
        name: "a fallback while waiting does nothing, and the timer still starts dictation",
        steps: [
            .down(" ", takes: true, log: [.warm], timer: .started),
            .fallback(log: [], timer: .same),
            .holdTime(log: [.start]),
        ]),
    HoldCase(
        name: "a fallback at idle does nothing, and a later key down starts the timer",
        steps: [
            .fallback(log: [], timer: .none),
            .down(" ", takes: true, log: [.warm], timer: .started),
        ]),
    HoldCase(
        name: "a change of blocked during the hold has no effect",
        steps: [
            .down(" ", takes: true, log: [.warm], timer: .started),
            .holdTime(log: [.start]),
            .blocked(true),
            .down(" ", takes: true, log: [.warm], timer: .none),
            .up(" ", takes: true, log: [.stop], timer: .none),
        ]),
    HoldCase(
        name: "a change of blocked during the wait makes the timer type the key",
        steps: [
            .down(" ", takes: true, log: [.warm], timer: .started),
            .blocked(true),
            .holdTime(log: typedSpace),
            .up(" ", takes: true, log: [], timer: .none),
        ]),
    HoldCase(
        name: "a key up with a modifier while waiting is taken and types the key",
        steps: [
            .down(" ", takes: true, log: [.warm], timer: .started),
            .up(" ", withCtrl, takes: true, log: typedSpace, timer: .none),
        ]),
    HoldCase(
        name: "a key up with a modifier while holding is taken and stops dictation",
        steps: [
            .down(" ", takes: true, log: [.warm], timer: .started),
            .holdTime(log: [.start]),
            .up(" ", withCtrl, takes: true, log: [.stop], timer: .none),
        ]),
    HoldCase(
        name: "a key up at idle is not taken",
        steps: [.up(" ", takes: false, log: [], timer: .none)]),
]

@Suite("the hold key edge cases", .testTimeLimit)
@MainActor
struct HoldKeyEdgeTests {
    @Test("the hold key script gives its results and calls", arguments: holdCases)
    fileprivate func script(_ item: HoldCase) async {
        let t = InputRig()
        var timer: Task<Void, Never>?
        for step in item.steps {
            let before = t.log.count
            var after = TimerAfter.none
            var log: [DictationCall] = []
            switch step {
            case .down(let key, let mods, let takes, let calls, let next):
                let taken = t.input.key(ev(.keydown, key, mods), dictationKey: KeyCode(.space))
                #expect(taken == takes, "\(step)")
                (log, after) = (calls, next)
            case .up(let key, let mods, let takes, let calls, let next):
                let taken = t.input.key(ev(.keyup, key, mods), dictationKey: KeyCode(.space))
                #expect(taken == takes, "\(step)")
                (log, after) = (calls, next)
            case .holdTime(let calls):
                await t.advance(holdMs)
                log = calls
            case .fallback(let calls, let next):
                t.input.fallback()
                (log, after) = (calls, next)
            case .blocked(let value):
                t.dictation.canStart = !value
                continue
            }
            #expect(Array(t.log.dropFirst(before)) == log, "\(step)")
            let now = t.input.holdTimer
            switch after {
            case .none: #expect(now == nil, "\(step)")
            case .started: #expect(now != nil && now != timer, "\(step)")
            case .same: #expect(now != nil && now == timer, "\(step)")
            }
            timer = now
        }
    }
}

// MARK: - The input rules

@Suite("the input rules of a chat", .testTimeLimit)
@MainActor
struct ChatInputRuleTests {
    @Test func theHoldKeySeesEachKeyEventFirst() {
        let t = InputRig()
        #expect(t.down(" "))
        #expect(t.down(" ", Mods(isRepeat: true)))
        #expect(t.up(" "))
        // A new press makes the speech engine ready. No other key rule runs.
        #expect(t.log == [.warm] + typedSpace)
    }

    @Test func anotherKeyStopsADictationAndShiftEnterSendsANewLine() {
        let t = InputRig()
        #expect(t.input.key(ev(.keydown, "Enter", Mods(shift: true)), dictationKey: nil))
        #expect(t.log == [.interrupt, .input("\(KeyRoute.newLineText)")])
        #expect(!t.input.key(ev(.keydown, "a"), dictationKey: nil))
        #expect(Array(t.log.dropFirst(2)) == [.interrupt])
        // A modifier key alone and a key up stop nothing.
        for key in ["Shift", "Meta", "Alt", "Control", "CapsLock"] {
            #expect(!t.input.key(ev(.keydown, key), dictationKey: nil))
        }
        #expect(!t.input.key(ev(.keyup, "a"), dictationKey: nil))
        #expect(t.log.count == 3)
    }

    // While a final text types, a key waits and does not stop the typer. Escape and Ctrl+C
    // stop each typer and drop the keys that wait.
    @Test(arguments: [false, true])
    func escapeAndCtrlCBlockAlsoWhileAFinalTextTypes(_ waits: Bool) {
        let t = InputRig()
        t.dictation.waits = waits
        #expect(!t.input.key(ev(.keydown, "a"), dictationKey: nil))
        #expect(!t.input.key(ev(.keydown, "Enter"), dictationKey: nil))
        #expect(t.log == (waits ? [] : [.interrupt, .interrupt]))
        let before = t.log.count
        #expect(!t.input.key(ev(.keydown, "Escape"), dictationKey: nil))
        #expect(!t.input.key(ev(.keydown, "c", Mods(ctrl: true)), dictationKey: nil))
        #expect(Array(t.log.dropFirst(before)) == [.block, .block])
    }

    // The chat input reads the wait before the hold key acts. Here the cancel of the hold makes
    // an older final text wait, and the key still stops the dictation.
    @Test func theChatInputReadsTheWaitBeforeTheHoldKeyActs() async {
        let t = InputRig()
        t.down(" ")
        await t.advance(holdMs)
        t.dictation.waitsAfterCancel = true
        #expect(!t.input.key(ev(.keydown, "a"), dictationKey: KeyCode(.space)))
        #expect(t.log == [.warm, .start, .cancel, .interrupt])
    }

    @Test(arguments: [false, true])
    func inputWithNoKeyDownStopsADictationUnlessAFinalTextTypes(_ waits: Bool) {
        let t = InputRig()
        t.dictation.waits = waits
        t.input.other()
        #expect(t.log == (waits ? [] : [.interrupt]))
    }

    // A mouse wheel with no mouse tracking sends the arrow keys, with no key down. Text and
    // the replies of the terminal go on with no stop.
    @Test(
        arguments: [
            ("\r", false), ("a", false), ("hello", false), ("\u{1B}[I", false),
            ("\u{1B}[12;5R", false), ("\u{1B}[A", true), ("\u{1B}OB", true),
            ("\u{1B}[1;5C", true),
        ])
    func aCursorKeyInTheDataStopsADictationFirst(_ data: String, _ cursor: Bool) {
        let idle = InputRig()
        idle.input.data(data)
        #expect(idle.log == (cursor ? [.interrupt, .input("\(data)")] : [.input("\(data)")]))
        let typing = InputRig()
        typing.dictation.waits = true
        typing.input.data(data)
        #expect(typing.log == [.input("\(data)")])
    }

    // A red box blocks, unless its reason is an escalation or an error. No box, a yellow box
    // and no row block nothing. A block also drops the keys that wait for the typer.
    @Test(
        arguments: [
            (SessionAlert.none, false), (.yellow(since: 1), false), (.red(.error, since: 1), false),
            (.red(.escalated, since: 1), false), (.red(.prompt, since: 1), true),
        ])
    func onlyARedBoxOfAChoiceBlocksDictation(_ alert: SessionAlert, _ blocks: Bool) {
        let t = InputRig()
        t.input.row(blocks: alert.blocksPrompt)
        #expect(t.log == (blocks ? [.block] : []))
    }

    // During a composition, Shift+Enter goes to the input method: no ESC CR, and the terminal
    // gets the key. The key down still stops a dictation.
    @Test func shiftEnterDuringACompositionGoesToTheInputMethod() {
        let t = InputRig()
        let composing = Mods(shift: true, isComposing: true)
        #expect(!t.input.key(ev(.keydown, "Enter", composing), dictationKey: KeyCode(.space)))
        #expect(!t.input.key(ev(.keyup, "Enter", composing), dictationKey: KeyCode(.space)))
        #expect(t.log == [.interrupt])
        #expect(t.input.key(ev(.keydown, "Enter", Mods(shift: true)), dictationKey: nil))
        #expect(t.input.key(ev(.keyup, "Enter", Mods(shift: true)), dictationKey: nil))
        #expect(t.log == [.interrupt, .interrupt, .input("\(KeyRoute.newLineText)")])
    }

    @Test func aFocusMakesTheSpeechEngineReadyOnlyWithADictationKey() {
        let t = InputRig()
        t.input.focus(true, dictationKey: nil)
        #expect(t.log.isEmpty)
        t.input.focus(true, dictationKey: KeyCode(.space))
        #expect(t.log == [.warm])
    }
}

// MARK: - The chat input of a chat dictation

@Suite("the chat input of a chat dictation", .testTimeLimit)
@MainActor
struct ChatDictationInputTests {
    private let down = ev(.keydown, " ")
    private let up = ev(.keyup, " ")

    @Test func theDictationKeyStartsAndStopsTheDictationOfTheChat() async {
        let t = DictationRig()
        #expect(t.dictation.chatInput.key(down, dictationKey: KeyCode(.space)))
        #expect(t.service.warms == 1)
        await t.advance(holdMs - 1)
        #expect(t.starts == 0)
        await t.advance(1)
        #expect(t.starts == 1)
        t.dictation.event(.level(0.4))
        t.dictation.event(.text(final: "", volatile: "Hi"))
        #expect(t.phase == .listening)
        #expect(t.dictation.chatInput.key(up, dictationKey: KeyCode(.space)))
        #expect(t.stops == 1)
        #expect(t.phase == .stopping)
        t.dictation.event(.end(final: "Hi there"))
        await t.advance(1000)
        #expect(t.prompt.exact == "Hi there".exact)
    }

    // A chat that blocks dictation (no attach, the agent view, a choice of Claude) and a closed
    // chat make the dictation key a normal key.
    @Test func aBlockedOrClosedChatMakesTheDictationKeyANormalKey() async {
        let t = DictationRig()
        t.chat.blocksDictation = true
        #expect(!t.dictation.chatInput.key(down, dictationKey: KeyCode(.space)))
        await t.advance(1000)
        #expect(t.starts == 0)
        t.chat.blocksDictation = false
        t.dictation.dispose()
        #expect(!t.dictation.chatInput.key(down, dictationKey: KeyCode(.space)))
        await t.advance(1000)
        #expect(t.starts == 0)
        // A closed chat makes the speech engine ready no more.
        t.dictation.chatInput.focus(true, dictationKey: KeyCode(.space))
        #expect(t.service.warms == 0)
    }

    // The chat closes during a hold: the dictation stops one time, and the key types nothing.
    @Test func aCloseDuringAHoldStopsTheDictationOneTime() async {
        let t = DictationRig()
        #expect(t.dictation.chatInput.key(down, dictationKey: KeyCode(.space)))
        await t.advance(holdMs)
        t.dictation.event(.level(0.4))
        t.dictation.dispose()
        #expect(t.stops == 1)
        #expect(t.phase == .off)
        let wait = DictationRig()
        #expect(wait.dictation.chatInput.key(down, dictationKey: KeyCode(.space)))
        wait.dictation.dispose()
        #expect(wait.dictation.chatInput.holdTimer == nil)
        await wait.advance(1000)
        #expect(wait.starts == 0)
        #expect(wait.prompt.isEmpty)
    }
}
