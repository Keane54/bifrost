// The driver of the key scenarios. It runs each scenario of key-scenarios.json with synthetic
// NSEvents through a BifrostWindow and the WindowKeyFilter of the app, and compares the log and
// the terminal text with the expected result of the scenario. The file is the data of this
// repository. Each scenario names a behaviour of the key rules and gives its expected result.
//
// The driver gives each key event to the window the way NSApplication.sendEvent does: a key
// down with Cmd goes to the key equivalents first (the views, then the menu of the app), then to
// NSWindow.sendEvent. A key up with Cmd held does not come, because macOS sends none.
//
// Each scenario has its own window, filter, chat and clock. The window is never ordered front.
// A wait step moves the manual clock of the hold timer, so the times of the fixture stay exact
// when the host is busy.
import AppKit
import BifrostSessions
import BifrostTestSupport
import Foundation
import SwiftTerm
import Testing

@testable import BifrostDictation
@testable import BifrostFoundation
@testable import BifrostKeyboard
@testable import BifrostLayout
@testable import BifrostWindows

// MARK: - The scenario file

nonisolated struct Scenario: Decodable, Sendable, CustomTestStringConvertible {
    nonisolated struct Setup: Decodable, Sendable {
        var view: String
        var custom: [String: String?]
        var blocked: Bool
        var heard: Bool
        var waits: Bool
        var settingsOnTop: Bool
        var escTaker: Bool
        // The selected row. The file gives null for no selection, and no field for S2.
        var selected: String?

        enum CodingKeys: String, CodingKey {
            case view, custom, blocked, heard, waits, settingsOnTop, escTaker, selected
        }

        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            view = try c.decodeIfPresent(String.self, forKey: .view) ?? "window"
            custom = try c.decodeIfPresent([String: String?].self, forKey: .custom) ?? [:]
            blocked = try c.decodeIfPresent(Bool.self, forKey: .blocked) ?? false
            heard = try c.decodeIfPresent(Bool.self, forKey: .heard) ?? true
            waits = try c.decodeIfPresent(Bool.self, forKey: .waits) ?? false
            settingsOnTop = try c.decodeIfPresent(Bool.self, forKey: .settingsOnTop) ?? false
            escTaker = try c.decodeIfPresent(Bool.self, forKey: .escTaker) ?? false
            selected =
                c.contains(.selected)
                ? try c.decodeIfPresent(String.self, forKey: .selected) : "S2"
        }
    }

    nonisolated struct Step: Decodable, Sendable {
        var action: String
        var key: String?
        var mods: [String]?
        var isRepeat: Bool?
        var ms: Int?
        var view: String?
        var row: String?
        var box: String?
        var reason: String?
        var on: Bool?
        var blocked: Bool?
        var heard: Bool?
        var waits: Bool?
        var escTaker: Bool?

        enum CodingKeys: String, CodingKey {
            case action = "do"
            case isRepeat = "repeat"
            case key, mods, ms, view, row, box, reason, on, blocked, heard, waits, escTaker
        }
    }

    nonisolated struct Term: Decodable, Sendable, Hashable {
        var key: String
        var mods: [String]
        var isRepeat: Bool

        enum CodingKeys: String, CodingKey {
            case key, mods
            case isRepeat = "repeat"
        }
    }

    nonisolated struct PtyPart: Decodable, Sendable {
        var text: String?
        var term: Term?
    }

    nonisolated struct Expect: Decodable, Sendable {
        var log: [String]
        var pty: [PtyPart]
    }

    var id: String
    var group: String
    var keys: String
    var rule: String
    var setup: Setup
    var steps: [Step]
    var expect: Expect
    var pty: String

    var testDescription: String { id }
}

nonisolated enum KeyScenarios {
    // The file of the scenarios: a resource of the test target (the folder UI/Scenarios).
    static let fixture = Bundle.module.url(
        forResource: "key-scenarios", withExtension: "json", subdirectory: "Scenarios")

    // The scenarios of the file, or no scenarios when the file does not load. The count test
    // then fails.
    static let all: [Scenario] = {
        guard let fixture, let data = try? Data(contentsOf: fixture) else { return [] }
        return (try? JSONDecoder().decode([Scenario].self, from: data)) ?? []
    }()
}

// MARK: - The state

// The state that the app keeps in other places: the dictation session and the Settings panel.
// The scenario keeps it here, and logs each action.
@MainActor
final class GateState {
    private(set) var log: [String] = []
    private(set) var pty: [UInt8] = []
    var logging = false
    var blocked = false
    var heard = true
    var waits = false
    var settingsOnTop = false
    var escTaker = false

    func record(_ line: String) {
        if logging { log.append(line) }
    }

    func recordPty(_ bytes: [UInt8]) {
        if logging { pty.append(contentsOf: bytes) }
    }

    func reset() {
        log = []
        pty = []
    }
}

// The options of a negative control run. They break one rule on purpose, so the run shows that
// the scenarios find a broken rule.
@MainActor
struct ScenarioOptions {
    // The filter does not see the events (--bypass of the gate).
    var bypass = false
    // The hold time of the dictation key (--hold-ms of the gate).
    var holdTime = ChatInput.holdTime
}

@MainActor
struct ScenarioResult {
    let id: String
    let expectedLog: [String]
    let actualLog: [String]
    let expectedPty: [UInt8]
    let actualPty: [UInt8]
    let checkPty: Bool

    var pass: Bool { expectedLog == actualLog && (!checkPty || expectedPty == actualPty) }

    var summary: String {
        "\(id): log \(actualLog) (expected \(expectedLog)), PTY \(escaped(actualPty)) "
            + "(expected \(escaped(expectedPty)))"
    }
}

// MARK: - One run

@MainActor
final class ScenarioRun {
    let state: GateState
    let selection: SelectionModel
    let clock: ManualClock
    let window: BifrostWindow
    let terminal: TerminalHost
    let rows: RowsView
    let filter: WindowKeyFilter
    // The filter of the bypass control, or nil.
    private var bypass: BypassFilter?
    private let views: [String: NSView]
    private let menu: NSMenu
    private let menuLog: MenuLog
    private var held: Set<USKeyboard.Mod> = []

    init(setup: Scenario.Setup, options: ScenarioOptions) {
        UITestApp.prepare()
        let state = GateState()
        let rowSource = FakeRowSource()
        let selection = SelectionModel(list: .reading(rowSource))
        let clock = ManualClock()
        self.state = state
        self.selection = selection
        self.clock = clock
        window = SnapshotBifrostWindow(
            contentRect: NSRect(x: 80, y: 80, width: 780, height: 560), styleMask: [.titled],
            backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.actsAsKey = true
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 780, height: 560))
        window.contentView = content

        terminal = TerminalHost(state: state, holdTime: options.holdTime, clock: clock)
        terminal.view.frame = NSRect(x: 10, y: 210, width: 760, height: 340)
        content.addSubview(terminal.view)

        rows = RowsView(frame: NSRect(x: 10, y: 10, width: 120, height: 190))
        if let overview = PanelID("overview:1") {
            rows.identifier = FocusMark.overviewRows(overview)
        }
        rows.zone = "other"
        rows.passesEscape = true
        rows.gateState = state
        rows.selection = selection
        content.addSubview(rows)

        let button = LoggingButton(frame: NSRect(x: 140, y: 160, width: 120, height: 32))
        button.title = "Control"
        button.bezelStyle = .push
        button.gateState = state
        content.addSubview(button)

        let text = LoggingTextView(frame: NSRect(x: 140, y: 10, width: 150, height: 140))
        text.zone = "text"
        text.gateState = state
        content.addSubview(text)

        let sendBox = LoggingTextView(frame: NSRect(x: 300, y: 10, width: 150, height: 190))
        sendBox.identifier = FocusMark.sendBox
        sendBox.zone = "send-box"
        sendBox.gateState = state
        content.addSubview(sendBox)

        let modal = LoggingView(frame: NSRect(x: 460, y: 10, width: 150, height: 190))
        modal.identifier = FocusMark.modal
        modal.zone = "modal"
        modal.gateState = state
        content.addSubview(modal)

        let recorder = LoggingView(frame: NSRect(x: 620, y: 10, width: 150, height: 190))
        recorder.identifier = FocusMark.keyRecorder
        recorder.zone = "modal"
        recorder.gateState = state
        content.addSubview(recorder)

        views = [
            "chat": terminal.view, "other": rows, "control": button, "text": text,
            "send-box": sendBox, "modal": modal, "recorder": recorder,
        ]

        // The custom keys of the scenario go through the settings edge, as settings.json does.
        // Each one must be a change there: a key that the edge refuses fails the scenario here,
        // not as a missing command later.
        let stored = setup.custom.mapValues { $0.map(JSONValue.string) ?? JSONValue.null }
        let changes = KeyChanges(stored: .object(stored))
        for (id, text) in setup.custom.sorted(by: { $0.key < $1.key }) {
            let binding: KeyBinding? =
                if let text { Chord(text).map(KeyBinding.chord) } else { .off }
            guard let slot = KeySlot(id), let binding, changes[slot] == binding else {
                Issue.record("The settings edge refuses the custom key \(id) of the scenario.")
                continue
            }
        }
        let keys = KeyMap(changes)
        let window = window
        let sinks = KeySinks(
            run: { state.record("cmd:\($0)") },
            hold: { state.record("hold:\($0)@\($1)") },
            escape: { intent in
                switch intent {
                case .none:
                    return
                case .leaveSendBox:
                    state.record("esc:leave-send-box")
                    _ = window.makeFirstResponder(nil)
                case .openSettings:
                    state.record("esc:open-settings")
                    state.settingsOnTop = true
                case .closeSettings:
                    state.record("esc:close-settings")
                    state.settingsOnTop = false
                }
            },
            settingsOnTop: { state.settingsOnTop })
        filter = WindowKeyFilter(
            window: window, selection: selection, keys: keys, sinks: sinks)
        if options.bypass {
            let bypass = BypassFilter(filter)
            self.bypass = bypass
            window.filter = bypass
        }
        rows.filter = filter
        menuLog = MenuLog(state: state)
        menu = MainMenu.build(
            MenuModel.make(appName: "Bifrost Dev", keys: keys), target: menuLog)

        rowSource.apply(ids: rows.rows)
    }

    // The state of the set-up. The calibration moves the focus to the chat, and that focus can
    // select its session. So the set-up comes after the calibration.
    private func prepare(_ setup: Scenario.Setup) {
        selection.selectedId = setup.selected
        state.blocked = setup.blocked
        state.heard = setup.heard
        state.waits = setup.waits
        state.settingsOnTop = setup.settingsOnTop
        state.escTaker = setup.escTaker
    }

    // Close the window and stop the timer of the chat.
    func close() {
        state.logging = false
        terminal.input.close()
        window.filter = nil
        window.close()
    }

    // MARK: Calibration

    // The text that the terminal sends for a key when it gets the key itself, not through the
    // filter. The expected PTY text of a key that the filter lets through is this text.
    func calibrate(_ keys: Set<Scenario.Term>) -> [Scenario.Term: [UInt8]] {
        _ = window.makeFirstResponder(terminal.view)
        var calibration: [Scenario.Term: [UInt8]] = [:]
        for key in keys.sorted(by: { "\($0)" < "\($1)" }) {
            let mods = Set(key.mods.compactMap(USKeyboard.Mod.init(rawValue:)))
            guard
                let event = USKeyboard.keyEvent(
                    down: true, id: key.key, mods: mods, isRepeat: key.isRepeat, window: window)
            else { continue }
            terminal.capture = []
            terminal.view.keyDown(with: event)
            calibration[key] = terminal.capture ?? []
            terminal.capture = nil
        }
        _ = window.makeFirstResponder(nil)
        return calibration
    }

    // MARK: Scenarios

    func run(_ scenario: Scenario) async -> ScenarioResult {
        let expect = scenario.expect
        let calibration = calibrate(Set(expect.pty.compactMap(\.term)))
        prepare(scenario.setup)
        focus(scenario.setup.view)
        state.reset()
        state.logging = true
        var selected = selection.selectedId
        for step in scenario.steps {
            await perform(step)
            // A new selection of a focus (FocusChange) goes to the log. A click logs its own
            // selection.
            if selection.selectedId != selected, step.action != "click" {
                state.record("select:\(selection.selectedId ?? "none")")
            }
            selected = selection.selectedId
        }
        await wait(.milliseconds(20))
        state.logging = false
        if terminal.view.hasMarkedText() { terminal.view.unmarkText() }

        var expectedPty: [UInt8] = []
        for part in expect.pty {
            if let text = part.text { expectedPty += Array(text.utf8) }
            if let term = part.term { expectedPty += calibration[term] ?? [] }
        }
        return ScenarioResult(
            id: scenario.id, expectedLog: expect.log, actualLog: state.log,
            expectedPty: expectedPty, actualPty: state.pty, checkPty: scenario.pty != "ignore")
    }

    private func focus(_ name: String) {
        _ = window.makeFirstResponder(name == "window" ? nil : views[name])
    }

    private func perform(_ step: Scenario.Step) async {
        switch step.action {
        case "down", "up":
            key(step)
        case "wait":
            await wait(.milliseconds(step.ms ?? 0))
        case "focus":
            focus(step.view ?? "window")
        case "press":
            mouse(.leftMouseDown, step.row)
        case "click":
            mouse(.leftMouseUp, step.row)
        case "window-blur":
            filter.keyWindowChanged(false)
        case "window-focus":
            filter.keyWindowChanged(true)
        case "close":
            terminal.input.close()
        case "fallback":
            terminal.input.fallback()
        case "other":
            terminal.input.other()
        case "row":
            // A red box of a scenario with no reason is a box of a prompt.
            let alert: SessionAlert =
                switch (step.box, step.reason) {
                case ("yellow", _): .yellow(since: 0)
                case ("red", "escalated"): .red(.escalated, since: 0)
                case ("red", "error"): .red(.error, since: 0)
                case ("red", _): .red(.prompt, since: 0)
                default: .none
                }
            terminal.input.row(blocks: alert.blocksPrompt)
        case "set":
            if let value = step.blocked { state.blocked = value }
            if let value = step.heard { state.heard = value }
            if let value = step.waits { state.waits = value }
            if let value = step.escTaker { state.escTaker = value }
        case "compose":
            if step.on == true {
                terminal.view.setMarkedText(
                    "か", selectedRange: NSRange(location: 1, length: 0),
                    replacementRange: NSRange(location: NSNotFound, length: 0))
            } else if terminal.view.hasMarkedText() {
                terminal.view.unmarkText()
            }
        default:
            state.record("driver:unknown step \(step.action)")
        }
    }

    // Move the clock of the hold timer. Then let a timer that is due run, so its effects come
    // before the next step, as they do with real time.
    private func wait(_ duration: Duration) async {
        await waitForHoldTimer()
        clock.advance(by: duration)
        await waitForHoldTimer()
    }

    // Wait until the hold timer sleeps on the clock or has run. A timer task that did not
    // start yet, or that woke, runs on the main actor at the next suspension. The wait is 5 s
    // at most on the real clock.
    //
    // The wait checks its two states after each turn of the main actor. The scenarios make more
    // than 800 of these waits, so a wait with a sleep between its checks is too slow, and
    // ManualClock.waitForSleepers(_:) records an issue when no timer runs.
    private func waitForHoldTimer() async {
        let end = ContinuousClock.now + .seconds(5)
        while terminal.input.holdTimer != nil, clock.sleeperCount == 0,
            ContinuousClock.now < end
        {
            await Task.yield()
        }
    }

    private func key(_ step: Scenario.Step) {
        let id = step.key ?? ""
        let down = step.action == "down"
        if let mod = USKeyboard.modifierOf[id] {
            if down { held.insert(mod) } else { held.remove(mod) }
            guard let event = USKeyboard.modifierEvent(id: id, mods: held, window: window) else {
                state.record("driver:no event for \(id)")
                return
            }
            deliver(event)
            return
        }
        let mods = held.union((step.mods ?? []).compactMap(USKeyboard.Mod.init(rawValue:)))
        // macOS sends no key up while Cmd is down.
        if !down && mods.contains(.meta) { return }
        guard
            let event = USKeyboard.keyEvent(
                down: down, id: id, mods: mods, isRepeat: step.isRepeat ?? false, window: window)
        else {
            state.record("driver:no event for \(id)")
            return
        }
        deliver(event)
    }

    // Give an event to the window as NSApplication.sendEvent does for the key window.
    private func deliver(_ event: NSEvent) {
        if event.type == .keyDown && event.modifierFlags.contains(.command) {
            if window.performKeyEquivalent(with: event) { return }
            if menu.performKeyEquivalent(with: event) { return }
        }
        window.sendEvent(event)
    }

    // The mouse steps go to the rows view itself. A click through the window would move the focus
    // to the rows, and the scenarios test the keys, not the mouse path.
    private func mouse(_ type: NSEvent.EventType, _ row: String?) {
        guard let row, let point = rows.windowPoint(of: row),
            let event = NSEvent.mouseEvent(
                with: type, location: point, modifierFlags: USKeyboard.flags(held),
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 0, clickCount: 1,
                pressure: type == .leftMouseDown ? 1 : 0)
        else {
            state.record("driver:no mouse event")
            return
        }
        if type == .leftMouseDown { rows.mouseDown(with: event) } else { rows.mouseUp(with: event) }
    }
}

// The target of the Bifrost items of the menu of the app. The menu gets the keys of the two menu
// slots first.
@MainActor
final class MenuLog: NSObject, MainMenuTarget {
    private let state: GateState

    init(state: GateState) {
        self.state = state
    }

    func runMenuItem(_ sender: NSMenuItem) {
        switch MainMenu.action(of: sender) {
        case .closePanel: state.record("menu:\(KeySlot.closePanel)")
        case .toggleFullScreen: state.record("menu:\(KeySlot.toggleFullscreen)")
        default: state.record("menu:other")
        }
    }
}

// Run each scenario in its own window. The result keeps the order of the scenarios.
@MainActor
func runScenarios(_ scenarios: [Scenario], options: ScenarioOptions) async -> [ScenarioResult] {
    var results: [ScenarioResult] = []
    for scenario in scenarios {
        let run = ScenarioRun(setup: scenario.setup, options: options)
        results.append(await run.run(scenario))
        run.close()
    }
    return results
}

// Show bytes with escapes, for the messages of a failed scenario.
@MainActor
func escaped(_ bytes: [UInt8]) -> String {
    var out = ""
    for byte in bytes {
        switch byte {
        case 0x1B: out += "\\e"
        case 0x0D: out += "\\r"
        case 0x0A: out += "\\n"
        case 0x09: out += "\\t"
        case 0x7F: out += "\\x7f"
        case 0x20: out += "␠"
        case 0x21...0x7E: out += String(UnicodeScalar(byte))
        default: out += String(format: "\\x%02x", byte)
        }
    }
    return out
}

// The filter of the bypass control (--bypass of the gate): the key filter does not see the
// events that the window sends. The other calls of the window go to the key filter.
@MainActor
private final class BypassFilter: WindowEventFilter {
    private let filter: WindowKeyFilter

    init(_ filter: WindowKeyFilter) {
        self.filter = filter
    }

    func filter(_ event: NSEvent) -> Bool { false }
    func keyEquivalent(_ event: NSEvent) -> Bool { filter.keyEquivalent(event) }
    func dispatchEnded(_ event: NSEvent) { filter.dispatchEnded(event) }
    func endOfChain(_ event: NSEvent) -> Bool { filter.endOfChain(event) }

    func focusChanged(from: NSResponder?, to: NSResponder?) {
        filter.focusChanged(from: from, to: to)
    }

    func keyWindowChanged(_ isKey: Bool) { filter.keyWindowChanged(isKey) }
}
