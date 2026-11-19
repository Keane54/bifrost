// The link opener: only the action of the last click runs. The fake lookup of Launch Services
// waits for a gate, the time limit runs on a manual clock, and the fake open only records the
// action. No test asks Launch Services, opens a link or starts an app.
import BifrostTestSupport
import Foundation
import Testing

@testable import BifrostChat

// Launch Services with an answer only after the test opens the gate: the editor opens each file.
nonisolated struct GatedApps: DefaultApps {
    static let editor = AppFacts(
        url: URL(filePath: "/Applications/Editor.app", directoryHint: .isDirectory),
        bundleID: "dev.example.editor")
    let gate: TestGate

    func opener(of file: FileFacts) -> OpenerFacts {
        gate.passBlocking()
        return OpenerFacts(
            app: Self.editor, typeApp: Self.editor.url, terminalIDs: ["com.apple.Terminal"])
    }
}

@MainActor
@Suite("link opener", .timeLimit(.minutes(1)), .tags(.window))
struct LinkOpenerTests {
    private let web = "https://example.com/newer"

    // The user clicks a web link while the action of a file link is not ready. The web link
    // opens. The late action of the file link opens nothing: an answer of Launch Services, and
    // also the end of the time limit.
    @Test func aLateActionAfterANewerClickOpensNothing() async throws {
        let folder = try TemporaryFolder(short: true)
        defer { folder.remove() }
        try Data("notes\n".utf8).write(to: URL(filePath: folder.appending("notes.txt")))
        let gate = TestGate()
        defer { gate.openAll() }
        let clock = ManualClock()
        var opened: [LinkAction] = []
        let links = LinkOpener(apps: GatedApps(gate: gate), clock: clock) { opened.append($0) }
        let file = "file://\(folder.path)/notes.txt"
        let webAction = LinkAction.openWeb(try #require(URL(string: web)))

        let answered = links.click(file)
        await clock.waitForSleepers(1)
        await links.click(web).value
        #expect(opened == [webAction])
        gate.open()
        await answered.value
        #expect(opened == [webAction])
        #expect(clock.sleeperCount == 0)

        let timedOut = links.click(file)
        await clock.waitForSleepers(1)
        await links.click(web).value
        clock.advance(by: LinkRules.openerTimeLimit)
        await timedOut.value
        #expect(opened == [webAction, webAction])
    }

    // With no newer click, the action of a click runs: the file opens in the app that the rules
    // checked, and after the time limit Finder shows the file.
    @Test func theActionOfTheLastClickRuns() async throws {
        let folder = try TemporaryFolder(short: true)
        defer { folder.remove() }
        try Data("notes\n".utf8).write(to: URL(filePath: folder.appending("notes.txt")))
        let real = "/private\(folder.path)/notes.txt"
        let gate = TestGate()
        defer { gate.openAll() }
        let clock = ManualClock()
        var opened: [LinkAction] = []
        let links = LinkOpener(apps: GatedApps(gate: gate), clock: clock) { opened.append($0) }
        let file = "file://\(folder.path)/notes.txt"

        let answered = links.click(file)
        await clock.waitForSleepers(1)
        gate.open()
        await answered.value
        #expect(opened == [.openFile(real, app: GatedApps.editor.url)])

        let timedOut = links.click(file)
        await clock.waitForSleepers(1)
        clock.advance(by: LinkRules.openerTimeLimit)
        await timedOut.value
        #expect(opened == [.openFile(real, app: GatedApps.editor.url), .showInFinder(real)])
    }
}
