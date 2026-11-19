import AppKit
import BifrostLayout
import BifrostSessions
import BifrostSettings
import BifrostTestSupport
import BifrostWindows
import Foundation
import SwiftTerm
import Testing

@testable import BifrostChat
@testable import BifrostKeyboard
@testable import BifrostLook

// One chat terminal in a window that is never ordered front. The tests of the keys, the mouse
// and the screen use the fake PTY of the fixture: the input is each write of the chat, and the
// size timers run on a manual clock. These tests run on a real PTY with the fake attach of
// scripts/fake-claude: the attach, a file link with its real path, the scroll back with a new
// attach, OSC 52, the focus reports of a new attach, a refused open, the exit line, the close
// with its SIGHUP, and the session size of a window that is not focused. A test home in a
// TemporaryFolder holds the files of that fake.
@Suite("chat terminal", .serialized, .timeLimit(.minutes(2)), .tags(.realProcess, .window))
@MainActor
struct ChatTerminalTests {
    // Open the chat of the first session, focused, and wait for the fake attach.
    private func attached(_ chat: ChatFixture) async throws -> ChatTerminal {
        chat.open()
        try #require(await chat.waitForAttach(), "The fake attach did not start.")
        return try chat.terminal()
    }

    @Test func aChatOpensTheAttachOfItsSession() async throws {
        let chat = try ChatFixture()
        // The panel opens at the rect that the layout gives it.
        chat.model.apply(.open(chat.panel()))
        try #require(await chat.waitForAttach(), "The fake attach did not start.")
        let terminal = try chat.terminal()
        #expect(chat.attachLines == ["FAKE ATTACH 5a0e0001"])
        await waitUntil { chat.screen().contains("FAKE ATTACH 5a0e0001") }
        #expect(terminal.state.attached)
        #expect(terminal.state.note == nil)
        #expect(chat.ptys.list().map(\.view) == [FakeSession.chatView()])
        // The focused window opens at the fit of its panel (the body below the title bar) with
        // the cells of SF Mono 13: 8 x 16 points. The PTY opens at the fit too, so the attach
        // needs no resize. (The view comes before the row, so the first attach knows that the
        // window shows.)
        let panel = terminal.body.bounds.size
        #expect(panel.width > 300)
        #expect(panel.height > 200)
        let fit = TerminalSize(cols: Int(panel.width / 8), rows: Int(panel.height / 16))
        #expect(terminal.view.terminalDimensions.cols == fit.cols)
        #expect(terminal.view.terminalDimensions.rows == fit.rows)
        #expect(chat.spawner.log.opens == [fit])
        await chat.close()
    }

    // The settings of the terminal gate and of docs/behaviour/chat.md.
    @Test func theTerminalHasTheSettingsOfTheGate() throws {
        UITestApp.prepare()
        let view = ChatTerminalView(
            sessionId: FakeSession.first,
            font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular))
        // The background is the token of the terminal background: fully clear.
        #expect(view.nativeBackgroundColor == ThemeTokens.terminalBackground.nsColor)
        #expect(view.nativeBackgroundColor.alphaComponent == 0)
        #expect(view.nativeForegroundColor == ThemeTokens.text.nsColor)
        #expect(!view.optionAsMetaKey)
        #expect(view.optionAsMetaKeyForFunctionalKeys)
        #expect(view.linkReporting == .implicit)
        #expect(view.linkHighlightMode == .hoverWithModifier)
        #expect(view.allowMouseReporting)
        #expect(view.bellStyle == .none)
        #expect(view.terminalDelegate === view)
        let event = try #require(
            USKeyboard.keyEvent(
                down: true, id: "k", mods: [.meta], isRepeat: false,
                window: NSWindow(
                    contentRect: .zero, styleMask: [], backing: .buffered, defer: true)))
        #expect(view.shouldSendCommandKeyToTerminal?(event) == false)
        // The start size: 120 x 32.
        #expect(view.terminalDimensions.cols == 120)
        #expect(view.terminalDimensions.rows == 32)
    }

    @Test func typedTextReachesTheSession() async throws {
        let chat = try ChatFixture(fakePTY: true)
        let terminal = try await attached(chat)
        await waitUntil { chat.window.firstResponder === terminal.view }
        chat.type("hello")
        await waitUntil { chat.input() == bytes("hello") }
        await chat.close()
    }

    @Test func shiftEnterSendsEscCR() async throws {
        let chat = try ChatFixture(fakePTY: true)
        let terminal = try await attached(chat)
        await waitUntil { chat.window.firstResponder === terminal.view }
        chat.key("Enter", [.shift])
        #expect(
            await waitUntil { chat.input() == bytes("\u{1b}\r") },
            "input: \(chat.input()), state: \(terminal.state)")
        await chat.close()
    }

    // The tests have no real input method. The composition is marked text, as an input method
    // sets it. The Bifrost rule does not take Shift+Enter, and SwiftTerm gives the key to the
    // text input system (interpretKeyEvents). With no input method there, the key binding of
    // the text system gives a CR. A real input method keeps the key.
    @Test func shiftEnterDuringACompositionGoesToTheInputMethod() async throws {
        let chat = try ChatFixture(fakePTY: true)
        let terminal = try await attached(chat)
        await waitUntil { chat.window.firstResponder === terminal.view }
        terminal.view.setMarkedText(
            "か", selectedRange: NSRange(location: 1, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(terminal.view.isComposing)
        chat.key("Enter", [.shift])
        await waitUntil { !chat.input().isEmpty }
        #expect(terminal.view.hasMarkedText())
        terminal.view.unmarkText()
        #expect(await chat.inputBeforeMarker() == bytes("\r"))
        await chat.close()
    }

    // Option+E is a dead key. Option types the character of the layout, so the key goes to the
    // input method and not to the Meta rule (which sends ESC e). The input method shows the
    // accent as marked text, and the next E commits one character.
    @Test func aDeadKeyTypesOneComposedCharacter() async throws {
        let chat = try ChatFixture(fakePTY: true)
        let terminal = try await attached(chat)
        await waitUntil { chat.window.firstResponder === terminal.view }
        chat.key("e", [.alt])
        // The composed character below is the marker: the session gets only its bytes.
        #expect(chat.input().isEmpty, "Option+E went to the session.")
        terminal.view.setMarkedText(
            "´", selectedRange: NSRange(location: 1, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: 0))
        terminal.view.insertText("é", replacementRange: NSRange(location: NSNotFound, length: 0))
        await waitUntil { chat.input() == bytes("é") }
        #expect(chat.input() == [0xc3, 0xa9])
        await chat.close()
    }

    // The Character Viewer inserts the emoji in the first responder.
    @Test func anInsertedEmojiReachesTheSession() async throws {
        let chat = try ChatFixture(fakePTY: true)
        let terminal = try await attached(chat)
        terminal.view.insertText("😀", replacementRange: NSRange(location: NSNotFound, length: 0))
        await waitUntil { chat.input() == bytes("😀") }
        await chat.close()
    }

    // The screen turns on the SGR mouse reports and shows an OSC 8 link at the top left.
    @Test func cmdClickOpensALinkAndAPlainClickGoesToClaude() async throws {
        let chat = try ChatFixture(fakePTY: true)
        let link = "https://example.com/bifrost-chat-test"
        try chat.writeScreen(
            "\u{1b}[2J\u{1b}[H\u{1b}[?1000h\u{1b}[?1006h"
                + "\u{1b}]8;;\(link)\u{1b}\\LINK TEXT\u{1b}]8;;\u{1b}\\")
        _ = try await attached(chat)
        await waitUntil { chat.screen().hasPrefix("LINK TEXT") }
        chat.click(col: 2, row: 0, command: true)
        await waitUntil { !chat.links.isEmpty }
        #expect(chat.links == [.openWeb(try #require(URL(string: link)))])
        // SwiftTerm also reports the press of the Cmd+click. The fake attach can write it to its
        // file late under load, so the plain click waits for it.
        await waitUntil { chat.input() == bytes("\u{1b}[<0;3;1M") }
        let before = chat.input()
        let clicks = chat.linkOpener.clicks
        chat.click(col: 2, row: 0, command: false)
        // The plain click is no link click.
        #expect(chat.linkOpener.clicks == clicks)
        let reports = bytes("\u{1b}[<0;3;1M\u{1b}[<0;3;1m")
        #expect(
            await waitUntil { chat.input() == before + reports },
            "input: \(chat.input()), before: \(before)")
        #expect(chat.links.count == 1)
        await chat.close()
    }

    // A file link: the action holds the real path of the file. A link to a symbolic
    // link of a script shows the script in Finder, and a link to a document opens the real path
    // of the document. The fake opener only records the actions.
    @Test func aCmdClickOnAFileLinkUsesTheRealPath() async throws {
        let chat = try ChatFixture()
        let folder = chat.folder.appending("links")
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        try "echo hi\n".write(toFile: "\(folder)/go.command", atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(
            atPath: "\(folder)/plain-name", withDestinationPath: "\(folder)/go.command")
        try "notes\n".write(toFile: "\(folder)/notes.txt", atomically: true, encoding: .utf8)
        try chat.writeScreen(
            "\u{1b}[2J\u{1b}[H\u{1b}]8;;file://\(folder)/plain-name\u{1b}\\SCRIPT\u{1b}]8;;\u{1b}\\"
                + "\r\n\u{1b}]8;;file://\(folder)/notes.txt\u{1b}\\NOTES\u{1b}]8;;\u{1b}\\")
        _ = try await attached(chat)
        await waitUntil { chat.screen().contains("NOTES") }
        chat.click(col: 1, row: 0, command: true)
        await waitUntil { chat.links.count == 1 }
        chat.click(col: 1, row: 1, command: true)
        await waitUntil { chat.links.count == 2 }
        // The test home is in /tmp, and the real path of /tmp is /private/tmp.
        let real = "/private\(folder)"
        #expect(
            chat.links == [
                .showInFinder("\(real)/go.command"), .openFile("\(real)/notes.txt", app: nil),
            ])
        await chat.close()
    }

    // A plain URL in the text is a link too (SwiftTerm finds it). A Cmd+click opens it, and a
    // plain click opens nothing.
    @Test func aCmdClickOnAPlainURLOpensIt() async throws {
        let chat = try ChatFixture(fakePTY: true)
        let link = "https://example.com/bifrost-plain-url"
        try chat.writeScreen("\u{1b}[2J\u{1b}[Hsee \(link) here")
        _ = try await attached(chat)
        await waitUntil { chat.screen().contains(link) }
        // The plain click is no link click.
        chat.click(col: 12, row: 0, command: false)
        #expect(chat.linkOpener.clicks == 0)
        chat.click(col: 12, row: 0, command: true)
        await waitUntil { !chat.links.isEmpty }
        #expect(chat.links == [.openWeb(try #require(URL(string: link)))])
        await chat.close()
    }

    // Option+drag makes a normal selection of the text, across the rows, also while Claude Code
    // reads the mouse, and the session gets no mouse report (macOptionClickForcesSelection). A
    // block selection would hold only the columns 2 to 6 of each row. A plain drag goes to
    // Claude Code.
    @Test func optionDragSelectsTheTextAndSendsNoMouseReport() async throws {
        let chat = try ChatFixture(fakePTY: true)
        try chat.writeScreen(
            "\u{1b}[2J\u{1b}[H\u{1b}[?1000h\u{1b}[?1006hfirst line here\r\nsecond line")
        let terminal = try await attached(chat)
        await waitUntil { chat.screen().contains("second line") }
        let before = chat.input()
        chat.drag(from: (6, 0), to: (2, 1), mods: [.option])
        let selection = try #require(terminal.view.getSelection())
        #expect(selection.hasPrefix("line here"))
        #expect(selection.contains("\n"))
        #expect(await chat.inputBeforeMarker() == before)
        // The control: a plain drag sends the press and the release reports.
        chat.drag(from: (6, 0), to: (2, 1), mods: [])
        await waitUntil { contains(chat.input(), bytes("\u{1b}[<0;7;1M")) }
        await chat.close()
    }

    // A lost mouse up (a drag with no left button down) ends an Option
    // press, so a later drag does not get Shift.
    @Test func aDragWithNoLeftButtonEndsTheOptionPress() async throws {
        let chat = try ChatFixture(fakePTY: true)
        let terminal = try await attached(chat)
        let view = terminal.view
        var buttons = 1
        view.pressedButtons = { buttons }
        let location = chat.point(col: 2, row: 1)
        func event(_ type: NSEvent.EventType, _ mods: NSEvent.ModifierFlags) throws -> NSEvent {
            try #require(
                NSEvent.mouseEvent(
                    with: type, location: location, modifierFlags: mods,
                    timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: chat.window.windowNumber, context: nil, eventNumber: 0,
                    clickCount: 1, pressure: 1))
        }
        view.mouseDown(with: try event(.leftMouseDown, [.option]))
        #expect(view.optionPress)
        // A drag with the left button down keeps the press.
        view.mouseDragged(with: try event(.leftMouseDragged, [.option]))
        #expect(view.optionPress)
        // The mouse up did not come: a drag with no left button down ends the press.
        buttons = 0
        view.mouseDragged(with: try event(.leftMouseDragged, []))
        #expect(!view.optionPress)
        await chat.close()
    }

    // The chat drops a key down of Cmd with a printable character
    // (aCmdKeyWithTextGoesNowhere). Its repeats and its key up go nowhere too, also after Cmd
    // went up, so a kitty repeat or release never comes without its press. A new key down of
    // the code starts again: then its key up goes to the terminal.
    @Test func theKeyUpOfADroppedCmdKeyGoesNowhere() async throws {
        let chat = try ChatFixture(fakePTY: true)
        try chat.writeScreen("\u{1b}[>3u")
        let terminal = try await attached(chat)
        await waitUntil { !terminal.view.keyboardEnhancementFlags.isEmpty }
        func takes(_ event: KeyEvent) -> Bool { terminal.chatKey(event, dictationKey: nil) }
        let k = KeyCode(rawValue: 40)
        let up = KeyEvent(keyCode: k, characters: "k", isDown: false)
        #expect(takes(KeyEvent(keyCode: k, characters: "k", modifiers: .command)))
        #expect(takes(KeyEvent(keyCode: k, characters: "k", isRepeat: true)))
        #expect(takes(up))
        // A second key up is not a key of the dropped press.
        #expect(!takes(up))
        // A plain press of the key: its key down and its key up go to the terminal.
        #expect(!takes(KeyEvent(keyCode: k, characters: "k")))
        #expect(!takes(up))
        // Through the window: Cmd+K, then the key up with no Cmd. The session gets no byte.
        await waitUntil { chat.window.firstResponder === terminal.view }
        let before = chat.input()
        chat.key("k", [.meta])
        if let release = USKeyboard.keyEvent(
            down: false, id: "k", mods: [], isRepeat: false, window: chat.window)
        {
            chat.window.sendEvent(release)
        }
        #expect(await chat.inputBeforeMarker() == before)
        await chat.close()
    }

    // The scroll bar has the tokens of the theme (docs/behaviour/chat.md).
    // The scroller of SwiftTerm draws nothing (alpha 0) and keeps the clicks and the drags. The
    // slider draws its knob in terminalSlider, and in terminalSliderHover under the pointer. The
    // background is terminalBackground. The alternate screen shows no slider.
    @Test func theScrollBarHasTheColoursOfTheTokens() async throws {
        let chat = try ChatFixture(fakePTY: true)
        try chat.writeScreen((1...800).map { "line \($0)" }.joined(separator: "\r\n"))
        let terminal = try await attached(chat)
        let view = terminal.view
        #expect(view.nativeBackgroundColor == ThemeTokens.terminalBackground.nsColor)
        await waitUntil { view.scrollerStyle == .legacy }
        let scroller = try #require(view.subviews.compactMap { $0 as? NSScroller }.first)
        #expect(scroller.alphaValue == 0)
        #expect(!view.slider.isHidden)
        #expect(view.slider.frame == scroller.frame)
        let middle = NSPoint(x: scroller.frame.midX, y: scroller.frame.midY)
        #expect(view.slider.hitTest(middle) == nil)
        #expect(view.slider.colour == ThemeTokens.terminalSlider)
        func crossing(_ type: NSEvent.EventType) throws -> NSEvent {
            try #require(
                NSEvent.enterExitEvent(
                    with: type, location: .zero, modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: chat.window.windowNumber, context: nil, eventNumber: 0,
                    trackingNumber: 0, userData: nil))
        }
        view.slider.mouseEntered(with: try crossing(.mouseEntered))
        #expect(view.slider.colour == ThemeTokens.terminalSliderHover)
        view.slider.mouseExited(with: try crossing(.mouseExited))
        #expect(view.slider.colour == ThemeTokens.terminalSlider)
        // A reset clears the lines: no history, no slider.
        try chat.terminal().received(bytes("\u{1b}[?1049h"))
        await waitUntil { view.slider.isHidden }
        await chat.close()
    }

    // A mouse report of the legacy encoding (mode 1000 with no 1006) past column 94 has bytes
    // that are not UTF-8. The session gets them as they are, not as U+FFFD.
    @Test func aReplyThatIsNotUTF8KeepsItsBytes() async throws {
        let chat = try ChatFixture(fakePTY: true)
        try chat.writeScreen("\u{1b}[?1000hmouse on")
        chat.open(at: rect(0, 0, 1150, 400))
        try #require(await chat.waitForAttach())
        let terminal = try chat.terminal()
        #expect(terminal.view.terminalDimensions.cols > 101)
        // The terminal read the mode before the click: the text after it shows. Under load the
        // output of the attach can come after the start of cat.
        try #require(await waitUntil { chat.screen().contains("mouse on") })
        chat.click(col: 100, row: 0, command: false)
        // CSI M, the button 0 (32), the column 101 (133) and the row 1 (33).
        await waitUntil { contains(chat.input(), [0x1b, 0x5b, 0x4d, 32, 133, 33]) }
        #expect(!contains(chat.input(), [0xef, 0xbf, 0xbd]))
        await chat.close()
    }

    // SwiftTerm resizes its own grid when its frame changes, for example when it measures the
    // cells again on a screen with another backing scale. The grid goes back to the size of the
    // core, and the PTY gets no resize.
    @Test func aGridOfAnotherSizeGoesBackToTheCoreSize() async throws {
        let chat = try ChatFixture(fakePTY: true)
        chat.model.apply(.open(chat.panel()))
        try #require(await chat.waitForAttach())
        let terminal = try chat.terminal()
        let before = terminal.view.terminalDimensions
        terminal.view.frame.size = CGSize(width: 400, height: 200)
        #expect(terminal.view.terminalDimensions.cols == before.cols)
        #expect(terminal.view.terminalDimensions.rows == before.rows)
        await chat.advance(by: .seconds(1))
        #expect(chat.fakeChild()?.resizes == [])
        await chat.close()
    }

    // The agent view check reads the live screen, not the rows of the scroll position. The user
    // scrolls back, then the session draws the agent view at the bottom of the live screen (with
    // no new line, so the scroll position stays). The window attaches again.
    @Test func theScreenReadIsTheLiveScreenDuringAScrollBack() async throws {
        let chat = try ChatFixture()
        try chat.writeScreen((1...300).map { "line \($0)" }.joined(separator: "\r\n"))
        let terminal = try await attached(chat)
        await waitUntil { chat.screen().contains("line 300") }
        terminal.view.scrollUp(lines: 100)
        #expect(!chat.screen().contains("line 300"))
        let rows = terminal.view.terminalDimensions.rows
        let draw =
            "\u{1b}[\(rows - 2);1H0 awaiting input · 0 working · 6 completed"
            + "\u{1b}[\(rows);1Henter to return · space to reply · ? for shortcuts"
        terminal.received(bytes(draw))
        #expect(!chat.screen().contains("enter to return"))
        await waitUntil { chat.attachLines.count >= 2 }
        await chat.close()
    }

    @Test func osc52CopiesToThePasteboard() async throws {
        let chat = try ChatFixture()
        let text = Data("copied by Claude".utf8).base64EncodedString()
        try chat.writeScreen("\u{1b}]52;c;\(text)\u{7}")
        _ = try await attached(chat)
        await waitUntil { chat.pasteboard.string(forType: .string) == "copied by Claude" }
        await chat.close()
    }

    // The screen turns on focus reports (1004) and bracketed paste (2004).
    private static let modes = "\u{1b}[?1004h\u{1b}[?2004h"

    @Test func bracketedPasteWrapsAPaste() async throws {
        let chat = try ChatFixture(fakePTY: true)
        try chat.writeScreen(Self.modes)
        let terminal = try await attached(chat)
        let view = terminal.view
        await waitUntil { view.terminalInputStateSnapshot()?.bracketedPasteMode == true }
        view.pasteText("pasted text")
        let wrapped = bytes("\u{1b}[200~pasted text\u{1b}[201~")
        await waitUntil { contains(chat.input(), wrapped) }
        await chat.close()
    }

    // Without the mode, a focus change sends nothing. After Claude turns the mode on, a focus
    // loss sends CSI O and a focus gain sends CSI I.
    @Test func focusReportsGoOutWhenClaudeTurnsThemOn() async throws {
        let chat = try ChatFixture()
        var terminal = try await attached(chat)
        await waitUntil { chat.window.firstResponder === terminal.view }
        _ = chat.window.makeFirstResponder(nil)
        _ = chat.window.makeFirstResponder(terminal.view)
        #expect(await chat.inputBeforeMarker().isEmpty)
        // A new attach of the session shows a screen that turns the modes on.
        try chat.writeScreen(Self.modes)
        chat.model.apply(.close(chat.panel()))
        try FileManager.default.removeItem(atPath: chat.inputPath())
        terminal = try await attached(chat)
        await waitUntil {
            terminal.view.terminalInputStateSnapshot()?.focusReportingEnabled == true
        }
        await waitUntil { chat.window.firstResponder === terminal.view }
        // One focus loss and gain first, so each report of the start has come.
        _ = chat.window.makeFirstResponder(nil)
        _ = chat.window.makeFirstResponder(terminal.view)
        await waitUntil { chat.input().suffix(6) == ArraySlice(bytes("\u{1b}[O\u{1b}[I")) }
        let start = chat.input()
        _ = chat.window.makeFirstResponder(nil)
        await waitUntil { chat.input() == start + bytes("\u{1b}[O") }
        _ = chat.window.makeFirstResponder(terminal.view)
        await waitUntil { chat.input() == start + bytes("\u{1b}[O\u{1b}[I") }
        await chat.close()
    }

    // The chat checks the rows again before the open. Two rows with the short ID of the
    // chat: the attach is not for one owned session, so the open fails, and nothing attaches.
    @Test func aRefusedOpenDoesNotAttach() async throws {
        let other = "0f0f0f0f-0000-4000-8000-00000000000f"
        let chat = try ChatFixture(rows: { folder in
            var twin = FakeSession.row(other, folder: folder, kind: .external)
            twin.shortId = ShortID(FakeSession.shortId(FakeSession.first))
            return [FakeSession.row(folder: folder), twin]
        })
        chat.open()
        let terminal = try chat.terminal()
        await waitUntil { terminal.state.ended }
        #expect(chat.screen().contains("[open failed: \(AttachRefusal.notOwnedAttach.message)]"))
        #expect(chat.ptys.list().isEmpty)
        #expect(chat.spawner.log.opens.isEmpty)
        #expect(chat.attachLines.isEmpty)
        await chat.close()
    }

    // The attach child ends by itself (here by a signal of the test to its own child): the
    // window writes the end line and does not attach again.
    @Test func anExitShowsTheEndLine() async throws {
        let chat = try ChatFixture()
        let terminal = try await attached(chat)
        let child = try #require(chat.ptys.list().first?.pid)
        kill(child, SIGTERM)
        await waitUntil { terminal.state.ended }
        await waitUntil { chat.screen().contains("[process ended: code 0]") }
        #expect(!terminal.state.attached)
        // The end line is the last step of the end: no new attach came before it, and none
        // comes after it, because the window does not attach again (ChatAttachTests).
        #expect(chat.attachLines.count == 1)
        await chat.close()
    }

    // A chat that another frame covers gives the keyboard focus back to its window. A focus gain
    // gives it to the terminal again.
    @Test func aChatThatLosesTheFocusGivesUpTheKeyboard() async throws {
        let chat = try ChatFixture(fakePTY: true)
        let terminal = try await attached(chat)
        await waitUntil { chat.window.firstResponder === terminal.view }
        chat.openPanel(panel("watchlist"), at: rect(700, 0, 300, 300))
        #expect(chat.window.firstResponder !== terminal.view)
        let frame = try #require(chat.model.layout.frame(of: chat.panel()))
        chat.model.apply(.focus(frame.id))
        await waitUntil { chat.window.firstResponder === terminal.view }
        await chat.close()
    }

    // A close sends SIGHUP to the attach child only. The stand-in session process
    // has the pid of the row, in its own process group, and lives on.
    @Test func closingAChatLeavesTheSessionRunning() async throws {
        let standIn = try StandInProcess()
        defer { standIn.stop() }
        let chat = try ChatFixture(rows: {
            [FakeSession.row(folder: $0, pid: standIn.pid)]
        })
        _ = try await attached(chat)
        let child = try #require(chat.ptys.list().first?.pid)
        #expect(child != standIn.pid)
        chat.model.apply(.close(chat.panel()))
        // One SIGHUP, by the pid of the attach child.
        let signals = chat.spawner.log.signals
        #expect(signals.map(\.pid) == [child])
        #expect(signals.map(\.signal) == [.hangup])
        #expect(chat.chats.terminal(FakeSession.first) == nil)
        #expect(chat.ptys.attach(FakeSession.chatView()) == nil)
        #expect(await waitUntil { kill(child, 0) != 0 }, "The attach child did not end.")
        // Only the attach child got a signal (the records above), so the session runs on.
        #expect(standIn.alive, "The session process ended.")
        await chat.close()
    }

    // A minimised frame and a back tab hide the chat. The terminal then drops Metal and leaves
    // its superview, and the PTY stays. A visible chat goes back and draws with Metal again.
    @Test func aHiddenTerminalDropsItsMetalRenderer() async throws {
        let chat = try ChatFixture(fakePTY: true)
        let frame = chat.open()
        try #require(await chat.waitForAttach())
        let terminal = try chat.terminal()
        let pid = try #require(chat.ptys.list().first?.pid)
        #expect(terminal.state.metal)
        #expect(terminal.view.superview === terminal.body.host)
        chat.model.apply(.minimise(frame))
        #expect(!terminal.state.metal)
        #expect(terminal.view.superview == nil)
        chat.model.apply(.restore(frame))
        #expect(terminal.state.metal)
        #expect(terminal.view.superview === terminal.body.host)
        // A back tab.
        let other = chat.openPanel(panel("watchlist"), at: rect(700, 0, 300, 300))
        chat.model.apply(.stack(other, onto: frame))
        #expect(chat.model.layout.frame(of: chat.panel())?.active == panel("watchlist"))
        #expect(!terminal.state.metal)
        #expect(terminal.view.superview == nil)
        chat.model.apply(.activate(chat.panel()))
        #expect(terminal.state.metal)
        #expect(terminal.view.superview === terminal.body.host)
        #expect(chat.ptys.list().map(\.pid) == [pid])
        #expect(chat.attachLines.count == 1)
        await chat.close()
    }

    @Test func theFontFollowsTheSettingAndTheScale() async throws {
        let chat = try ChatFixture(fakePTY: true)
        let terminal = try await attached(chat)
        // The default: SF Mono 13, the monospaced system font, at the scale 100.
        #expect(terminal.view.font == NSFont.monospacedSystemFont(ofSize: 13, weight: .regular))
        chat.chats.setFont(
            TerminalFont(family: "SF Mono", size: 15), metrics: CanvasMetrics(interfaceScale: 120))
        #expect(terminal.view.font == NSFont.monospacedSystemFont(ofSize: 18, weight: .regular))
        chat.chats.setFont(
            TerminalFont(family: "Menlo", size: 12), metrics: CanvasMetrics(interfaceScale: 100))
        #expect(terminal.view.font.fontName == "Menlo-Regular")
        #expect(terminal.view.font.pointSize == 12)
        // The fit follows the new cells: the grid fills the panel with whole cells.
        let cell = terminal.view.getOptimalFrameSize().size
        let grid = terminal.view.terminalDimensions
        let width = cell.width / CGFloat(grid.cols)
        let height = cell.height / CGFloat(grid.rows)
        let panel = terminal.body.bounds.size
        #expect(grid.cols == Int((panel.width / width).rounded(.down)))
        #expect(grid.rows == Int((panel.height / height).rounded(.down)))
        // A new chat gets the font of the setting.
        chat.rows.append(FakeSession.row(FakeSession.second, folder: chat.home))
        chat.open(FakeSession.second, at: rect(650, 0, 300, 300))
        #expect(try chat.terminal(FakeSession.second).view.font.fontName == "Menlo-Regular")
        await chat.close()
    }

    // A chat that is not focused opens at the session size of the other clients (250 x 60 from
    // the fake process inspector), and zooms it to fit its panel, with the pointer blocker. The
    // grid of 250 x 60 cells of 8 x 16 points is 2000 x 960 points.
    @Test func anUnfocusedChatShowsTheSessionSizeScaled() async throws {
        // The rows come after the layout, so the chat attaches when it is not focused.
        let chat = try ChatFixture(size: TerminalSize(cols: 250, rows: 60), rows: { _ in [] })
        chat.open(at: rect(0, 0, 500, 300))
        chat.openPanel(panel("watchlist"), at: rect(600, 0, 300, 300))
        // No process has this pid. The fake inspector reads no process.
        chat.rows = [FakeSession.row(folder: chat.home, pid: 4_000_000)]
        chat.sync()
        try #require(await chat.waitForAttach())
        let terminal = try chat.terminal()
        let reads = chat.sizes.calls
        #expect(reads.first == .terminalDevice(4_000_000))
        #expect(reads.dropFirst().first == .terminalSize("/dev/ttys900"))
        #expect(terminal.view.terminalDimensions.cols == 250)
        #expect(terminal.view.terminalDimensions.rows == 60)
        let panel = terminal.body.bounds.size
        let zoom = min(1, Double(panel.width) / 2000, Double(panel.height) / 960)
        #expect(zoom < 0.3)
        #expect(terminal.body.scale == zoom)
        #expect(!terminal.body.blocker.isHidden)
        let transform = try #require(terminal.body.host.layer?.sublayerTransform)
        #expect(CATransform3DEqualToTransform(transform, CATransform3DMakeScale(zoom, zoom, 1)))
        // The host is flipped, so the layer of the terminal is at the origin of the host layer,
        // the point that the scale keeps in place: the top left corner.
        #expect(terminal.body.host.isFlipped)
        #expect(terminal.view.layer?.frame.origin == .zero)
        // The window gets the focus: the session gets the fit, and the zoom and the blocker go.
        let frame = try #require(chat.model.layout.frame(of: chat.panel()))
        chat.model.apply(.focus(frame.id))
        await waitUntil { terminal.body.scale == 1 }
        #expect(terminal.body.blocker.isHidden)
        await chat.close()
    }

    // SwiftTerm calls sizeChanged each time that its grid changes. That call never resizes the
    // PTY: only the focused window sends a size, after the quiet time of the size rule. Here the
    // other clients give the session a new size. The window that is not focused follows it, and
    // the PTY gets no resize. The focus gain then sends the fit.
    @Test func theGridOfSwiftTermNeverResizesThePTY() async throws {
        let chat = try ChatFixture(
            size: TerminalSize(cols: 250, rows: 60), rows: { _ in [] }, fakePTY: true)
        chat.open(at: rect(0, 0, 500, 300))
        chat.openPanel(panel("watchlist"), at: rect(600, 0, 300, 300))
        chat.rows = [FakeSession.row(folder: chat.home, pid: 4_000_000)]
        chat.sync()
        try #require(await chat.waitForAttach())
        let terminal = try chat.terminal()
        #expect(chat.fakes.spawns.map(\.size) == [TerminalSize(cols: 250, rows: 60)])
        // Within 500 ms of the open, another session size is an old read (SizeRule).
        await chat.advance(by: .milliseconds(700))
        // A redraw of the session after a resize by another client.
        chat.sizes.size = TerminalSize(cols: 200, rows: 50)
        terminal.received(bytes("\u{1b}[2J"))
        // The read of the session size waits for its quiet time on the clock of the chats.
        await chat.advance(by: .seconds(1))
        await waitUntil { terminal.view.terminalDimensions.cols == 200 }
        #expect(terminal.view.terminalDimensions.rows == 50)
        await chat.advance(by: .seconds(1))
        #expect(chat.fakeChild()?.resizes == [])
        let frame = try #require(chat.model.layout.frame(of: chat.panel()))
        chat.model.apply(.focus(frame.id))
        let panel = terminal.body.bounds.size
        let fit = TerminalSize(cols: Int(panel.width / 8), rows: Int(panel.height / 16))
        await chat.advance(by: .seconds(1))
        await waitUntil { chat.fakeChild()?.resizes == [fit] }
        #expect(terminal.view.terminalDimensions.cols == fit.cols)
        await chat.close()
    }

    // The screen prints 800 numbered lines on the normal screen. The terminal keeps 500 lines
    // above the screen, and the scroll bar shows.
    @Test func theScrollbackIs500Lines() async throws {
        #expect(ChatTerminalView.scrollback == 500)
        let chat = try ChatFixture(fakePTY: true)
        try chat.writeScreen((1...800).map { "line \($0)" }.joined(separator: "\r\n"))
        let terminal = try await attached(chat)
        await waitUntil { chat.screen().contains("line 800") }
        let rows = terminal.view.terminalDimensions.rows
        let all = try #require(terminal.view.terminalContentSnapshot(region: .all))
        #expect(all.rows.count == 500 + rows)
        #expect(terminal.view.scrollerStyle == .legacy)
        await chat.close()
    }

    // The scroll bar shows only while the normal screen has lines above it. The alternate
    // screen of claude attach has none.
    @Test func theAlternateScreenShowsNoScrollBar() async throws {
        let chat = try ChatFixture(fakePTY: true)
        try chat.writeScreen(
            "\u{1b}[?1049h" + (1...200).map { "line \($0)" }.joined(separator: "\r\n"))
        let terminal = try await attached(chat)
        await waitUntil { chat.screen().contains("line 200") }
        #expect(terminal.view.scrollerStyle == .overlay)
        await chat.close()
    }

    @Test func theCoreGraphicsSettingGivesNoMetal() async throws {
        let chat = try ChatFixture(renderer: .cg, fakePTY: true)
        let terminal = try await attached(chat)
        #expect(terminal.view.window != nil)
        #expect(!terminal.state.metal)
        // The hidden setting: "cg" gives Core Graphics, each other value and no value give
        // Metal. The registration domain is in memory only.
        let defaults = try #require(UserDefaults(suiteName: "com.example.app.chat-tests"))
        #expect(TerminalRenderer.read(defaults) == .metal)
        defaults.register(defaults: [TerminalRenderer.defaultsKey: "cg"])
        #expect(TerminalRenderer.read(defaults) == .cg)
        defaults.register(defaults: [TerminalRenderer.defaultsKey: "metal"])
        #expect(TerminalRenderer.read(defaults) == .metal)
        await chat.close()
    }

    // SwiftTerm gives a Cmd key to the program from performKeyEquivalent, before the key filter,
    // when the program turned on the kitty keyboard protocol and shouldSendCommandKeyToTerminal
    // says yes. The chat says no, so each Bifrost Cmd key gets to the key filter.
    @Test func everyBifrostCmdKeyStaysOutOfTheTerminalWithTheKittyProtocol() async throws {
        let chat = try ChatFixture(fakePTY: true)
        try chat.writeScreen("\u{1b}[>1u")
        let terminal = try await attached(chat)
        await waitUntil { !terminal.view.keyboardEnhancementFlags.isEmpty }
        await waitUntil { chat.window.firstResponder === terminal.view }
        let keys = KeyMap.defaults
        let active = keys.activeBindings.map(\.chord.description).filter { $0.hasPrefix("Mod+") }
        let menu = [keys[.closePanel], keys[.toggleFullscreen]].compactMap(\.chord?.description)
        // The list holds the Cmd keys of the key table, for example the first and the last.
        #expect(active.contains("Mod+N"))
        #expect(active.contains("Mod+,"))
        #expect(menu == ["Mod+W", "Mod+Control+F"])
        let before = chat.input()
        // With the setting of the chat, no Bifrost Cmd key goes to the terminal before the
        // filter. The menu gets the two menu keys next.
        for binding in active + menu {
            let event = try #require(Self.event(binding, window: chat.window), "\(binding)")
            #expect(!chat.window.performKeyEquivalent(with: event), "\(binding)")
        }
        // Each other Bifrost Cmd key acts in the filter, and the session gets no byte of it.
        for binding in active {
            let event = try #require(Self.event(binding, window: chat.window), "\(binding)")
            chat.window.sendEvent(event)
        }
        #expect(chat.commands.count == active.count)
        #expect(await chat.inputBeforeMarker() == before)
        // The control: with a yes, the terminal takes the key before the filter.
        let setting = terminal.view.shouldSendCommandKeyToTerminal
        let probe = try #require(Self.event("Mod+K", window: chat.window))
        terminal.view.shouldSendCommandKeyToTerminal = { _ in true }
        #expect(chat.window.performKeyEquivalent(with: probe))
        terminal.view.shouldSendCommandKeyToTerminal = setting
        await chat.close()
    }

    // A Cmd key with a printable character that no Bifrost key and no menu item takes goes
    // nowhere, as in xterm.js. With the kitty keyboard protocol on, SwiftTerm would send it to
    // Claude Code as a super key.
    @Test func aCmdKeyWithTextGoesNowhere() async throws {
        let chat = try ChatFixture(fakePTY: true)
        try chat.writeScreen("\u{1b}[>1u")
        let terminal = try await attached(chat)
        await waitUntil { !terminal.view.keyboardEnhancementFlags.isEmpty }
        await waitUntil { chat.window.firstResponder === terminal.view }
        let before = chat.input()
        chat.key("k", [.meta])
        chat.key("e", [.meta])
        chat.key("k", [.meta, .shift])
        chat.key(";", [.meta])
        #expect(await chat.inputBeforeMarker() == before)
        #expect(chat.commands.isEmpty)
        // The control: the same key with no Cmd goes to Claude Code.
        let marked = chat.input()
        chat.key("k")
        await waitUntil { chat.input().count > marked.count }
        await chat.close()
    }

    // Cmd+Space, also with Shift or Option, goes nowhere. The space bar is a named key.
    @Test func cmdSpaceGoesNowhere() async throws {
        let chat = try ChatFixture(fakePTY: true)
        try chat.writeScreen("\u{1b}[>1u")
        let terminal = try await attached(chat)
        await waitUntil { !terminal.view.keyboardEnhancementFlags.isEmpty }
        let space = KeyCode(rawValue: 49)
        for mods: KeyEvent.Modifiers in [[.command], [.command, .shift], [.command, .option]] {
            let event = KeyEvent(keyCode: space, characters: " ", modifiers: mods)
            #expect(terminal.chatKey(event, dictationKey: nil))
        }
        // The control: Space with no Cmd goes to the terminal.
        #expect(!terminal.chatKey(KeyEvent(keyCode: space, characters: " "), dictationKey: nil))
        await chat.close()
    }

    // The key down of a binding such as "Mod+Shift+M" on the US keyboard.
    static func event(_ binding: String, window: NSWindow) -> NSEvent? {
        var parts = binding.split(separator: "+").map(String.init)
        guard let key = parts.popLast() else { return nil }
        let names: [String: USKeyboard.Mod] = [
            "Mod": .meta, "Shift": .shift, "Control": .ctrl, "Alt": .alt,
        ]
        let mods = Set(parts.compactMap { names[$0] })
        let id = key.count == 1 ? key.lowercased() : key
        return USKeyboard.keyEvent(down: true, id: id, mods: mods, isRepeat: false, window: window)
    }
}
