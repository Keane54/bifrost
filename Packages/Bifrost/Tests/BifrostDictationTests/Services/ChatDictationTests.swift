// The dictation of a chat: the hold, the events of the service, the typer, the keys that wait
// and the notices. DictationRig gives the events at once, records the PTY and the calls to the
// service, and moves a manual clock. The last suite runs the real service with the fake engine.
import BifrostKeyboard
import BifrostTestSupport
import Testing

@testable import BifrostDictation

private let ready = DictationViewEvent.ready(language: "en-US", fallback: false)
private let languageReady = DictationViewEvent.ready(language: "en-US", fallback: true)
private let level = DictationViewEvent.level(0.3)
private let long = String(repeating: "abcd ", count: 200).dropLast().description
private let micDenied = "Bifrost can't use the microphone. Allow it in System Settings."

private func text(_ final: String, _ volatile: String = "") -> DictationViewEvent {
    .text(final: final, volatile: volatile)
}

private func end(_ final: String) -> DictationViewEvent { .end(final: final) }

private func ms(_ duration: Duration) -> Int { Int(duration / .milliseconds(1)) }

@Suite("the dictation of a chat", .timeLimit(.minutes(1)))
@MainActor
struct ChatDictationTests {
    // The times of docs/behaviour/dictation.md: the key wait, the close wait and the notice.
    @Test func theTimesAreTheTimesOfTheBehaviourList() {
        #expect(ChatDictation.keyWait == .seconds(2))
        #expect(ChatDictation.closeWait == .seconds(3))
        #expect(ChatDictation.noticeTime == .seconds(6))
    }

    @Test func aHoldTypesTheLiveTextAndTheFinalTextAtTheRelease() async {
        let t = DictationRig()
        t.dictation.start()
        // The vim mode read runs first.
        #expect(t.starts == 0)
        await t.settled()
        #expect(t.starts == 1)
        #expect(t.phase == .starting)
        // The ready of the service opens no microphone. The first level shows that it is open.
        t.dictation.event(ready)
        #expect(t.phase == .starting)
        t.dictation.event(.level(0.5))
        #expect(t.phase == .listening)
        t.dictation.event(text("Hello", " wor"))
        #expect(t.prompt.exact == "Hello wor".exact)
        t.dictation.stop()
        #expect(t.stops == 1)
        #expect(t.phase == .stopping)
        t.dictation.event(end("Hello world."))
        await t.advance(1000)
        #expect(t.prompt.exact == "Hello world.".exact)
        #expect(t.phase == .off)
    }

    @Test func vimModeKeepsDictationOffAndGivesTheKeyBack() async {
        let t = DictationRig(vim: true)
        await t.holdKey()
        #expect(t.starts == 0)
        #expect(t.prompt.exact == " ".exact)
        #expect(t.phase == .off)
        #expect(t.line?.text == "Dictation doesn't work with Claude's vim mode yet.")
        await t.advance(ms(ChatDictation.noticeTime) - 1)
        #expect(t.line != nil)
        await t.advance(1)
        #expect(t.line == nil)
    }

    @Test func aReleaseBeforeTheVimModeAnswerStartsNothing() async {
        let t = DictationRig(vim: nil)
        t.dictation.start()
        t.dictation.stop()
        await t.answerVim(false)
        #expect(t.starts == 0)
        #expect(t.stops == 0)
        #expect(t.phase == .off)
    }

    @Test func theAnswerOfAnOlderVimModeReadDoesNothing() async {
        let t = DictationRig(vim: nil)
        t.dictation.start()
        await t.settled()
        t.dictation.cancel()
        t.dictation.start()
        await t.answerVim(false)
        #expect(t.starts == 0)
        #expect(!t.dictation.heard)
        await t.answerVim(false)
        #expect(t.starts == 1)
        #expect(t.phase == .starting)
    }

    @Test func aStartWithNoPTYOrNoServiceGivesTheKeyBackWithItsNotice() async {
        let t = DictationRig()
        t.chat.hasPTY = false
        await t.holdKey()
        #expect(t.starts == 0)
        #expect(t.prompt.exact == " ".exact)
        #expect(t.phase == .off)
        #expect(
            t.line?.text
                == "This chat window isn't connected to its session, so dictation can't start.")
        await t.advance(ms(ChatDictation.noticeTime))
        #expect(t.line == nil)
        let none = DictationRig(service: false)
        await none.holdKey()
        #expect(none.prompt.exact == " ".exact)
        #expect(none.phase == .off)
        #expect(
            none.line
                == NoticeLine(
                    text: "Dictation isn't available in this build of Bifrost.",
                    opensSettings: false))
    }

    @Test func anErrorInPlaceOfTheStartGivesTheKeyBackAndLaterEventsDoNothing() async {
        let t = DictationRig()
        await t.holdKey()
        t.dictation.event(.error(.micDenied))
        #expect(t.prompt.exact == " ".exact)
        #expect(t.phase == .off)
        #expect(t.dictation.view.notice == .error(.micDenied))
        t.dictation.event(text("late"))
        t.dictation.event(end("late"))
        await t.advance(1000)
        #expect(t.prompt.exact == " ".exact)
    }

    @Test func anErrorDuringDictationKeepsTheTypedText() async {
        let t = DictationRig()
        await t.listen()
        t.dictation.event(text("Hello"))
        t.dictation.event(.error(.failed))
        t.dictation.event(text("Hello there"))
        t.dictation.stop()
        t.dictation.event(end("Hello there"))
        await t.advance(1000)
        #expect(t.prompt.exact == "Hello".exact)
    }

    // A hold before the good start gives no green look: a release types nothing, and an error
    // gives the key back.
    @Test func beforeTheGoodStartAReleaseTypesNothingAndAnErrorGivesTheKeyBack() async {
        let released = DictationRig()
        await released.hold()
        released.dictation.event(ready)
        #expect(!released.dictation.heard)
        released.dictation.stop()
        // The key (the slow space) goes at once: it waits for no text of this dictation.
        #expect(!released.dictation.waits)
        released.dictation.input(" ")
        #expect(released.prompt.exact == " ".exact)
        released.dictation.event(end("late words"))
        await released.advance(1000)
        released.dictation.input("x")
        #expect(released.prompt.exact == " x".exact)
        let failed = DictationRig()
        await failed.holdKey()
        failed.dictation.event(ready)
        failed.dictation.event(.error(.micDenied))
        #expect(failed.prompt.exact == " ".exact)
        #expect(!failed.chat.views.contains { $0.phase == .listening })
    }

    @Test func heardIsFalseUntilTheFirstLevelOrText() async {
        let t = DictationRig(vim: nil)
        #expect(t.dictation.heard)
        t.dictation.start()
        #expect(!t.dictation.heard)
        await t.answerVim(false)
        #expect(t.phase == .starting)
        #expect(!t.dictation.heard)
        t.dictation.event(ready)
        #expect(!t.dictation.heard)
        t.dictation.event(.level(0.1))
        #expect(t.dictation.heard)
        // A text with no level before it is a good start too.
        let textFirst = DictationRig()
        await textFirst.hold()
        textFirst.dictation.event(ready)
        textFirst.dictation.event(text("Hi"))
        #expect(textFirst.phase == .listening)
        #expect(textFirst.prompt.exact == "Hi".exact)
        // A download, and a blocking choice, make the hold heard: the release types nothing.
        let download = DictationRig()
        await download.hold()
        download.dictation.event(.downloading(progress: 0.2))
        #expect(download.dictation.heard)
        let blocked = DictationRig()
        await blocked.hold()
        blocked.dictation.block()
        #expect(blocked.dictation.heard)
    }

    @Test func aHoldDuringADownloadShowsTheDownloadAndNeverListens() async {
        let t = DictationRig()
        await t.hold()
        t.dictation.event(.downloading(progress: 0))
        t.dictation.event(.downloading(progress: 0.4))
        #expect(t.dictation.view.phase == .downloading(progress: 0.4))
        t.dictation.stop()
        t.dictation.event(end("words"))
        await t.advance(1000)
        #expect(t.prompt.isEmpty)
        #expect(!t.chat.views.contains { $0.phase == .listening })
        // A new hold after the download opens the microphone.
        await t.listen()
        #expect(t.phase == .listening)
        // A ready after the progress listens at the first text.
        let after = DictationRig()
        await after.hold()
        after.dictation.event(.downloading(progress: 0.9))
        after.dictation.event(ready)
        after.dictation.event(text("Hi"))
        #expect(after.phase == .listening)
        #expect(after.prompt.exact == "Hi".exact)
    }

    @Test func anEventWithNoDictationDoesNothing() async {
        let t = DictationRig()
        t.dictation.event(ready)
        t.dictation.event(text("stray"))
        t.dictation.event(end("stray"))
        await t.advance(1000)
        #expect(t.prompt.isEmpty)
        #expect(t.phase == .off)
    }
}

@Suite("an early stop of a dictation", .timeLimit(.minutes(1)))
@MainActor
struct EarlyStopTests {
    @Test func aCancelKeepsTheTypedTextAndTheEndTypesNothing() async {
        let t = DictationRig()
        await t.listen()
        t.dictation.event(text("Hello", " wor"))
        t.dictation.cancel()
        #expect(t.stops == 1)
        #expect(t.phase == .off)
        t.dictation.event(text("Hello world"))
        t.dictation.event(end("Hello world."))
        await t.advance(1000)
        #expect(t.prompt.exact == "Hello wor".exact)
    }

    @Test func anInterruptAfterTheReleaseKeepsTheFinalText() async {
        let t = DictationRig()
        await t.listen()
        t.dictation.event(text("Hello"))
        t.dictation.stop()
        t.dictation.interrupt()
        t.dictation.input("!")
        t.dictation.event(end("Hello there."))
        await t.advance(1000)
        #expect(t.prompt.exact == "Hello there.!".exact)
    }

    @Test func aBlockStopsTheTyperAtOnce() async {
        let t = DictationRig()
        await t.listen()
        t.dictation.stop()
        t.dictation.event(end(String(repeating: "Pick 1. ", count: 40)))
        #expect(t.chat.writes.count == 1)
        t.dictation.block()
        await t.advance(1000)
        #expect(t.chat.writes.count == 1)
    }

    // An end that answers no release of this chat, for example at the 2-minute limit, types
    // nothing. A stop closes the microphone, in case the end was a late end of an older
    // dictation.
    @Test func anEndWithNoReleaseTypesNothingAndStopsTheService() async {
        let t = DictationRig()
        await t.listen()
        t.dictation.event(text("Hello", " wor"))
        t.dictation.event(end("Hello world."))
        await t.advance(1000)
        #expect(t.prompt.exact == "Hello wor".exact)
        #expect(t.phase == .off)
        #expect(t.stops == 1)
        t.dictation.stop()
        #expect(t.stops == 1)
    }

    // The chat closes during a hold: the service gets the stop, the look goes, the typed text
    // stays, and nothing acts after it.
    @Test func aDisposeStopsTheHoldAndActsOnNothingAfter() async {
        let t = DictationRig()
        await t.listen()
        t.dictation.event(text("Hello"))
        let views = t.chat.views.count
        t.dictation.dispose()
        #expect(t.stops == 1)
        #expect(t.chat.looks.last == .some(nil))
        t.dictation.event(text("Hello there"))
        t.dictation.event(end("Hello there"))
        t.dictation.start()
        await t.advance(1000)
        #expect(t.prompt.exact == "Hello".exact)
        #expect(t.starts == 1)
        #expect(t.chat.views.count == views)
        // After the release, the final text and the keys that wait stop too.
        let released = DictationRig()
        await released.finishing(long)
        released.dictation.input("x")
        // The gap timer of the typer sleeps. The dispose stops it.
        await released.clock.waitForSleepers(1)
        released.dictation.dispose()
        #expect(released.clock.sleeperCount == 0)
        let writes = released.chat.writes.count
        released.dictation.stop()
        released.dictation.interrupt()
        released.dictation.block()
        released.dictation.input("y")
        await released.advance(3000)
        #expect(released.chat.writes.count == writes)
        #expect(!released.dictation.waits)
    }
}

@Suite("the keys during a final text", .timeLimit(.minutes(1)))
@MainActor
struct KeysDuringAFinalTextTests {
    @Test func keysWaitForTheFinalTextAndGoInTheirOrder() async {
        let t = DictationRig()
        await t.finishing(long)
        #expect(t.dictation.waits)
        t.dictation.input("x")
        t.dictation.input(" ")
        t.dictation.input("y")
        #expect(!t.prompt.hasSuffix("x"))
        await t.advance(1500)
        #expect(t.prompt.exact == "\(long)x y".exact)
        #expect(!t.dictation.waits)
    }

    @Test func aKeyAfterTheReleaseWaitsForTheEnd() async {
        let t = DictationRig()
        await t.listen()
        t.dictation.event(text("Hello", " wor"))
        t.dictation.stop()
        #expect(t.dictation.waits)
        t.dictation.input(".")
        await t.advance(500)
        t.dictation.event(end("Hello world"))
        await t.advance(500)
        #expect(t.prompt.exact == "Hello world.".exact)
    }

    @Test func theKeysGoAfterTheKeyWaitAndALateEndTypesNothing() async {
        let t = DictationRig()
        await t.listen()
        t.dictation.event(text("Hi"))
        t.dictation.stop()
        t.dictation.input("x")
        await t.advance(ms(ChatDictation.keyWait) - 1)
        #expect(t.prompt.exact == "Hi".exact)
        await t.advance(1)
        #expect(t.prompt.exact == "Hix".exact)
        t.dictation.event(end("Hi there"))
        await t.advance(1000)
        #expect(t.prompt.exact == "Hix".exact)
        // A key that comes after the key wait goes at once.
        let late = DictationRig()
        await late.listen()
        late.dictation.event(text("Hi"))
        late.dictation.stop()
        await late.advance(ms(ChatDictation.keyWait))
        late.dictation.input("x")
        #expect(late.prompt.exact == "Hix".exact)
        // With no key that waits, an end after the key wait still types.
        let slow = DictationRig()
        await slow.listen()
        slow.dictation.event(text("Hi"))
        slow.dictation.stop()
        await slow.advance(ms(ChatDictation.keyWait) + 500)
        slow.dictation.event(end("Hi there"))
        await slow.advance(100)
        #expect(slow.prompt.exact == "Hi there".exact)
    }

    @Test func theFinalTextTypesBeforeTheKeys() async {
        let t = DictationRig()
        await t.listen()
        t.dictation.stop()
        t.dictation.input("x")
        t.dictation.input("\r")
        t.dictation.event(end("yes"))
        await t.advance(500)
        #expect(t.prompt.exact == "yesx\r".exact)
        // Also when the final text waits for the typer of an older dictation.
        let older = DictationRig()
        await older.finishing(long)
        await older.listen()
        older.dictation.event(text("Hi"))
        older.dictation.stop()
        older.dictation.input("x")
        older.dictation.input("\r")
        older.dictation.event(end("Hi there"))
        await older.advance(3000)
        #expect(older.prompt.exact == "\(long) Hi therex\r".exact)
    }

    @Test func aLongFinalTextThatComesLateTypesFirst() async {
        let t = DictationRig()
        await t.listen()
        t.dictation.event(text("abcd"))
        t.dictation.stop()
        t.dictation.input("\r")
        await t.advance(1900)
        // 2,000 units: 20 writes, so the typer needs about 400 ms, past the key wait.
        let final = String(repeating: "abcd ", count: 400).dropLast().description
        t.dictation.event(end(final))
        await t.advance(2000)
        #expect(t.prompt.exact == "\(final)\r".exact)
    }

    // A final text that waits for the gap of a stopped typer holds the keys of its dictation.
    @Test func aFinalTextThatWaitsForAGapHoldsTheKeys() async {
        let t = DictationRig()
        await t.listen()
        t.dictation.event(text("abc"))
        t.dictation.cancel()
        t.dictation.event(end(""))
        await t.listen()
        t.dictation.stop()
        t.dictation.input("x")
        t.dictation.event(end("yes"))
        await t.advance(100)
        #expect(t.prompt.exact == "abc yesx".exact)
    }

    // Escape and Ctrl+C stop each typer at once and drop the keys that wait. The
    // key itself goes.
    @Test(arguments: [("Escape", "\u{1B}", false), ("c", "\u{3}", true)])
    func escapeAndCtrlCStopEachTyperAndDropTheKeys(key: String, data: String, ctrl: Bool) async {
        let t = DictationRig()
        await t.finishing(long)
        t.press("x", "x")
        t.press("Enter", "\r")
        let before = t.prompt
        #expect(before.count < long.count)
        t.press(key, data, ctrl: ctrl)
        #expect(t.prompt.exact == "\(before)\(data)".exact)
        await t.advance(1500)
        #expect(t.prompt.exact == "\(before)\(data)".exact)
    }

    @Test func escapeDuringANewHoldStopsItAndTheOlderTyper() async {
        let t = DictationRig()
        await t.finishing(long)
        t.press("Enter", "\r")
        await t.listen()
        let before = t.prompt
        t.press("Escape", "\u{1B}")
        #expect(t.phase == .off)
        #expect(t.stops == 2)
        #expect(t.prompt.exact == "\(before)\u{1B}".exact)
        await t.advance(1500)
        #expect(t.prompt.exact == "\(before)\u{1B}".exact)
    }

    // A key or a click during a new hold stops only that hold. The older final text still
    // types, and the input waits for it.
    @Test func otherInputDuringANewHoldStopsOnlyThatHold() async {
        let t = DictationRig()
        await t.listen()
        t.dictation.event(text("abcd"))
        t.dictation.stop()
        t.press("Enter", "\r")
        t.dictation.event(end(long))
        await t.listen()
        #expect(t.phase == .listening)
        t.press("x", "x")
        #expect(t.phase == .off)
        #expect(!t.prompt.unicodeScalars.contains("\r"))
        await t.advance(1500)
        #expect(t.prompt.exact == "\(long)\rx".exact)
        let click = DictationRig()
        await click.finishing(long)
        click.press("Enter", "\r")
        await click.listen()
        click.dictation.event(text("Next"))
        click.other()
        #expect(click.phase == .off)
        #expect(!click.prompt.unicodeScalars.contains("\r"))
        await click.advance(1500)
        #expect(click.prompt.exact == "\(long)\r".exact)
    }

    @Test func aCursorKeyOfAMouseWheelStopsALiveDictationBeforeItGoes() async {
        let t = DictationRig()
        await t.listen()
        t.dictation.event(text("Hello", " wor"))
        t.data("\u{1B}[A")
        #expect(t.phase == .off)
        #expect(t.prompt.exact == "Hello wor\u{1B}[A".exact)
        // The next text of the service types nothing, so no DEL can remove other text.
        t.dictation.event(text("Hello world"))
        t.dictation.event(end("Hello world."))
        await t.advance(1000)
        #expect(t.prompt.exact == "Hello wor\u{1B}[A".exact)
    }

    @Test func aClickAndItsPasteWaitForTheFinalText() async {
        let t = DictationRig()
        await t.finishing(long)
        t.other()
        t.dictation.input("pasted")
        #expect(!t.prompt.contains("pasted"))
        await t.advance(1500)
        #expect(t.prompt.exact == "\(long)pasted".exact)
        // A click before the end of the release.
        let beforeEnd = DictationRig()
        await beforeEnd.listen()
        beforeEnd.dictation.event(text("Hello"))
        beforeEnd.dictation.stop()
        beforeEnd.other()
        beforeEnd.dictation.input("/tmp/a.png")
        beforeEnd.dictation.event(end("Hello there."))
        await beforeEnd.advance(1000)
        #expect(beforeEnd.prompt.exact == "Hello there./tmp/a.png".exact)
        // A click during a new hold before its good start stops that hold.
        let early = DictationRig()
        await early.finishing(long)
        await early.hold()
        #expect(early.phase == .starting)
        #expect(!early.dictation.waits)
        early.other()
        #expect(early.phase == .off)
        #expect(early.stops == 2)
        early.dictation.input("x")
        await early.advance(1500)
        #expect(early.prompt.exact == "\(long)x".exact)
    }

    @Test func aBlockDropsTheKeysThatWait() async {
        let t = DictationRig()
        await t.finishing(long)
        t.dictation.input("1")
        let before = t.prompt
        t.dictation.block()
        await t.advance(1500)
        #expect(t.prompt.exact == before.exact)
    }

    @Test func nothingWaitsWithNoFinalTextOrDuringAHold() async {
        let t = DictationRig()
        #expect(!t.dictation.waits)
        t.dictation.input("a")
        #expect(t.prompt.exact == "a".exact)
        await t.listen()
        #expect(!t.dictation.waits)
    }

    @Test func aKeyFromBeforeADictationTypesBeforeItsText() async {
        let t = DictationRig()
        await t.finishing(long)
        t.dictation.input("x")
        await t.listen()
        t.dictation.event(text("Next"))
        await t.advance(2000)
        #expect(t.prompt.exact == "\(long)x Next".exact)
    }
}

@Suite("one dictation at a time", .timeLimit(.minutes(1)))
@MainActor
struct OneDictationAtATimeTests {
    @Test func aHoldAfterAnEarlyStopWaitsForItsEnd() async {
        let t = DictationRig()
        await t.listen()
        t.dictation.event(text("One"))
        t.dictation.cancel()
        await t.hold()
        #expect(t.starts == 1)
        // The late end of the first dictation types nothing.
        t.dictation.event(end("One two"))
        await t.settled()
        #expect(t.starts == 2)
        t.dictation.event(ready)
        t.dictation.event(text("Three"))
        await t.advance(1000)
        #expect(t.prompt.exact == "One Three".exact)
    }

    @Test func aHoldAfterAReleaseWaitsForTheEndAndTypesItFirst() async {
        let t = DictationRig()
        await t.listen()
        t.dictation.event(text("One"))
        t.dictation.stop()
        await t.hold()
        #expect(t.starts == 1)
        t.dictation.event(end("One."))
        await t.settled()
        #expect(t.starts == 2)
        t.dictation.event(ready)
        t.dictation.event(text("Two"))
        await t.advance(1000)
        #expect(t.prompt.exact == "One. Two".exact)
    }

    @Test func theWaitForAnEndStopsAfterTheCloseWait() async {
        let t = DictationRig()
        await t.listen()
        t.dictation.cancel()
        await t.hold()
        await t.advance(ms(ChatDictation.closeWait) - 1)
        #expect(t.starts == 1)
        await t.advance(1)
        #expect(t.starts == 2)
    }

    @Test func aReleaseDropsAHoldThatWaits() async {
        let t = DictationRig()
        await t.listen()
        t.dictation.cancel()
        await t.hold()
        t.dictation.stop()
        t.dictation.event(end(""))
        await t.settled()
        #expect(t.starts == 1)
        // Also while the hold waits for the turn of a final text.
        let waiting = DictationRig()
        await waiting.listen()
        waiting.dictation.stop()
        waiting.dictation.event(end(String(repeating: "abcd ", count: 100)))
        await waiting.listen()
        waiting.dictation.stop()
        await waiting.hold()
        waiting.dictation.event(end("Hello"))
        waiting.dictation.stop()
        await waiting.advance(1000)
        #expect(waiting.starts == 2)
        #expect(waiting.prompt.hasSuffix(" Hello"))
    }

    // A new typer writes only after the typer before it and its gap.
    @Test func aNewTyperWritesAfterTheLastTyperAndItsGap() async {
        let t = DictationRig()
        await t.listen()
        t.dictation.stop()
        // 500 units: five writes.
        let long = String(repeating: "abcd ", count: 100).dropLast().description
        t.dictation.event(end(long))
        #expect(t.chat.writes.count == 1)
        await t.listen()
        t.dictation.event(text("Next"))
        await t.advance(1000)
        #expect(t.prompt.exact == "\(long) Next".exact)
        let times = t.chat.writes.map(\.at)
        for (a, b) in zip(times, times.dropFirst()) {
            #expect(b - a >= TypingRules.writeGap)
        }
    }

    // A hold that waits for the end of the last dictation also waits for the first write of its
    // final text. The final text of the dictation before it still types.
    @Test func aHoldThatWaitsStartsAtTheFirstWriteOfTheFinalText() async {
        let t = DictationRig()
        let long = String(repeating: "abcd ", count: 100).dropLast().description
        await t.listen()
        t.dictation.stop()
        t.dictation.event(end(long))
        // The second dictation hears no text.
        await t.listen()
        t.dictation.stop()
        await t.hold()
        t.dictation.event(end("Hello"))
        await t.settled()
        #expect(t.starts == 2)
        await t.advance(1000)
        #expect(t.starts == 3)
        t.dictation.event(ready)
        t.dictation.event(text("World"))
        await t.advance(1000)
        #expect(t.prompt.exact == "\(long) Hello World".exact)
    }

    @Test func aNewHoldLetsTheOlderFinalTextTypeToItsEnd() async {
        let t = DictationRig()
        await t.finishing(long)
        #expect(t.prompt.exact != long.exact)
        await t.hold()
        #expect(t.phase == .starting)
        #expect(t.starts == 2)
        await t.advance(1500)
        #expect(t.prompt.exact == long.exact)
    }
}

@Suite("the notice of a chat", .timeLimit(.minutes(1)))
@MainActor
struct NoticeOfAChatTests {
    // The notice of a denied microphone keeps its button, and it stays until a good start. A
    // ready alone is no good start: the service gives it before the engine tries.
    @Test func aDeniedMicrophoneShowsItsButtonUntilAGoodStart() async {
        let t = DictationRig()
        await t.hold()
        t.dictation.event(ready)
        t.dictation.event(.error(.micDenied))
        #expect(t.line == NoticeLine(text: micDenied, opensSettings: true))
        #expect(t.phase == .off)
        #expect(!t.chat.views.contains { $0.phase == .listening })
        await t.advance(ms(ChatDictation.serviceNoticeTime) * 5)
        #expect(t.line == NoticeLine(text: micDenied, opensSettings: true))
        t.dictation.stop()
        await t.hold()
        t.dictation.event(ready)
        #expect(t.line?.text == micDenied)
        t.dictation.event(level)
        #expect(t.line == nil)
    }

    @Test func theNoticeOfAnEarlierFailureGoesAtTheFirstText() async {
        let t = DictationRig()
        await t.hold()
        t.dictation.event(.error(.failed))
        await t.hold()
        t.dictation.event(ready)
        t.dictation.event(text("", "Hi"))
        #expect(t.line == nil)
        // A new error before the good start replaces the notice.
        let again = DictationRig()
        await again.hold()
        again.dictation.event(.error(.micAsked))
        await again.hold()
        again.dictation.event(ready)
        again.dictation.event(.error(.micDenied))
        #expect(again.line == NoticeLine(text: micDenied, opensSettings: true))
    }

    @Test(arguments: [DictationErrorCode.failed, .noModel, .micAsked, .unavailable])
    func aNoticeOfTheServiceWithNoButtonGoesAfter12Seconds(code: DictationErrorCode) async {
        let t = DictationRig()
        await t.hold()
        t.dictation.event(ready)
        t.dictation.event(.error(code))
        #expect(t.line?.opensSettings == false)
        #expect(ChatDictation.serviceNoticeTime == .seconds(12))
        await t.advance(ms(ChatDictation.serviceNoticeTime) - 1)
        #expect(t.line != nil)
        await t.advance(1)
        #expect(t.line == nil)
    }

    @Test func theLanguageNoticeShowsAtTheFirstLevelOnceForEachChat() async {
        let t = DictationRig()
        await t.hold()
        t.dictation.event(languageReady)
        #expect(t.line == nil)
        t.dictation.event(level)
        #expect(
            t.line?.text == "Your language has no on-device speech model, so Bifrost uses English.")
        t.dictation.event(level)
        await t.advance(ms(ChatDictation.serviceNoticeTime) - 1)
        #expect(t.line != nil)
        await t.advance(1)
        #expect(t.line == nil)
        t.dictation.stop()
        t.dictation.event(end(""))
        await t.hold()
        t.dictation.event(languageReady)
        t.dictation.event(level)
        #expect(t.line == nil)
        // The notice of one dictation goes at the next good start.
        let next = DictationRig()
        await next.hold()
        next.dictation.event(languageReady)
        next.dictation.event(level)
        next.dictation.stop()
        next.dictation.event(end(""))
        #expect(next.line != nil)
        await next.hold()
        next.dictation.event(languageReady)
        next.dictation.event(level)
        #expect(next.line == nil)
    }

    @Test func aHoldDuringADownloadShowsTheProgressThenTheReadyText() async {
        let t = DictationRig()
        await t.hold()
        t.dictation.event(.downloading(progress: 0))
        #expect(t.line?.text == "Getting the speech model ready… 0%")
        t.dictation.event(.downloading(progress: 0.37))
        #expect(t.line?.text == "Getting the speech model ready… 37%")
        t.dictation.event(.modelReady)
        #expect(
            t.line
                == NoticeLine(
                    text: "The speech model is ready. Hold the key to dictate.",
                    opensSettings: false))
        #expect(t.phase != .listening)
        // The microphone stays closed. The release types nothing, and the service gets one stop.
        t.dictation.stop()
        #expect(t.stops == 1)
        t.dictation.event(end(""))
        #expect(t.phase == .off)
        #expect(t.prompt.isEmpty)
        await t.advance(ms(ChatDictation.noticeTime))
        #expect(t.line == nil)
    }

    @Test func theFirstProgressRemovesAnOlderNotice() async {
        let t = DictationRig()
        await t.hold()
        t.dictation.event(.error(.noModel))
        await t.hold()
        t.dictation.event(.downloading(progress: 0.1))
        t.dictation.stop()
        t.dictation.event(end(""))
        #expect(t.line == nil)
    }

    @Test func aReadyAfterTheModelReadyKeepsItsTextUntilTheFirstLevel() async {
        let t = DictationRig()
        await t.hold()
        t.dictation.event(.downloading(progress: 0.9))
        t.dictation.event(.modelReady)
        t.dictation.event(ready)
        #expect(t.phase == .downloaded)
        #expect(t.line?.text == "The speech model is ready. Hold the key to dictate.")
        t.dictation.event(level)
        #expect(t.phase == .listening)
        #expect(t.line == nil)
    }
}

@Suite("the writes, the typed tail and the look of a dictation", .timeLimit(.minutes(1)))
@MainActor
struct WritesAndLookTests {
    // A write goes at once. The next write waits the gap, and it has the newest text. After
    // DELs, the gap is longer: 1 ms more for each 2 DELs.
    @Test func writesWaitTheGapAndUseTheNewestText() async {
        let t = DictationRig()
        await t.listen()
        t.dictation.event(text("", "a"))
        t.dictation.event(text("", "ab"))
        t.dictation.event(text("", "abc"))
        #expect(t.chat.writes.map(\.data) == ["a"])
        await t.advance(ms(TypingRules.writeGap) - 1)
        #expect(t.chat.writes.map(\.data) == ["a"])
        await t.advance(1)
        #expect(t.chat.writes.map(\.data) == ["a", "bc"])
        t.dictation.event(text("", "abx"))
        await t.advance(ms(TypingRules.writeGap))
        t.dictation.event(text("", "abx now"))
        // The write of 1 DEL waits 1 ms more.
        await t.advance(ms(TypingRules.writeGap))
        #expect(t.chat.writes.count == 3)
        await t.advance(1)
        #expect(t.chat.writes.map(\.data).exact == ["a", "bc", "\u{7F}x", " now"].exact)
    }

    @Test func aLongDELRunWaitsForItsDELs() async {
        let t = DictationRig()
        t.dictation.input("Keep ")
        await t.listen()
        t.dictation.event(text("", String(repeating: "a", count: 1500)))
        await t.advance(1000)
        t.dictation.stop()
        t.dictation.event(end("b"))
        let before = t.chat.writes.count
        #expect(parts(t.chat.writes[before - 1].data).deletes == 1000)
        await t.advance(ms(TypingRules.gap(afterDeletes: 1000)) - 1)
        #expect(t.chat.writes.count == before)
        await t.advance(1)
        #expect(t.chat.writes.count == before + 1)
        #expect(t.prompt.exact == "Keep b".exact)
    }

    // The leading space of a dictation reads the end of the text that the chat sent to the PTY.
    // A new attach clears it, and a text that did not go adds nothing.
    @Test func theLeadingSpaceReadsTheTextThatTheChatSent() async {
        let t = DictationRig()
        t.dictation.input("Fix")
        await t.listen()
        t.dictation.event(text("", "it"))
        #expect(t.prompt.exact == "Fix it".exact)
        t.dictation.stop()
        t.dictation.event(end("it"))
        t.dictation.clearTypedText()
        await t.advance(100)
        await t.listen()
        t.dictation.event(text("", "now"))
        #expect(t.prompt.exact == "Fix itnow".exact)
        let blocked = DictationRig()
        blocked.chat.takesInput = false
        blocked.dictation.input("Fix")
        blocked.chat.takesInput = true
        await blocked.listen()
        blocked.dictation.event(text("", "it"))
        #expect(blocked.prompt.exact == "it".exact)
    }

    // The look shows the voice level only while the chat listens. The level of an older
    // dictation never shows in a new one, and a close removes the look.
    @Test func theLookShowsTheLevelOnlyWhileTheChatListens() async {
        let t = DictationRig()
        await t.hold()
        t.dictation.event(ready)
        #expect(t.dictation.look == nil)
        t.dictation.event(.level(0.3))
        t.dictation.event(.level(0.6))
        #expect(t.chat.looks == [0.3, 0.6])
        t.dictation.stop()
        t.dictation.event(.level(0.9))
        #expect(t.dictation.look == nil)
        t.dictation.event(end(""))
        await t.hold()
        t.dictation.event(ready)
        t.dictation.event(text("Hi"))
        #expect(t.dictation.look == 0)
        t.dictation.dispose()
        #expect(t.chat.looks == [0.3, 0.6, nil, 0, nil])
    }

    // Seeded random recognizer texts through the whole dictation: no write of the typer has
    // Enter, a line break, a tab, ESC or another control character after its DELs.
    @Test func noWriteOfADictationHasEnterTabOrEscape() async {
        var random = SeededRandom(seed: 11_162_026)
        var failures: [String] = []
        for n in 0..<150 {
            let t = DictationRig()
            await t.listen()
            for _ in 0..<random.int(1...4) {
                t.dictation.event(text("", DictationTyperTests.text(&random)))
            }
            t.dictation.stop()
            t.dictation.event(end(DictationTyperTests.text(&random)))
            await t.advance(5000)
            for write in t.chat.writes where DictationTyperTests.hasForbidden(write.data) {
                failures.append("case \(n): \(write.data.debugDescription)")
            }
        }
        #expect(failures.isEmpty, "\(failures.count) writes: \(failures.prefix(3))")
    }
}

// The dictation of a chat with the real dictation service and the fake engine. The service has
// a manual clock. The chat has the continuous clock, so its gaps pass, and each test waits for
// what it checks.
@MainActor
private final class EngineChat {
    let engine: FakeSpeechEngine
    let service: DictationService
    let chat: RecordedChat
    let dictation: ChatDictation
    private let reader: Task<Void, Never>

    init(_ script: FakeSpeechScript = .helper) {
        engine = FakeSpeechEngine(script: script)
        service = DictationService(engine: engine, clock: ManualClock())
        chat = RecordedChat(clock: ManualClock())
        let dictation = ChatDictation(
            session: DictationRig.session, chat: chat, service: service, clock: ContinuousClock(),
            vimMode: { false })
        self.dictation = dictation
        let events = service.listen(for: DictationRig.session)
        reader = Task {
            for await event in events { dictation.event(event) }
        }
    }

    isolated deinit {
        reader.cancel()
    }

    var closed: Bool { !engine.microphoneOpen && engine.microphoneOpens == engine.microphoneCloses }
}

@Suite("the dictation of a chat with the fake engine", .timeLimit(.minutes(1)))
@MainActor
struct ChatDictationEngineTests {
    private let final = FakeSpeechScript.helperText

    @Test func aHoldTypesTheTextOfTheEngineAndTheReleaseClosesTheMicrophone() async {
        let t = EngineChat()
        t.dictation.start()
        await waitUntil { t.chat.prompt == final && t.dictation.view.phase == .listening }
        #expect(t.engine.microphoneOpen)
        t.dictation.stop()
        await waitUntil { t.dictation.view.phase == .off && t.closed }
        #expect(t.chat.prompt.exact == final.exact)
        #expect(t.engine.microphoneOpens == 1)
        #expect(t.engine.overlaps == 0)
    }

    @Test func aKeyAfterTheReleaseGoesAfterTheFinalTextOfTheEngine() async {
        var script = FakeSpeechScript.helper
        script.events = [.level(0.5), .text(final: "", volatile: "Hello")]
        script.final = "Hello there, the end."
        let t = EngineChat(script)
        t.dictation.start()
        await waitUntil { t.chat.prompt == "Hello" }
        t.dictation.stop()
        t.dictation.input("!")
        await waitUntil { t.chat.prompt == "Hello there, the end.!" }
        await waitUntil { t.closed }
    }

    @Test func anErrorOfTheEngineKeepsTheTextAndClosesTheMicrophone() async {
        let t = EngineChat()
        t.dictation.start()
        await waitUntil { t.chat.prompt == final }
        t.engine.failSession(.failed)
        await waitUntil { t.dictation.view.notice == .error(.failed) }
        #expect(t.dictation.view.phase == .off)
        #expect(t.closed)
        #expect(t.chat.prompt.exact == final.exact)
    }

    @Test func aStartWithNoPTYOpensNoMicrophone() async {
        let t = EngineChat()
        t.chat.hasPTY = false
        let space = KeyEvent(keyCode: KeyCode(.space), characters: " ")
        #expect(t.dictation.chatInput.key(space, dictationKey: KeyCode(.space)))
        await waitUntil { t.chat.prompt == " " }
        #expect(t.engine.microphoneOpens == 0)
    }
}
