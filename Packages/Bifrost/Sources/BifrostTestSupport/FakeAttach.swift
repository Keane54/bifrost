// The parts of the chat terminal tests: the fake claude of scripts/fake-claude
// on the PATH of a real PTY, a test home in a TemporaryFolder, fake session rows, and a canvas
// with the chat terminals in a window that is never ordered front. With fakePTY, the chats get
// the fake PTY of BifrostTestSupport and a manual clock: no child process starts, and the test
// gives the output and the exit of each attach.
//
// Safety: no test runs the real claude or attaches to a real session (the fake attach only
// writes files in the test home). Dictation uses only FakeSpeechEngine, so no test opens the
// microphone, asks for a permission or downloads a speech model. Sizes come from a fake
// process inspector, so no test reads a process of the Mac. Links go to a fake
// LinkOpener with no default apps, so no test asks Launch Services, opens a link or starts an
// app. OSC 52 goes to a private pasteboard. The tests never activate the app.
import AppKit
import BifrostChat
import BifrostDictation
import BifrostFoundation
import BifrostKeyboard
import BifrostLayout
import BifrostSessions
import BifrostWindows
import Foundation
import SwiftTerm
import Synchronization
import Testing

// No file has an app, and Launch Services answers (Terminal is a terminal). Thus a document opens
// with no app, and the link rules never ask Launch Services.
package nonisolated struct NoDefaultApps: DefaultApps {
    package init() {}

    package func opener(of file: FileFacts) -> OpenerFacts {
        OpenerFacts(app: nil, typeApp: nil, terminalIDs: ["com.apple.Terminal"])
    }
}

// The fake sessions. The short ID of the first one is 5a0e0001, as in the smoke test.
@MainActor
package enum FakeSession {
    package static let first = "5a0e0001-0000-4000-8000-000000000001"
    package static let second = "5a0e0002-0000-4000-8000-000000000002"

    package static func shortId(_ sessionId: String) -> String { String(sessionId.prefix(8)) }

    // The PTY view of the chat of the session.
    package static func chatView(_ sessionId: String = first) -> PTYView {
        guard let session = SessionID(sessionId) else { preconditionFailure("bad session ID") }
        return .chat(session)
    }

    // An owned row that is not parked, in the folder of the test home.
    package static func row(
        _ sessionId: String = first, folder: String, pid: pid_t? = nil,
        kind: SessionKind = .owned, state: SessionState = .idle
    ) -> SessionRow {
        SessionRow.test(
            sessionId: sessionId, shortId: ShortID(shortId(sessionId)), name: "fake", kind: kind,
            pid: pid,
            cwd: folder, state: state, lastActivity: 0, startedAt: 0)
    }
}

// A claude runner that runs no program. The chats start the fake claude on a PTY, not through
// the runner.
nonisolated struct NoProgramRunner: CommandRunner {
    func run(_ command: Command) async -> ExecResult {
        ExecResult(.notStarted, stderr: "refused by the test")
    }
}

// The canvas bodies of the chat panels. Another panel gets a plain view.
@MainActor
final class ChatBodies: PanelBodies {
    let chats: ChatTerminals

    init(chats: ChatTerminals) {
        self.chats = chats
    }

    func body(for panel: PanelID) -> NSView { chats.body(for: panel) ?? NSView() }
    func title(for panel: PanelID) -> String { panel.text }
    func releaseBody(for panel: PanelID) { chats.releaseBody(for: panel) }
}

// The window, the canvas, the PTY manager and the chat terminals of one test.
@MainActor
package final class ChatFixture {
    package let folder: TemporaryFolder
    package let window: BifrostWindow
    package let model: WindowLayoutModel
    package let canvas: CanvasView
    package let ptys: PTYManager
    package let chats: ChatTerminals
    // The session sizes of the other clients: the device /dev/ttys900 and the size of the init.
    // No size: the size read fails.
    package let sizes: FakeProcessInspector
    package let spawner = RecordingPTYSpawner()
    // The fake PTY and the manual clock of the chats, with fakePTY.
    package let fakes = FakeSpawner()
    package let clock = ManualClock()
    package let fakePTY: Bool
    // The screen that the fake attach prints after its first line, with fakePTY.
    private var fakeScreen: String?
    package let pasteboard = NSPasteboard.withUniqueName()
    // The dictation of the chats: the fake engine, the service on its own clock (the
    // 2-minute limit), the vim mode answer and the URLs that the notice opened. nil with no
    // speech script.
    package let speech: FakeSpeechEngine?
    package let speechClock = ManualClock()
    package let dictation: DictationService?
    var vimMode = false
    package private(set) var openedURLs: [URL] = []
    // The commands of the Bifrost keys that the key filter ran, and the intents of each Esc.
    package private(set) var commands: [String] = []
    package private(set) var escapes: [EscapeIntent] = []
    package private(set) var links: [LinkAction] = []
    // The link opener of the chats.
    package let linkOpener: LinkOpener
    package private(set) var filter: WindowKeyFilter?
    private let bodies: ChatBodies
    package var rows: [SessionRow]

    package var home: String { folder.path }

    package init(
        renderer: TerminalRenderer = .metal, size: TerminalSize? = nil,
        rows: ((String) -> [SessionRow])? = nil, speech script: FakeSpeechScript? = nil,
        dictationKey: KeyBinding = .off, fakePTY: Bool = false
    ) throws {
        UITestApp.prepare()
        self.fakePTY = fakePTY
        folder = try TemporaryFolder(short: true)
        let home = folder.path
        self.rows = rows?(home) ?? [FakeSession.row(folder: home)]
        sizes = FakeProcessInspector(size: size)
        let fake = try Repo.fakeClaude()
        let fakeFolder = URL(fileURLWithPath: fake).deletingLastPathComponent().path
        let claude = ClaudeRunner(
            path: fake,
            baseEnvironment: [
                "PATH": "\(fakeFolder):/usr/bin:/bin", "HOME": home, "BIFROST_TEST_HOME": home,
                "LANG": "en_US.UTF-8",
            ], runner: NoProgramRunner())
        ptys = PTYManager(claude: claude, spawner: fakePTY ? fakes : spawner)
        var openLink: (LinkAction) -> Void = { _ in }
        var openURL: (URL) -> Void = { _ in }
        var readVim: () -> Bool = { false }
        linkOpener = LinkOpener(apps: NoDefaultApps()) { openLink($0) }
        var readRows: () -> [SessionRow] = { [] }
        let engine = script.map { FakeSpeechEngine(script: $0) }
        speech = engine
        let clock = speechClock
        let service = engine.map { DictationService(engine: $0, clock: clock) }
        dictation = service
        chats = ChatTerminals(
            ptys: ptys, sizes: SessionSizeReader(inspector: sizes), rows: { readRows() },
            clock: fakePTY ? self.clock : ContinuousClock(),
            links: linkOpener, pasteboard: pasteboard,
            renderer: renderer, dictation: service.map {
                ChatDictationParts(
                    service: $0, vimMode: { readVim() }, openURL: { openURL($0) })
            })
        window = BifrostWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800), styleMask: [.titled],
            backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.actsAsKey = true
        model = WindowLayoutModel(layout: WindowLayout(bounds: LayoutSize(w: 1, h: 1)))
        bodies = ChatBodies(chats: chats)
        canvas = CanvasView(model: model, bodies: bodies, settings: CanvasSettings())
        canvas.frame = NSRect(x: 0, y: 0, width: 1200, height: 800)
        window.contentView = canvas
        chats.onDictationLook = { [canvas] in canvas.setDictation($0, level: $1) }
        // The canvas moves the bodies first, then the chats get the layout, as the shell does.
        model.onChange = { [weak self] change in
            self?.canvas.modelChanged(change)
            if change == .layout { self?.sync() }
        }
        let sinks = KeySinks(
            run: { [weak self] in self?.commands.append($0.description) }, hold: { _, _ in },
            escape: { [weak self] in self?.escapes.append($0) }, settingsOnTop: { false })
        filter = WindowKeyFilter(
            window: window, selection: SelectionModel(list: SessionListModel()),
            keys: KeyMap([.dictation: dictationKey]), sinks: sinks)
        openLink = { [weak self] in self?.links.append($0) }
        openURL = { [weak self] in self?.openedURLs.append($0) }
        readVim = { [weak self] in self?.vimMode ?? false }
        readRows = { [weak self] in self?.rows ?? [] }
    }

    // Give the chats the layout again. The chats read the rows of the fixture.
    package func sync(loaded: Bool = true) {
        chats.sync(layout: model.layout, loaded: loaded)
    }

    // MARK: - The layout

    package func panel(_ sessionId: String = FakeSession.first) -> PanelID {
        guard let session = SessionID(sessionId) else {
            preconditionFailure("bad session ID")
        }
        return .chat(session)
    }

    // Open the chat of the session in a new frame at the rect. The result is the frame.
    @discardableResult
    package func open(
        _ sessionId: String = FakeSession.first,
        at r: LayoutRect = LayoutRect(x: 0, y: 0, w: 640, h: 400)
    ) -> FrameID {
        openPanel(panel(sessionId), at: r)
    }

    @discardableResult
    package func openPanel(_ id: PanelID, at r: LayoutRect) -> FrameID {
        model.apply(.open(id))
        guard let frame = model.layout.frame(of: id) else { preconditionFailure("no frame") }
        model.apply(.setRect(frame.id, r))
        return frame.id
    }

    package func terminal(_ sessionId: String = FakeSession.first) throws -> ChatTerminal {
        try #require(chats.terminal(sessionId))
    }

    // MARK: - The files of the fake attach

    // The screen that the fake attach prints after its first line: the escape sequences of a
    // screen. Write it before the open.
    package func writeScreen(_ text: String) throws {
        if fakePTY {
            fakeScreen = text
        } else {
            try text.write(
                toFile: folder.appending("fake-attach-screen"), atomically: true, encoding: .utf8)
        }
    }

    // The first line of each attach: the lines of attach.log, or the spawns of the fake PTY.
    package var attachLines: [String] {
        if fakePTY {
            return fakes.spawns.map { "FAKE ATTACH \($0.arguments.last ?? "")" }
        }
        let file = folder.appending("attach.log")
        let text = (try? String(contentsOfFile: file, encoding: .utf8)) ?? ""
        return text.split(separator: "\n").map(String.init)
    }

    // The fake child of the last attach of the session, with fakePTY.
    package func fakeChild(_ sessionId: String = FakeSession.first) -> FakeChild? {
        let short = FakeSession.shortId(sessionId)
        let spawns = fakes.spawns
        let children = fakes.fakes
        guard let index = spawns.lastIndex(where: { $0.arguments.last == short }),
            index < children.count
        else { return nil }
        return children[index]
    }

    package func inputPath(_ sessionId: String = FakeSession.first) -> String {
        folder.appending("attach-input-\(FakeSession.shortId(sessionId)).log")
    }

    // The bytes that the session got from the chat window: the input file of the fake attach,
    // or each write to the fake PTY.
    package func input(_ sessionId: String = FakeSession.first) -> [UInt8] {
        if fakePTY { return fakeChild(sessionId)?.written.flatMap { $0 } ?? [] }
        return FileManager.default.contents(atPath: inputPath(sessionId)).map { [UInt8]($0) } ?? []
    }

    // A barrier for a check that nothing more reached the session: type the marker key "z",
    // wait until the session got it, and give the input before the marker. The chat writes the
    // bytes of the earlier events before the marker, so each such byte is in the result. With
    // the kitty keyboard protocol, the marker can come as CSI 122 u. The terminal of the session
    // must have the keyboard.
    package func inputBeforeMarker(
        _ sessionId: String = FakeSession.first, sourceLocation: SourceLocation = #_sourceLocation
    ) async -> [UInt8] {
        let before = input(sessionId).count
        type("z")
        var at: Int?
        await waitUntil(sourceLocation: sourceLocation) {
            at = Self.marker(in: Array(self.input(sessionId).dropFirst(before)))
            return at != nil
        }
        return Array(input(sessionId).prefix(before + (at ?? 0)))
    }

    // The index of the first marker key in the bytes, or nil.
    private static func marker(in bytes: [UInt8]) -> Int? {
        let forms = [Array("\u{1b}[122".utf8), [UInt8(ascii: "z")]]
        return forms.compactMap { bytes.firstRange(of: $0)?.lowerBound }.min()
    }

    // Wait until the attach of the session runs and the chat attached. On a real PTY, the fake
    // attach runs cat (then the terminal of the PTY is raw); the open ends in a later turn of the
    // main actor than the spawn, so the fake can make its file before the attach of the chat
    // exists. On the fake PTY, the fake child prints the first line and the screen.
    @discardableResult
    package func waitForAttach(
        _ sessionId: String = FakeSession.first, sourceLocation: SourceLocation = #_sourceLocation
    ) async -> Bool {
        if fakePTY {
            let attached = await waitUntil(sourceLocation: sourceLocation) {
                self.fakeChild(sessionId) != nil
                    && self.chats.terminal(sessionId)?.state.attached == true
            }
            guard attached, let child = fakeChild(sessionId),
                let terminal = chats.terminal(sessionId), terminal.benchOutput == 0
            else { return attached }
            child.emitData("FAKE ATTACH \(FakeSession.shortId(sessionId))\r\n" + (fakeScreen ?? ""))
            return await waitUntil(sourceLocation: sourceLocation) { terminal.benchOutput > 0 }
        }
        return await waitUntil(sourceLocation: sourceLocation) {
            FileManager.default.fileExists(atPath: self.inputPath(sessionId))
                && self.chats.terminal(sessionId)?.state.attached == true
        }
    }

    // The text of the screen of the terminal of the session.
    package func screen(_ sessionId: String = FakeSession.first) -> String {
        guard let view = chats.terminal(sessionId)?.view else { return "" }
        return view.visibleRowsText(0..<view.terminalDimensions.rows).joined(separator: "\n")
    }

    // Move the manual clock, then wait until no timer of the chats is due: each timer that the
    // move woke slept again to a later time, or ran its action (the agent view check, a size
    // send, a read of the session size). An action runs on the main actor in the turn of its
    // timer, so the effects up to its first wait are there after this call. A later step of an
    // action (for example a reattach or the result of a read) needs a wait of its own.
    package func advance(
        by duration: Duration, sourceLocation: SourceLocation = #_sourceLocation
    ) async {
        clock.advance(by: duration)
        await waitUntil(every: .milliseconds(1), sourceLocation: sourceLocation) {
            !self.chats.timersDue
        }
    }

    // MARK: - Events

    // A key down and a key up through the window, as NSApplication gives them to the key
    // window: a Cmd key first goes to the key equivalents of the views.
    package func key(_ id: String, _ mods: Set<USKeyboard.Mod> = []) {
        for down in [true, false] {
            // macOS sends no key up while Cmd is down.
            if !down && mods.contains(.meta) { continue }
            guard
                let event = USKeyboard.keyEvent(
                    down: down, id: id, mods: mods, isRepeat: false, window: window)
            else { continue }
            if down && mods.contains(.meta) && window.performKeyEquivalent(with: event) {
                continue
            }
            window.sendEvent(event)
        }
    }

    package func type(_ text: String) {
        for character in text { key(String(character)) }
    }

    // Only the key down, or only the key up, of a key with no modifier, through the window.
    package func keyDown(_ id: String) { press(id, down: true) }
    package func keyUp(_ id: String) { press(id, down: false) }

    private func press(_ id: String, down: Bool) {
        guard
            let event = USKeyboard.keyEvent(
                down: down, id: id, mods: [], isRepeat: false, window: window)
        else { return }
        window.sendEvent(event)
    }

    // The window point of the middle of a cell of the terminal of the session.
    package func point(col: Int, row: Int, _ sessionId: String = FakeSession.first) -> CGPoint {
        guard let view = chats.terminal(sessionId)?.view else { return .zero }
        let grid = view.terminalDimensions
        let optimal = view.getOptimalFrameSize().size
        let x = (CGFloat(col) + 0.5) * optimal.width / CGFloat(grid.cols)
        let top = (CGFloat(row) + 0.5) * optimal.height / CGFloat(grid.rows)
        let local = CGPoint(x: x, y: view.isFlipped ? top : view.bounds.height - top)
        return view.convert(local, to: nil)
    }

    // A click of the left button on the terminal view, as the window gives it.
    package func click(col: Int, row: Int, command: Bool, _ sessionId: String = FakeSession.first) {
        guard let view = chats.terminal(sessionId)?.view else { return }
        let location = point(col: col, row: row, sessionId)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            guard
                let event = NSEvent.mouseEvent(
                    with: type, location: location, modifierFlags: command ? [.command] : [],
                    timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                    clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0)
            else { continue }
            if type == .leftMouseDown {
                view.mouseDown(with: event)
            } else {
                view.mouseUp(with: event)
            }
        }
    }

    // A click of the left button at a point of the canvas, as the window gives it: the gesture
    // recognizers of the hit view and of its superviews see the press first, then the hit view
    // gets the press and the release. NSWindow drops the mouse events of a window that was never
    // ordered in, so the fixture does this dispatch itself. The result is the hit view.
    @discardableResult
    package func press(at point: CGPoint) -> NSView? {
        let location = canvas.convert(point, to: nil)
        guard let content = window.contentView,
            let hit = content.hitTest(content.superview?.convert(location, from: nil) ?? location)
        else { return nil }
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            guard
                let event = NSEvent.mouseEvent(
                    with: type, location: location, modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                    clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0)
            else { continue }
            guard type == .leftMouseDown else {
                hit.mouseUp(with: event)
                continue
            }
            var ancestor: NSView? = hit
            while let current = ancestor {
                for recognizer in current.gestureRecognizers where recognizer.isEnabled {
                    recognizer.mouseDown(with: event)
                }
                ancestor = current.superview
            }
            hit.mouseDown(with: event)
        }
        return hit
    }

    // A drag of the left button on the terminal view, from a cell to a cell, in 8 steps.
    package func drag(
        from start: (col: Int, row: Int), to end: (col: Int, row: Int),
        mods: NSEvent.ModifierFlags, _ sessionId: String = FakeSession.first
    ) {
        guard let view = chats.terminal(sessionId)?.view else { return }
        // A synthetic drag has no real button down: the left button is down for the view until
        // the mouse up.
        view.pressedButtons = { 1 }
        defer { view.pressedButtons = { 0 } }
        let a = point(col: start.col, row: start.row, sessionId)
        let b = point(col: end.col, row: end.row, sessionId)
        func event(_ type: NSEvent.EventType, _ location: CGPoint) -> NSEvent? {
            NSEvent.mouseEvent(
                with: type, location: location, modifierFlags: mods,
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
                pressure: type == .leftMouseUp ? 0 : 1)
        }
        if let down = event(.leftMouseDown, a) { view.mouseDown(with: down) }
        for step in 1...8 {
            let t = CGFloat(step) / 8
            let p = CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
            if let drag = event(.leftMouseDragged, p) { view.mouseDragged(with: drag) }
        }
        if let up = event(.leftMouseUp, b) { view.mouseUp(with: up) }
    }

    // MARK: - The end

    // Detach all chats, wait until each attach child that the test started ended, then remove
    // the test home.
    package func close(sourceLocation: SourceLocation = #_sourceLocation) async {
        closed = true
        model.onChange = nil
        chats.detachAll()
        dictation?.stopAll()
        ptys.closeAll()
        filter = nil
        window.close()
        // A spawn in flight ends first: the manager then closes its child (the closeAll cancelled
        // its open).
        await waitUntil(sourceLocation: sourceLocation) {
            spawner.log.spawning == 0
        }
        await Task.yield()
        // Each child that the spawner started, also a child that a test closed or replaced.
        let started = spawner.log.pids
        await waitUntil(sourceLocation: sourceLocation) {
            started.allSatisfy { kill($0, 0) != 0 }
        }
        pasteboard.releaseGlobally()
        folder.remove()
    }

    private var closed = false

    // A test that stops early (a failed #require) does not call close. Then the deinit detaches
    // each chat (SIGHUP to each attach child) and removes the test home.
    isolated deinit {
        guard !closed else { return }
        model.onChange = nil
        chats.detachAll()
        dictation?.stopAll()
        ptys.closeAll()
        window.close()
        pasteboard.releaseGlobally()
        folder.remove()
    }
}

// The bytes of a text, for a compare with the input of a session.
@MainActor
package func bytes(_ text: String) -> [UInt8] { Array(text.utf8) }

// True when the bytes hold the part.
@MainActor
package func contains(_ bytes: [UInt8], _ part: [UInt8]) -> Bool {
    bytes.firstRange(of: part) != nil
}
