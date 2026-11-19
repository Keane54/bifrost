// The answers of the debug test port (docs/behaviour/shell.md, "The test port"). Only a Debug build
// has this code, and the app makes the port only when StartPlan.testPort has a socket: the
// development app with a test home. The smoke test drives the app with it.
//
// - state: the frames of the layout (ID, panels, active panel, rect, minimised, locked), the chats
//   (session, attached, ended, blocked, note, Metal renderer), the count of the opens and the
//   closes of the microphone of the speech engine (the fake engine in a test home), the window
//   (visible: no other window covers all of it; main: on the main display; space: on the active
//   space; background: the phase of the background motion) and the last bench run (name, status,
//   phase, reason, and check: true when a failed check of the display or of the window gave no
//   result), or null. It also gives the Overview panels of the layout (panel, active tab, sort
//   column, desc, and the rows of the active tab in view order with their ID and name), the
//   report of the import of this start (at, imported, kept, skipped), or null, the saved settings
//   (the fields of settings.json), or null before the settings store opens, the key of each item
//   of the menu of the app by its title (menuKeys), the Event log (the count of entries and the
//   texts of the newest 5), the Usage HUD (the bars and the source line, with no token), the rows
//   of the Watchlist (null while it is in no frame), the PR line of each Show Info panel, the
//   Reviews panel (reviews: the rows of both tabs with pr, tab, flash, paused, state and the
//   step of a round that runs, the consent of the automatic rounds and the problem line), the
//   status of Live details (live: plugin, modCurrent, oldInstall, listening, liveSessions,
//   claudeVersion, versionOk, error) and of the skills (skills: plugin, folderCurrent, the names
//   of the skills, error) as Settings has them, or null before their first read, and the rows of
//   the session list (sessions: id, state, pid, listed), the release notes dialog (releaseNotes:
//   null, or view, load, title and the versions that it shows), the Daily update (dailyUpdate:
//   null with no service, or the status, whether a run goes, and each tab with its ID, its
//   marker, the length of its draft and its send) and the Performance monitor (performance: the
//   level, "checking" before the first level, and the number of reasons). The session actions
//   give the selected row ID (selected), the notice line and the error line of the action runner
//   (notice, error), whether a dialog shows (dialog), and the IDs of the rows with an action
//   that did not end (running).
// - open: open the panel, or bring its frame to the front.
// - overview: sort the active tab of the Overview panel by the column, as a click on its header
//   does. An Overview that is not in a frame, or a column that the active tab hides, gives an
//   error.
// - type and key: synthetic key events of a US keyboard through the window, so the window key
//   filter gets them first, as it gets the keys of a person. They go to the focused chat. With no
//   focused chat the port sends no key. The key "interrupt" (Cmd+.) is a Bifrost key of the window:
//   it acts on the selected row, so it goes also with no focused chat.
// - hold: the key down of Space, a wait, then its key up, to the focused chat. The answer comes
//   after the key up.
// - bench: start a run of the debug bench. The answer comes at once, and the state shows the run.
//   The runner refuses a home that is not the test home and a claude that is not the fake claude of
//   this repo. The results go to <test home>/bench/<name>.jsonl. One run at a time.
// - setting: change the settings with the patch of the request, in one edit of the settings
//   store (SettingsPatch). A refused patch changes nothing and gives the reason as the error, for
//   example "Two actions can't share the same key." for a new key conflict.
// - live and skills: run an action of Settings > Live details or of Settings > Skills, as its
//   button does, also Remove with no confirm. The answer comes at the end of the action. A
//   failed action gives its text as the error, for example "claude was not found.".
// - resume: run the session command Resume on the row of the session. A refusal gives its text
//   as the error.
// - action: run a session action or a global action through the action runner, and answer its
//   dialogs (Shell.runTestAction). The answer comes at the end of the run: ok, or the reason
//   when the action is off, a dialog did not save or start, or the run did not end in time.
// - send: type the text into the session, as the send box does. The answer comes at the end of
//   the send: ok, or the reason of the refusal.
// - releaseNotes: open the release notes dialog, as the Release notes button of Settings > Updates
//   does.
// - daily: Refresh of the Daily update (the answer comes at once, and the state shows the run),
//   or Mark as sent of an area. With no service, or no tab for the area, the error says why.
// - reviews: a click on Review or Pause of the row of a PR in the Reviews panel, as its button
//   does (Shell.runReviewsTest). The answer comes at once, and the state shows the result. A PR
//   with no row, or a row that does not offer the item now, gives an error.
// - quit: quit the app after the answer went to the client, as the Quit item does.
#if DEBUG
import AppKit
import BifrostApp
import BifrostChat
import BifrostDictation
import BifrostFoundation
import BifrostKeyboard
import BifrostLayout
import BifrostSessions
import BifrostWindows

final class TestPortHandler {
    // The key of the Info.plist of the Debug app that gives the path of the fake claude of this
    // repo (scripts/fake-claude/claude). The Debug build sets it from the source root of the
    // build. The Release app has no such key.
    static let fakeClaudeKey = "BifrostFakeClaude"

    private let shell: Shell
    // The test home of the app, or nil. The port exists only with a test home.
    private let testHome: URL?
    // The path of the fake claude from the env, or nil. A bench run needs it.
    private let fakeClaude: String?
    // The runner of the last bench run and the name of its results file.
    private var bench: (runner: BenchRunner, name: String)?

    init(shell: Shell, testHome: URL?, fakeClaude: String?) {
        self.shell = shell
        self.testHome = testHome
        self.fakeClaude = fakeClaude
    }

    func handle(_ request: TestPortRequest) async -> JSONValue {
        switch request {
        case .state:
            return state()
        case .open(let panel):
            shell.layout.apply(.open(panel))
            return ["ok": true]
        case .overview(let panel, let column):
            do throws(Shell.OverviewSortRefusal) {
                try shell.sortOverview(panel, by: column)
            } catch {
                return ["error": .string(error.message)]
            }
            return ["ok": true]
        case .type(let text):
            return type(text)
        case .key(let key):
            return press(key)
        case .hold(let ms):
            return await hold(ms)
        case .bench(let request):
            return startBench(request)
        case .setting(let patch):
            guard let reason = await shell.changeSettings(patch) else { return ["ok": true] }
            return ["error": .string(reason)]
        case .live(let action):
            return answer(await shell.runPluginAction(action, skills: false))
        case .skills(let action):
            return answer(await shell.runPluginAction(action, skills: true))
        case .resume(let sessionId):
            return answer(await shell.resumeSession(sessionId))
        case .action(let action):
            return answer(await shell.runTestAction(action))
        case .send(let session, let text):
            return answer(await shell.sendTestText(session, text))
        case .releaseNotes:
            return answer(
                shell.openReleaseNotes()
                    ? nil : "the release notes dialog did not open: no source, or a dialog shows")
        case .daily(let action):
            return answer(shell.runDailyTest(action))
        case .reviews(let action, let pr):
            return answer(shell.runReviewsTest(action, pr: pr))
        case .quit:
            return ["ok": true]
        }
    }

    // The answer of a change: ok, or the reason of the failure as the error.
    private func answer(_ failure: String?) -> JSONValue {
        failure.map { ["error": .string($0)] } ?? ["ok": true]
    }

    // The answer of the request went to the client. The quit starts from the main run loop, not
    // from this block of the main dispatch queue: the quit waits for its saves in a nested run
    // loop (terminateLater), and the main queue cannot run the tasks of the saves inside one of
    // its own blocks. A perform on the main thread with no wait goes to the run loop.
    func answered(_ request: TestPortRequest) {
        guard request == .quit else { return }
        let app = NSApplication.shared
        app.performSelector(
            onMainThread: #selector(NSApplication.terminate(_:)), with: nil, waitUntilDone: false)
    }

    // MARK: - The state

    private func state() -> JSONValue {
        let frames = shell.layout.layout.frames.map { frame -> JSONValue in
            [
                "id": .string(frame.id.text),
                "panels": .array(frame.panels.map { .string($0.text) }),
                "active": .string(frame.active.text),
                "rect": [
                    "x": .number(frame.rect.x), "y": .number(frame.rect.y),
                    "w": .number(frame.rect.w), "h": .number(frame.rect.h),
                ],
                "minimised": .bool(frame.minimised), "locked": .bool(frame.locked),
            ]
        }
        let chats = shell.chats.sessionIds.compactMap { id -> JSONValue? in
            guard let state = shell.chats.terminal(id)?.state else { return nil }
            return [
                "session": .string(id), "attached": .bool(state.attached),
                "ended": .bool(state.ended), "blocked": .bool(state.blocked),
                "note": state.note.map(JSONValue.string) ?? .null, "metal": .bool(state.metal),
            ]
        }
        let dictation = shell.dictation
        let microphone: JSONValue = [
            "opens": .int(dictation.microphoneOpens), "closes": .int(dictation.microphoneCloses),
        ]
        let fields: [String: JSONValue] = [
            "frames": .array(frames), "chats": .array(chats), "microphone": microphone,
            "window": windowState(), "bench": benchState(), "overviews": shell.overviewsState,
            "import": shell.importState, "settings": shell.settingsState, "menuKeys": menuKeys(),
            "events": shell.eventsState, "usage": shell.usageState,
            "watchlist": shell.watchlistState, "showInfo": shell.showInfoState,
            "reviews": shell.reviewsState,
            "live": shell.liveDetailsState, "skills": shell.skillsPluginState,
            "sessions": shell.sessionsState, "releaseNotes": shell.releaseNotesState,
            "dailyUpdate": shell.dailyUpdateState, "performance": shell.performanceState,
        ]
        return .object(fields.merging(shell.actionsState) { first, _ in first })
    }

    // The key of each item of the menu of the app, by its title: the modifiers in the order of
    // the macOS menus, then the key equivalent, joined with "+", for example "shift+cmd+k". An
    // item with no key gives null. For a title that comes again, the first item counts. The app
    // builds the menu again after a change of a menu key, so the answer shows the menu that the
    // app installed.
    private func menuKeys() -> JSONValue {
        let modifiers: [(NSEvent.ModifierFlags, String)] = [
            (.control, "ctrl"), (.option, "alt"), (.shift, "shift"), (.command, "cmd"),
        ]
        var keys: [String: JSONValue] = [:]
        for top in NSApplication.shared.mainMenu?.items ?? [] {
            for item in top.submenu?.items ?? [] where !item.isSeparatorItem {
                guard keys[item.title] == nil else { continue }
                guard !item.keyEquivalent.isEmpty else {
                    keys[item.title] = .null
                    continue
                }
                let mask = item.keyEquivalentModifierMask
                let parts = modifiers.filter { mask.contains($0.0) }.map(\.1)
                keys[item.title] = .string((parts + [item.keyEquivalent]).joined(separator: "+"))
            }
        }
        return .object(keys)
    }

    private func windowState() -> JSONValue {
        let window = shell.window.window
        let main = window.screen.map { $0 == NSScreen.screens.first } ?? false
        return [
            "visible": .bool(window.isVisible && window.occlusionState.contains(.visible)),
            "main": .bool(main), "space": .bool(window.isOnActiveSpace),
            "background": .string(shell.backgroundPhase),
        ]
    }

    private func benchState() -> JSONValue {
        guard let bench else { return .null }
        var phase: JSONValue = .null
        var reason: JSONValue = .null
        var check: JSONValue = .null
        let status: String
        switch bench.runner.status {
        case .waiting: status = "waiting"
        case .running(let current):
            status = "running"
            phase = current.map { .string($0.rawValue) } ?? .null
        case .done: status = "done"
        case .failed(let text, let failedCheck):
            status = "failed"
            reason = .string(text)
            check = .bool(failedCheck)
        }
        return [
            "name": .string(bench.name), "status": .string(status), "phase": phase,
            "reason": reason, "check": check,
        ]
    }

    // MARK: - The bench

    // Start a bench run in a new task, and answer at once. A run that runs refuses a new one.
    private func startBench(_ request: TestBench) -> JSONValue {
        if let bench {
            switch bench.runner.status {
            case .waiting, .running: return ["error": "a bench run is running"]
            case .done, .failed: break
            }
        }
        guard let testHome, let ptys = shell.ptys, let fakeClaude,
            let runner = BenchRunner(
                testHome: testHome, claudePath: ptys.claudePath, fakeClaudePath: fakeClaude)
        else { return ["error": "the bench needs a test home and the fake claude"] }
        let output = testHome.appending(path: "bench").appending(path: "\(request.name).jsonl")
        bench = (runner, request.name)
        let stage = shell.benchStage()
        Task {
            await runner.run(
                BenchPlan(request.plan), chats: request.chats, variant: request.variant,
                output: output, stage: stage)
        }
        return ["ok": true]
    }

    // MARK: - The keys

    private func type(_ text: String) -> JSONValue {
        guard shell.chats.focusedSession != nil else { return ["error": "no focused chat"] }
        let strokes = text.compactMap(USKeyboard.keystroke(for:))
        // The message parse allows printable ASCII only, and each such character has a key.
        guard strokes.count == text.count else { return ["error": "no key for the text"] }
        for stroke in strokes { send(stroke.id, stroke.mods) }
        return ["ok": true]
    }

    private func press(_ key: TestKey) -> JSONValue {
        if key == .interrupt {
            send(".", [.meta])
            return ["ok": true]
        }
        guard shell.chats.focusedSession != nil else { return ["error": "no focused chat"] }
        switch key {
        case .enter: send("Enter", [])
        case .shiftEnter: send("Enter", [.shift])
        case .escape: send("Escape", [])
        case .interrupt: break
        }
        return ["ok": true]
    }

    // The key down of Space, a wait of ms milliseconds, then the key up, through the window.
    private func hold(_ ms: Int) async -> JSONValue {
        guard shell.chats.focusedSession != nil else { return ["error": "no focused chat"] }
        sendOne("Space", down: true)
        try? await Task.sleep(for: .milliseconds(ms))
        sendOne("Space", down: false)
        return ["ok": true]
    }

    private func sendOne(_ id: String, down: Bool) {
        let window = shell.window.window
        guard
            let event = USKeyboard.keyEvent(
                down: down, id: id, mods: [], isRepeat: false, window: window)
        else { return }
        window.sendEvent(event)
    }

    // One key down and up through the window. A modifier goes down before the key and up after
    // it, as on a keyboard. As for the key of a person, a key down with Cmd goes to the key
    // equivalents first, and macOS sends no key up while Cmd is down.
    private func send(_ id: String, _ mods: Set<USKeyboard.Mod>) {
        let window = shell.window.window
        var held: Set<USKeyboard.Mod> = []
        var events: [NSEvent?] = []
        for mod in USKeyboard.Mod.allCases where mods.contains(mod) {
            held.insert(mod)
            events.append(
                USKeyboard.modifierEvent(id: Self.modifierKey(mod), mods: held, window: window))
        }
        for down in [true, false] where down || !mods.contains(.meta) {
            events.append(
                USKeyboard.keyEvent(
                    down: down, id: id, mods: mods, isRepeat: false, window: window))
        }
        for mod in USKeyboard.Mod.allCases.reversed() where mods.contains(mod) {
            held.remove(mod)
            events.append(
                USKeyboard.modifierEvent(id: Self.modifierKey(mod), mods: held, window: window))
        }
        for event in events.compactMap(\.self) {
            let command = event.type == .keyDown && event.modifierFlags.contains(.command)
            if command && window.performKeyEquivalent(with: event) { continue }
            window.sendEvent(event)
        }
    }

    // The key ID of a modifier key (USKeyboard.modifierOf).
    private static func modifierKey(_ mod: USKeyboard.Mod) -> String {
        switch mod {
        case .shift: "Shift"
        case .ctrl: "Control"
        case .alt: "Alt"
        case .meta: "Meta"
        }
    }
}
#endif
