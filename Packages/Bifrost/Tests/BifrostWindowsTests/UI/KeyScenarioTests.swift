import AppKit
import BifrostTestSupport
import Testing

@testable import BifrostWindows

// The 318 scenarios of the key-rules gate through the window key filter of the app (the section
// "How state flows" of the architecture design). Each scenario has its own window, and the window
// is never ordered front. The scenarios and their expected results are the data file
// Scenarios/key-scenarios.json. The two negative controls of the gate break one rule each, and an
// exact count of the scenarios must then fail. The suite runs serialized.
@Suite("key scenarios", .serialized, .timeLimit(.minutes(5)), .tags(.window))
@MainActor
struct KeyScenarioTests {
    @Test func theFileHas318UniqueScenarios() {
        #expect(KeyScenarios.all.count == 318)
        #expect(Set(KeyScenarios.all.map(\.id)).count == 318)
    }

    // Two scenarios have a result that differs from the old app. The user accepted both changes
    // (docs/behaviour/keys.md). The first: Shift+Enter during a composition goes to the
    // input method, so the terminal gets no ESC CR. The second: a hold key goes from the hold
    // gate at each key up, so a stale hold key does not turn a row click into a hold command.
    @Test func theTwoAcceptedChangesStayInTheData() throws {
        let composing = try #require(KeyScenarios.all.first { $0.id == "shift-enter/composing" })
        #expect(composing.expect.log == ["dict:interrupt"])
        #expect(composing.expect.pty.isEmpty)
        let rollover = try #require(KeyScenarios.all.first { $0.id == "hold-gate/rollover-stale" })
        #expect(rollover.expect.log == ["cmd:open-project:key", "click:S2"])
        #expect(rollover.expect.pty.isEmpty)
    }

    // The terminal sends text for a key, so the PTY checks of the scenarios compare real text.
    @Test func theTerminalOfTheChatSendsTheTextOfAKey() throws {
        let setup = try JSONDecoder().decode(
            Scenario.Setup.self, from: Data(#"{"view": "chat"}"#.utf8))
        let run = ScenarioRun(setup: setup, options: ScenarioOptions())
        defer { run.close() }
        let keys: Set<Scenario.Term> = [
            Scenario.Term(key: "a", mods: [], isRepeat: false),
            Scenario.Term(key: "Enter", mods: [], isRepeat: false),
            Scenario.Term(key: "ArrowUp", mods: [], isRepeat: false),
        ]
        let text = run.calibrate(keys)
        #expect(text[Scenario.Term(key: "a", mods: [], isRepeat: false)] == Array("a".utf8))
        #expect(text[Scenario.Term(key: "Enter", mods: [], isRepeat: false)] == [0x0D])
        let up = text[Scenario.Term(key: "ArrowUp", mods: [], isRepeat: false)] ?? []
        #expect(up == Array("\u{1b}[A".utf8) || up == Array("\u{1b}OA".utf8))
    }

    @Test(arguments: KeyScenarios.all)
    func all318ScenariosPass(_ scenario: Scenario) async {
        let run = ScenarioRun(setup: scenario.setup, options: ScenarioOptions())
        let result = await run.run(scenario)
        run.close()
        #expect(result.pass, "\(result.summary)")
    }

    // The filter does not see the events. The 75 scenarios that still pass are the keys that
    // Bifrost leaves alone: the text boxes, the dialogs and the menu slots.
    @Test func theBypassControlFails243Scenarios() async {
        let results = await runScenarios(KeyScenarios.all, options: ScenarioOptions(bypass: true))
        #expect(results.count == 318)
        let failed = results.filter { !$0.pass }
        #expect(failed.count == 243, "passed: \(results.filter(\.pass).map(\.id))")
    }

    // A hold time of 100 ms in place of 250 ms: the taps of 100 to 150 ms become holds. Four of
    // the five taps last 100 ms exactly. On the manual clock a key that stays down for the hold
    // time is a hold, so all five fail each time. The gate ran on the real clock: there the
    // timer and the next step of a 100 ms tap came in a random order, and the gate got 4.
    @Test func aHoldOf100msFails5Scenarios() async {
        let results = await runScenarios(
            KeyScenarios.all, options: ScenarioOptions(holdTime: .milliseconds(100)))
        #expect(results.count == 318)
        let failed = results.filter { !$0.pass }.map(\.id)
        #expect(
            failed == [
                "slot/dictation:hold/chat-tap", "dictation/tap-249", "dictation/rollover",
                "dictation/blur-in-wait", "dictation/close-in-wait",
            ])
    }
}
