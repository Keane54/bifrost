import AppKit
import BifrostFoundation
import BifrostSessions
import BifrostTestSupport
import Foundation
import Testing

@testable import BifrostChat
@testable import BifrostDictation
@testable import BifrostKeyboard
@testable import BifrostLayout
@testable import BifrostLook
@testable import BifrostWindows

// The dictation of a chat window on a real PTY with the fake attach of
// scripts/fake-claude and the fake speech engine. The hold key is Space, through the window key
// filter. No test opens the microphone, asks for a permission, downloads a speech model or plays
// audio. The window is never ordered front.

@MainActor
private let final = FakeSpeechScript.helperText

// A chat with the fake engine: open, attached and focused, with Space as the dictation key.
@MainActor
private func dictationChat(_ script: FakeSpeechScript = .helper) async throws -> (
    ChatFixture, ChatTerminal, FrameID
) {
    let space = KeySlot.dictation.defaultBinding
    let chat = try ChatFixture(speech: script, dictationKey: .chord(space))
    let frame = chat.open()
    try #require(await chat.waitForAttach())
    let terminal = try chat.terminal()
    if chat.window.firstResponder !== terminal.view {
        _ = chat.window.makeFirstResponder(terminal.view)
    }
    try #require(chat.window.firstResponder === terminal.view)
    return (chat, terminal, frame)
}

@Suite("dictation of a chat", .serialized, .timeLimit(.minutes(3)), .tags(.realProcess, .window))
@MainActor
struct DictationTests {
    // A hold of Space types the text of
    // the fake helper into the session, and no space follows it. A tap types one space and opens
    // no dictation.
    @Test func aHoldDictatesAndATapTypesASpace() async throws {
        let (chat, terminal, _) = try await dictationChat()
        let engine = try #require(chat.speech)
        chat.keyDown("Space")
        await waitUntil { contains(chat.input(), bytes(final)) }
        #expect(terminal.dictationView.phase == .listening)
        chat.keyUp("Space")
        await waitUntil { terminal.dictationView.phase == .off }
        let typed = await chat.inputBeforeMarker()
        #expect(typed.suffix(final.utf8.count).elementsEqual(final.utf8))
        let after = chat.input()
        chat.keyDown("Space")
        chat.keyUp("Space")
        await waitUntil { chat.input() == after + bytes(" ") }
        #expect(await chat.inputBeforeMarker() == after + bytes(" "))
        #expect(engine.microphoneOpens == 1)
        #expect(engine.microphoneCloses == 1)
        #expect(engine.overlaps == 0)
        await chat.close()
    }

    // A new attach clears the end of the typed text: the first dictation of
    // the new attach gets no leading space for the text of the older attach.
    @Test func aNewAttachClearsTheTypedText() async throws {
        let (chat, terminal, _) = try await dictationChat()
        chat.type("abc")
        await waitUntil { contains(chat.input(), bytes("abc")) }
        // The attach ends, and the window attaches again.
        chat.ptys.attach(FakeSession.chatView())?.close()
        terminal.exited(code: 0)
        #expect(terminal.state.ended)
        terminal.restart()
        await waitUntil { chat.attachLines.count == 2 && terminal.state.attached }
        if chat.window.firstResponder !== terminal.view {
            _ = chat.window.makeFirstResponder(terminal.view)
        }
        chat.keyDown("Space")
        await waitUntil { contains(chat.input(), bytes(final)) }
        chat.keyUp("Space")
        #expect(contains(chat.input(), bytes("abc" + final)))
        #expect(!contains(chat.input(), bytes("abc " + final)))
        await chat.close()
    }

    // The cyan top line of the frame turns green, the glow and the shadow show, and the title bar
    // shows the meter, only while the chat listens. A model download shows no green look.
    @Test func theFrameShowsTheGreenLookOnlyWhileListening() async throws {
        let (chat, terminal, frame) = try await dictationChat()
        let view = try #require(chat.canvas.frameView(frame))
        let cyan = view.look.topLine
        #expect(!view.isDictating)
        chat.keyDown("Space")
        await waitUntil { view.isDictating }
        #expect(terminal.dictationView.phase == .listening)
        #expect(!view.titleBar.meter.isHidden)
        #expect(view.dictationParts.allSatisfy { !$0.isHidden })
        // The last level of the fake engine is 0.7. The display link of a window that is not on
        // a screen can wait, so the test gives the frames.
        await waitUntil { view.dictationTarget == 0.7 }
        for _ in 0..<30 { view.smoothDictation(seconds: 1.0 / 60) }
        #expect(view.dictationLevel > 0.6)
        let look = DictationLook.of(level: view.dictationLevel)
        #expect(view.look.topLine == DictationGlow.green(look.borderAlpha))
        #expect(view.look.glow == 0)
        #expect(view.dictationEdgeLayer.backgroundColor == DictationGlow.green(look.borderAlpha))
        #expect(abs(view.titleBar.meter.bar.fill - view.dictationLevel) < 1e-9)
        chat.keyUp("Space")
        await waitUntil { !view.isDictating }
        #expect(view.titleBar.meter.isHidden)
        #expect(view.dictationParts.allSatisfy { $0.isHidden })
        #expect(view.look.topLine == cyan)
        #expect(view.look.glow == 1)
        #expect(!view.displayLinkRuns)
        await chat.close()

        // The focus of the chat warms the engine, and its download waits.
        var download = FakeSpeechScript.helper
        download.download = [0, 0.5]
        download.holdsDownload = true
        let (second, held, other) = try await dictationChat(download)
        let otherView = try #require(second.canvas.frameView(other))
        second.keyDown("Space")
        await waitUntil { held.dictationView.phase == .downloading(progress: 0.5) }
        #expect(!otherView.isDictating)
        second.speech?.finishDownload()
        await waitUntil { held.dictationView.notice == .modelReady }
        #expect(held.dictationView.phase == .downloaded)
        #expect(!otherView.isDictating)
        #expect(second.speech?.microphoneOpens == 0)
        second.keyUp("Space")
        await second.close()
    }

    // A hold after a no to the microphone shows the notice with its button. The button opens the
    // Microphone pane of System Settings (a fake opener). The microphone never opens, and the
    // held key types its text.
    @Test func theNoticeOfADeniedMicrophoneOpensSystemSettings() async throws {
        var script = FakeSpeechScript.helper
        script.permission = .denied
        let (chat, terminal, _) = try await dictationChat(script)
        let before = chat.input()
        chat.keyDown("Space")
        await waitUntil { terminal.dictationView.notice == .error(.micDenied) }
        let notice = terminal.body.dictationNotice
        #expect(!notice.isHidden)
        #expect(notice.label.stringValue == DictationNoticeText.error(.micDenied))
        #expect(!notice.button.isHidden)
        #expect(notice.button.title == "Open System Settings")
        chat.keyUp("Space")
        await waitUntil { chat.input() == before + bytes(" ") }
        notice.button.performClick(nil)
        #expect(
            chat.openedURLs.map(\.absoluteString) == [
                "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"
            ])
        #expect(chat.speech?.microphoneOpens == 0)
        // A notice with no button takes no pointer input.
        #expect(notice.hitTest(NSPoint(x: 1, y: 1)) == nil)
        await chat.close()
    }

    // The microphone closes at each end of a dictation in a chat window: the
    // release, a blur, Esc, Ctrl+C, a blocking choice, the 2-minute limit, an engine error, a
    // chat close, a window close and a quit (the calls of the shell). The fake engine counts each
    // open and close.
    @Test func everyEndPathClosesTheMicrophone() async throws {
        let (chat, first, _) = try await dictationChat()
        let engine = try #require(chat.speech)
        let service = try #require(chat.dictation)
        var terminal = first
        func listen() async throws {
            try #require(await waitUntil { terminal.dictationView.phase == .off })
            chat.keyDown("Space")
            let listening = await waitUntil {
                engine.microphoneOpen && terminal.dictationView.phase == .listening
            }
            try #require(listening)
        }
        func closed(_ path: String) async {
            let done = await waitUntil {
                !engine.microphoneOpen && engine.microphoneOpens == engine.microphoneCloses
            }
            #expect(done, "\(path)")
        }
        // The release.
        try await listen()
        chat.keyUp("Space")
        await closed("release")
        // A blur: the chat loses the key focus.
        try await listen()
        _ = chat.window.makeFirstResponder(nil)
        await closed("blur")
        chat.keyUp("Space")
        _ = chat.window.makeFirstResponder(terminal.view)
        // Esc and Ctrl+C.
        try await listen()
        chat.key("Escape")
        await closed("Esc")
        chat.keyUp("Space")
        try await listen()
        chat.key("c", [.ctrl])
        await closed("Ctrl+C")
        chat.keyUp("Space")
        // A blocking choice: the row shows a red box.
        try await listen()
        var red = FakeSession.row(folder: chat.home)
        red.alert = .red(.prompt, since: 1)
        let rows = chat.rows
        chat.rows = [red]
        chat.sync()
        await closed("a blocking choice")
        chat.keyUp("Space")
        chat.rows = rows
        chat.sync()
        // The 2-minute limit, on the clock of the service.
        try await listen()
        chat.speechClock.advance(by: DictationService.holdLimit)
        await closed("the 2-minute limit")
        chat.keyUp("Space")
        // An engine error.
        try await listen()
        engine.failSession(.failed)
        await closed("an engine error")
        chat.keyUp("Space")
        // A chat close.
        try await listen()
        chat.model.apply(.close(chat.panel()))
        await closed("a chat close")
        // A window close: the shell detaches each chat and stops the service at once.
        chat.open()
        try #require(await chat.waitForAttach())
        terminal = try chat.terminal()
        _ = chat.window.makeFirstResponder(terminal.view)
        try await listen()
        chat.chats.detachAll()
        service.stopAll()
        await closed("a window close")
        // A quit: the service stops at once (Shell.detach and AppServices.stop).
        chat.sync()
        try #require(await chat.waitForAttach())
        terminal = try chat.terminal()
        _ = chat.window.makeFirstResponder(terminal.view)
        try await listen()
        service.stopAll()
        await closed("a quit")
        #expect(engine.microphoneOpens == 10)
        #expect(engine.overlaps == 0)
        await chat.close()
    }

    // detachAll stops the dictation of each chat: the service gets the
    // stop, the microphone closes, and the frame loses the green look.
    @Test func detachAllStopsEachDictation() async throws {
        let (chat, _, frame) = try await dictationChat()
        let engine = try #require(chat.speech)
        let view = try #require(chat.canvas.frameView(frame))
        chat.keyDown("Space")
        await waitUntil { engine.microphoneOpen && view.isDictating }
        chat.chats.detachAll()
        await waitUntil { !engine.microphoneOpen }
        #expect(engine.microphoneOpens == engine.microphoneCloses)
        #expect(!view.isDictating)
        chat.keyUp("Space")
        await chat.close()
    }

    // A focused chat warms the speech engine only with a dictation key.
    @Test func aChatWarmsTheEngineOnlyWithADictationKey() async throws {
        let (chat, terminal, _) = try await dictationChat()
        let engine = try #require(chat.speech)
        let filter = try #require(chat.filter)
        await waitUntil { engine.downloads == 1 }
        chat.dictation?.stopAll()
        filter.setKeys(KeyMap([.dictation: .off]))
        _ = chat.window.makeFirstResponder(nil)
        let service = try #require(chat.dictation)
        #expect(!service.isBooted)
        _ = chat.window.makeFirstResponder(terminal.view)
        // A warm starts the boot in the same turn, so the focus gain started none.
        #expect(!service.isBooted)
        #expect(engine.downloads == 1)
        filter.setKeys(.defaults)
        _ = chat.window.makeFirstResponder(nil)
        _ = chat.window.makeFirstResponder(terminal.view)
        #expect(service.isBooted)
        await waitUntil { engine.downloads == 2 }
        await chat.close()
    }

    // An event of the service goes only to a chat that has a PTY: after the PTY goes, a new level
    // does not reach the frame. The PTY goes after the end of the script of the fake engine: the
    // whole text is in the session, so the typer writes nothing more. A write of the typer to a
    // PTY that went ends the window, and the end of the window stops the dictation.
    @Test func anEventGoesOnlyToAChatWithAPTY() async throws {
        let (chat, terminal, frame) = try await dictationChat()
        let engine = try #require(chat.speech)
        let view = try #require(chat.canvas.frameView(frame))
        chat.keyDown("Space")
        let scriptEnded = await waitUntil {
            view.dictationTarget == 0.7 && contains(chat.input(), bytes(final))
        }
        #expect(scriptEnded)
        engine.emit(.level(0.3))
        await waitUntil { view.dictationTarget == 0.3 }
        chat.ptys.attach(FakeSession.chatView())?.close()
        engine.emit(.level(0.9))
        // The failure of the session comes after the level on the same stream. When the service
        // has the failure, the hold timer stops, and the chat stream has the level before it.
        let service = try #require(chat.dictation)
        let timers = service.runningTimers
        engine.failSession(.failed)
        await waitUntil { service.runningTimers == timers - 1 }
        // A new listen ends the stream of the chat after those events. The listen of the chat
        // then ends, after it read each event.
        let listen = try #require(chat.chats.dictationListen(FakeSession.first))
        _ = service.listen(for: try #require(SessionID(FakeSession.first)))
        await listen.value
        #expect(view.dictationTarget == 0.3)
        #expect(!terminal.state.ended)
        chat.keyUp("Space")
        await chat.close()
    }

    // The end of the PTY stops a dictation of the chat, and the
    // microphone closes.
    @Test func theEndOfThePTYStopsTheDictation() async throws {
        let (chat, terminal, _) = try await dictationChat()
        let engine = try #require(chat.speech)
        chat.keyDown("Space")
        await waitUntil { engine.microphoneOpen && terminal.dictationView.phase == .listening }
        terminal.exited(code: 1)
        #expect(terminal.state.ended)
        await waitUntil { !engine.microphoneOpen }
        #expect(engine.microphoneOpens == engine.microphoneCloses)
        chat.keyUp("Space")
        await chat.close()
    }

    // A start for a chat with no PTY is refused with the friendly text. The
    // service gets no start, and the microphone never opens.
    @Test func aStartWithNoTerminalIsRefused() async throws {
        let (chat, terminal, _) = try await dictationChat()
        let engine = try #require(chat.speech)
        // The PTY goes. A close gives no exit code, so the chat still counts as attached.
        chat.ptys.attach(FakeSession.chatView())?.close()
        chat.keyDown("Space")
        await waitUntil {
                terminal.dictationView.notice == .refused(.noTerminal)
            }
        chat.keyUp("Space")
        #expect(engine.microphoneOpens == 0)
        #expect(engine.prepares <= 1)
        await chat.close()
    }
}
