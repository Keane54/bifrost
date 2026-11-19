// The rules of the Take control loader (docs/behaviour/chat.md, "The Take control loader"): the
// loader shows while Take control runs, and after a good Take control until the terminal shows
// Claude or the time limit passes.
import Testing

@testable import BifrostChat

private let id = "5a0e0001-0000-4000-8000-000000000001"
private let other = "5a0e0002-0000-4000-8000-000000000002"

@Suite("the Take control loader")
struct TakeControlLoaderTests {
    @Test func theLineNamesTheSessionOrOnlySaysThatTakeControlRuns() {
        #expect(TakeControlLoader.text(name: "smoke-alpha") == "Taking control of smoke-alpha...")
        #expect(TakeControlLoader.text(name: nil) == "Taking control...")
        #expect(TakeControlLoader.text(name: "") == "Taking control...")
        // A hidden character of the name does not reach the line.
        #expect(
            TakeControlLoader.text(name: "fix\u{200B}-a\u{202E}") == "Taking control of fix-a...")
        #expect(TakeControlLoader.text(name: "\u{200B}") == "Taking control...")
    }

    @Test func aStartShowsTheLoaderWhileTakeControlRuns() {
        var loader = TakeControlLoader()
        #expect(!loader.shows(id))
        loader.start(id)
        #expect(loader.shows(id))
        #expect(!loader.waits(id))
        #expect(!loader.shows(other))
        #expect(loader.sessionIds == [id])
    }

    // The loader stays until Take control worked and the terminal shows Claude, in either order.
    @Test func theLoaderStaysUntilTheFinishAndTheTerminalShowsClaude() {
        var finishedFirst = TakeControlLoader()
        finishedFirst.start(id)
        finishedFirst.finish(id)
        #expect(finishedFirst.shows(id))
        #expect(finishedFirst.waits(id))
        finishedFirst.shown(id)
        #expect(!finishedFirst.shows(id))

        var shownFirst = TakeControlLoader()
        shownFirst.start(id)
        shownFirst.shown(id)
        #expect(shownFirst.shows(id))
        #expect(!shownFirst.waits(id))
        shownFirst.finish(id)
        #expect(!shownFirst.shows(id))
    }

    @Test func aStopRemovesTheLoader() {
        var loader = TakeControlLoader()
        loader.start(id)
        loader.stop(id)
        #expect(!loader.shows(id))
        loader.start(id)
        loader.shown(id)
        loader.stop(id)
        #expect(!loader.shows(id))
    }

    // A loader that waits only for the first output has a time limit. Then the window shows the
    // terminal, with its note when it cannot attach.
    @Test func theTimeLimitRemovesALoaderThatWaitsOnlyForTheFirstOutput() {
        var loader = TakeControlLoader()
        loader.start(id)
        loader.finish(id)
        loader.timeLimitPassed(id)
        #expect(!loader.shows(id))
        #expect(TakeControlLoader.timeLimit == .seconds(20))
    }

    @Test func theTimeLimitKeepsALoaderWhileTakeControlRuns() {
        var loader = TakeControlLoader()
        loader.start(id)
        loader.timeLimitPassed(id)
        #expect(loader.shows(id))
        loader.shown(id)
        loader.timeLimitPassed(id)
        #expect(loader.shows(id))
        #expect(!loader.waits(id))
    }

    @Test func aSessionWithNoLoaderStaysWithNoLoader() {
        var loader = TakeControlLoader()
        loader.finish(id)
        loader.shown(id)
        loader.stop(id)
        loader.timeLimitPassed(id)
        #expect(!loader.shows(id))
        #expect(!loader.waits(id))
        #expect(loader == TakeControlLoader())
    }

    // Each session has its own loader.
    @Test func eachSessionHasItsOwnLoader() {
        var loader = TakeControlLoader()
        loader.start(id)
        loader.start(other)
        loader.stop(other)
        #expect(loader.shows(id))
        #expect(!loader.shows(other))
    }
}
