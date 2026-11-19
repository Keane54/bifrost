import AppKit
import BifrostFoundation
import BifrostLook
import BifrostSessions
import BifrostTestSupport
import Testing

@testable import BifrostDictation
@testable import BifrostKeyboard
@testable import BifrostLayout
@testable import BifrostSettings
@testable import BifrostWindows

// The window key filter with the key commands of the app (the public init), and the end of the
// responder chain of the window: an Esc or a Tab that no Bifrost key uses goes to AppKit. The
// window is never ordered front.
@Suite("window key filter", .serialized, .timeLimit(.minutes(1)), .tags(.window))
@MainActor
struct WindowKeyFilterTests {
    static let s1 = "11111111-1111-4111-8111-111111111111"
    static let s2 = "22222222-2222-4222-8222-222222222222"

    // A window with the filter of the app. The layout has the Overview and a stack of
    // selected-item and the chat of S1.
    @MainActor
    private final class Parts {
        let folder: TemporaryFolder
        let window: RecordingWindow
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        let model = WindowLayoutModel(layout: WindowLayout(bounds: LayoutSize(w: 1200, h: 800)))
        let rows = FakeRowSource()
        let selection: SelectionModel
        let store: UIStateStore
        let commands: KeyCommands
        let filter: WindowKeyFilter
        var opened: [String] = []

        // dictation keeps the dictation key of the key map (Space), else the key is Off.
        init(custom: KeyChanges = [:], dictation: Bool = false) async throws {
            let list = SessionListModel.reading(rows)
            selection = SelectionModel(list: list)
            UITestApp.prepare()
            folder = try TemporaryFolder()
            store = await UIStateStore.open(
                file: folder.url.appending(path: "ui-state.json"), clock: ManualClock(),
                log: Recorder<StoreEvent>())
            window = RecordingWindow(
                contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled],
                backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.actsAsKey = true
            window.contentView = content
            let frames = [
                SavedFrame(
                    panels: [panel("overview:1")], active: panel("overview:1"),
                    rect: rect(0, 0, 300, 200), minimised: false, locked: false),
                SavedFrame(
                    panels: [panel("selected-item"), panel("chat:\(s1)")],
                    active: panel("chat:\(s1)"), rect: rect(0, 0, 300, 200), minimised: false,
                    locked: false),
            ]
            model.apply(.load(LayoutSnapshot(frames: frames, memory: [:])))
            rows.apply(ids: [s1, s2])
            selection.selectedId = s2
            var openSink: (String) -> Void = { _ in }
            commands = KeyCommands(
                layout: model, sideBar: SideBarModel(layout: model, store: store),
                selection: selection,
                overviews: .test(
                    store: store, sessions: list, selection: selection, layout: model),
                openChat: { openSink($0) }, menu: { _ in })
            // The dictation key is Off unless the test asks for it.
            var changes = custom
            if !dictation { changes.set(.off, for: .dictation) }
            filter = WindowKeyFilter(
                window: window, commands: commands, selection: selection, keys: KeyMap(changes))
            openSink = { [unowned self] in self.opened.append($0) }
        }

        func send(
            _ id: String, _ mods: Set<USKeyboard.Mod> = [], down: Bool = true,
            isRepeat: Bool = false
        ) {
            guard
                let event = USKeyboard.keyEvent(
                    down: down, id: id, mods: mods, isRepeat: isRepeat, window: window)
            else { return }
            window.sendEvent(event)
        }

        func add<V: NSView>(_ view: V) -> V {
            content.addSubview(view)
            return view
        }

        deinit { folder.remove() }
    }

    // While a dialog shows, a field of the dialog gets the repeats and the release of a held key,
    // for example a held Backspace in the name field. After the close of the dialog, the repeats
    // of a key that the dialog had stay out of the views.
    @Test func aHeldKeyInADialogFieldGivesItsRepeatsToTheField() async throws {
        let p = try await Parts()
        let host = DialogHost(look: PanelLook(), clock: ManualClock())
        let layer = p.add(host.view)
        layer.isHidden = false
        let field = KeyRecordingView(frame: NSRect(x: 0, y: 0, width: 50, height: 50))
        layer.addSubview(field)
        p.window.openDialog = layer
        #expect(p.window.makeFirstResponder(field))
        p.send("Backspace")
        p.send("Backspace", isRepeat: true)
        p.send("Backspace", isRepeat: true)
        p.send("Backspace", down: false)
        #expect(field.keys.count == 3)
        p.send("Enter")
        p.window.openDialog = nil
        p.send("Enter", isRepeat: true)
        p.send("Enter", down: false)
        #expect(field.keys.count == 4)
    }

    // While a dialog shows, each key is in the dialog zone, also when the first responder is
    // outside the dialog: a Bifrost key does not act, and the view gets the key.
    @Test func aBifrostKeyDoesNotActWhileADialogShows() async throws {
        let p = try await Parts()
        let view = p.add(KeyRecordingView(frame: NSRect(x: 0, y: 0, width: 50, height: 50)))
        #expect(p.window.makeFirstResponder(view))
        let host = DialogHost(look: PanelLook(), clock: ManualClock())
        p.window.openDialog = p.add(host.view)
        p.send("]", [.meta])
        #expect(p.model.layout.topFrame?.active == panel("chat:\(Self.s1)"))
        #expect(view.keys == ["]"])
        p.window.openDialog = nil
        p.send("]", [.meta])
        #expect(p.model.layout.topFrame?.active == panel("selected-item"))
    }

    // A key of the key layer runs its command in the app: Cmd+] activates the next tab of the
    // top frame, and the view does not get the key.
    @Test func aBifrostKeyRunsItsCommandAndTheViewDoesNotGetIt() async throws {
        let p = try await Parts()
        #expect(p.window.filter === p.filter)
        let view = p.add(KeyRecordingView(frame: NSRect(x: 0, y: 0, width: 50, height: 50)))
        #expect(p.window.makeFirstResponder(view))
        p.send("]", [.meta])
        #expect(p.model.layout.topFrame?.active == panel("selected-item"))
        #expect(view.keys.isEmpty)
        // A key that is not a Bifrost key goes to the view.
        p.send("q")
        #expect(view.keys == ["q"])
    }

    // While a Bifrost menu shows over the window, the window stays the key window and gives each
    // key down to the menu: a Bifrost key does not act, and the view gets no key. After the close,
    // the keys act again.
    @Test func anOpenMenuTakesEachKeyDown() async throws {
        let p = try await Parts()
        let view = p.add(KeyRecordingView(frame: NSRect(x: 0, y: 0, width: 50, height: 50)))
        #expect(p.window.makeFirstResponder(view))
        let driver = MenuDriver()
        driver.show([.item(MenuItemSpec(id: "alpha", label: "Alpha"))], in: p.window)
        p.send("]", [.meta])
        p.send("q")
        p.send("ArrowDown")
        #expect(p.model.layout.topFrame?.active == panel("chat:\(Self.s1)"))
        #expect(view.keys.isEmpty)
        #expect(driver.menu.panels.first?.list.state.highlighted == 0)
        driver.menu.close()
        p.send("]", [.meta])
        #expect(p.model.layout.topFrame?.active == panel("selected-item"))
    }

    // The user holds the dictation key in a chat, and a menu opens over the window (a click on
    // the menu button). The release of the key still goes to the chat input, so the dictation
    // stops. The key up does not reach the menu.
    @Test func aHeldDictationKeyStopsAtItsReleaseWhileAMenuShows() async throws {
        let p = try await Parts(dictation: true)
        let state = GateState()
        state.logging = true
        let clock = ManualClock()
        let host = TerminalHost(state: state, holdTime: ChatInput.holdTime, clock: clock)
        host.view.sessionId = Self.s1
        _ = p.add(host.view)
        #expect(p.window.makeFirstResponder(host.view))
        p.send("Space")
        await clock.waitForSleepers(1)
        clock.advance(by: ChatInput.holdTime)
        #expect(await waitUntil { state.log.last == "dict:start" })
        let driver = MenuDriver()
        driver.show([.item(MenuItemSpec(id: "alpha", label: "Alpha"))], in: p.window)
        // The chat keeps the focus, and the window stays the key window.
        #expect(p.window.firstResponder === host.view)
        p.send("Space", down: false)
        #expect(state.log.last == "dict:stop")
        #expect(state.pty.isEmpty)
        #expect(driver.menu.isOpen)
        #expect(driver.chosen.isEmpty)
        #expect(driver.menu.panels.first?.list.state.highlighted == nil)
        driver.menu.close()
    }

    // A key that a menu takes never reaches the chat: not its release while the menu shows, and
    // not its repeats or its release after it closed the menu. The release of a key that went
    // down in the chat before the menu opened still reaches the chat.
    @Test func aKeyThatTheMenuTakesNeverReachesTheChat() async throws {
        let p = try await Parts()
        let chat = p.add(StandInChatView())
        chat.sessionId = Self.s1
        var keys: [(down: Bool, code: UInt16)] = []
        chat.onKey = { event, _ in
            keys.append((event.isDown, event.keyCode.rawValue))
            return false
        }
        #expect(p.window.makeFirstResponder(chat))
        p.send("q")
        let driver = MenuDriver()
        driver.show([.item(MenuItemSpec(id: "alpha", label: "Alpha"))], in: p.window)
        p.send("q", down: false)
        #expect(keys.map(\.down) == [true, false])
        keys = []
        p.send("ArrowDown")
        p.send("ArrowDown", down: false)
        #expect(driver.menu.panels.first?.list.state.highlighted == 0)
        // Return chooses the row and closes the menu. Its repeats and its release stay out of
        // the chat, so no carriage return reaches the session.
        p.send("Enter")
        #expect(driver.chosen == ["alpha"])
        #expect(!driver.menu.isOpen)
        p.send("Enter", isRepeat: true)
        p.send("Enter", isRepeat: true)
        p.send("Enter", down: false)
        #expect(keys.isEmpty)
        // The next press of a key goes to the chat again.
        p.send("Enter")
        #expect(keys.map(\.down) == [true])
    }

    // A primary mouse down on a row with O held claims the key, and the click then opens the
    // chat of the row and keeps the selection (open:hold, D8). A plain click is a selection.
    @Test func aRowClickWithAHeldHoldKeyRunsTheHoldCommand() async throws {
        let p = try await Parts()
        p.send("o")
        p.filter.rowPress(Self.s1)
        #expect(p.filter.rowClick(Self.s1))
        p.send("o", down: false)
        #expect(p.opened == [Self.s1])
        #expect(p.selection.selectedId == Self.s2)
        p.filter.rowPress(Self.s1)
        #expect(!p.filter.rowClick(Self.s1))
        #expect(p.opened == [Self.s1])
    }

    // At a blur of the window no key up comes. So the key layer forgets the held hold keys: the
    // next row click is a plain click, and the key up does not run the key either.
    @Test func aWindowBlurForgetsTheHeldHoldKeys() async throws {
        let p = try await Parts()
        p.send("o")
        p.window.resignKey()
        p.filter.rowPress(Self.s1)
        #expect(!p.filter.rowClick(Self.s1))
        p.send("o", down: false)
        #expect(p.opened.isEmpty)
        // With no blur, the key up of O opens the chat of the selected row (open:key).
        p.send("o")
        p.send("o", down: false)
        #expect(p.opened == [Self.s2])
    }

    // The dictation key is Off. Space in a chat goes to the terminal as a normal key, and only
    // stops a dictation, as each key does. A focus of the chat warms nothing.
    @Test func spaceInAChatIsANormalKeyWithTheDictationKeyOff() async throws {
        let p = try await Parts()
        let state = GateState()
        state.logging = true
        let host = TerminalHost(state: state, holdTime: ChatInput.holdTime, clock: ManualClock())
        host.view.sessionId = Self.s1
        _ = p.add(host.view)
        #expect(p.window.makeFirstResponder(host.view))
        #expect(state.log == [])
        // A focus in the chat selected its session.
        #expect(p.selection.selectedId == Self.s1)
        p.send("Space")
        p.send("Space", down: false)
        #expect(state.pty == Array(" ".utf8))
        #expect(host.input.holdTimer == nil)
        #expect(state.log == ["dict:interrupt"])
    }

    // An Esc that is not a Bifrost key gets to AppKit: in a full screen, cancelOperation: ends
    // it. The Esc slot is Off here, and a dialog keeps its own Esc.
    @Test func anEscThatIsNotABifrostKeyGoesToAppKit() async throws {
        let off = try await Parts(custom: [keySlot("escape:key"): .off])
        #expect(off.window.makeFirstResponder(nil))
        off.send("Escape")
        #expect(off.window.cancelOperations == 1)
        let p = try await Parts()
        let dialog = p.add(PassingView(frame: NSRect(x: 0, y: 0, width: 100, height: 100)))
        dialog.identifier = FocusMark.modal
        #expect(p.window.makeFirstResponder(dialog))
        p.send("Escape")
        #expect(p.window.cancelOperations == 1)
    }

    // An Esc of the key layer that acts (it opens or closes Settings) stays with Bifrost, also
    // on a control. A key repeat of Esc has no intent, so it goes to AppKit.
    @Test func anEscThatActsStaysWithBifrostAndARepeatGoesToAppKit() async throws {
        let p = try await Parts()
        #expect(p.window.makeFirstResponder(nil))
        p.send("Escape")
        #expect(p.window.cancelOperations == 0)
        let button = p.add(FocusableButton(frame: NSRect(x: 0, y: 0, width: 80, height: 30)))
        #expect(p.window.makeFirstResponder(button))
        p.send("Escape")
        #expect(p.window.cancelOperations == 0)
        let repeated = try #require(
            USKeyboard.keyEvent(
                down: true, id: "Escape", mods: [], isRepeat: true, window: p.window))
        p.window.sendEvent(repeated)
        #expect(p.window.cancelOperations == 1)
    }

    // A Tab that the key layer does not use moves the focus in the key-view loop. A control
    // keeps Tab, so the key goes to AppKit. In the other zone, Tab is the key of the next
    // Overview tab, so the focus stays.
    @Test func aTabThatIsNotABifrostKeyMovesTheKeyViewLoop() async throws {
        let p = try await Parts()
        let one = p.add(FocusableButton(frame: NSRect(x: 0, y: 0, width: 80, height: 30)))
        let two = p.add(FocusableButton(frame: NSRect(x: 100, y: 0, width: 80, height: 30)))
        one.nextKeyView = two
        two.nextKeyView = one
        #expect(p.window.makeFirstResponder(one))
        p.send("Tab")
        #expect(p.window.firstResponder === two)
        p.send("Tab", [.shift])
        #expect(p.window.firstResponder === one)
        let view = p.add(KeyRecordingView(frame: NSRect(x: 200, y: 0, width: 50, height: 50)))
        view.nextKeyView = one
        #expect(p.window.makeFirstResponder(view))
        p.send("Tab")
        #expect(p.window.firstResponder === view)
    }

    // A focused tab of a frame is a control. Return activates the tab, Tab
    // moves the focus in the key-view loop, and the arrow keys and the hold letters run no
    // Bifrost key. In the other zone they would run open:key2, the Overview tab keys,
    // select-next and the hold keys.
    @Test func returnTabAndArrowDownOnAFocusedTabGoToTheTab() throws {
        let p = FocusTargetTests.Parts()
        var commands: [String] = []
        let sinks = KeySinks(
            run: { commands.append($0.description) },
            hold: { slot, _ in commands.append(slot.description) },
            escape: { _ in }, settingsOnTop: { false })
        let selection = SelectionModel(list: SessionListModel())
        let filter = WindowKeyFilter(
            window: p.window, selection: selection, keys: KeyMap([.dictation: .off]), sinks: sinks)
        let stack = try FocusTargetTests.stackedCanvas(in: p)
        let model = stack.canvas.model
        let tab = try #require(stack.tabs.first)
        #expect(model.layout.topFrame?.active == panel("settings"))
        let next = p.add(FocusableButton(frame: NSRect(x: 0, y: 0, width: 80, height: 30)))
        tab.nextKeyView = next
        func send(_ id: String, _ mods: Set<USKeyboard.Mod> = []) {
            for down in [true, false] {
                guard
                    let event = USKeyboard.keyEvent(
                        down: down, id: id, mods: mods, isRepeat: false, window: p.window)
                else { continue }
                p.window.sendEvent(event)
            }
        }
        #expect(p.window.makeFirstResponder(tab))
        send("ArrowDown")
        send("o")
        #expect(p.window.firstResponder === tab)
        send("Tab")
        #expect(p.window.firstResponder === next)
        #expect(p.window.makeFirstResponder(tab))
        send("Enter")
        #expect(model.layout.topFrame?.active == panel("watchlist"))
        #expect(commands.isEmpty)
        withExtendedLifetime(filter) {}
    }

    // The window gives its key state to the filter: a blur makes the key layer forget its keys,
    // as no key up comes.
    @Test func theKeyStateOfTheWindowGoesToTheFilter() {
        UITestApp.prepare()
        let window = BifrostWindow(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 100), styleMask: [.titled],
            backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let filter = RecordingFilter()
        window.filter = filter
        window.becomeKey()
        window.resignKey()
        #expect(filter.keyStates == [true, false])
    }

    // MARK: - The key recorder

    // A key down as the app gives it: AppKit offers a key equivalent to the key window (and its
    // views), then to the main menu, and only then sends the key down to the window.
    private func appSend(
        _ p: Parts, _ id: String, _ mods: Set<USKeyboard.Mod> = [], menu: NSMenu
    ) {
        guard
            let event = USKeyboard.keyEvent(
                down: true, id: id, mods: mods, isRepeat: false, window: p.window)
        else { return }
        if p.window.performKeyEquivalent(with: event) { return }
        if menu.performKeyEquivalent(with: event) { return }
        p.window.sendEvent(event)
    }

    // The menu of the app with the default keys. Close Panel closes the active panel.
    private func menu(_ p: Parts) -> (NSMenu, MenuTarget) {
        let target = MenuTarget(commands: p.commands)
        let model = MenuModel.make(appName: "Bifrost Dev", keys: .defaults)
        return (MainMenu.build(model, target: target), target)
    }

    // A key recorder in the window, and the chords of the keys that it records.
    private func recorder(in p: Parts) -> (KeyRecorderView, () -> [String]) {
        let recorder = p.add(KeyRecorderView(frame: NSRect(x: 300, y: 0, width: 100, height: 30)))
        let keys = KeyList()
        recorder.onKey = { keys.items.append(Chord(event: $0)?.text ?? "none") }
        return (recorder, { keys.items })
    }

    // Cmd+W and Ctrl+Cmd+F during the recording are recorded. The menu does not get them, so no
    // panel closes and the display mode stays. The menu still shows its keys.
    @Test func cmdWDuringTheRecordingIsRecordedAndClosesNothing() async throws {
        let p = try await Parts()
        let (menu, target) = menu(p)
        let (recorder, keys) = recorder(in: p)
        let before = p.model.layout
        recorder.begin()
        appSend(p, "w", [.meta], menu: menu)
        appSend(p, "f", [.ctrl, .meta], menu: menu)
        appSend(p, "q", [.meta], menu: menu)
        #expect(keys() == ["Mod+W", "Mod+Control+F", "Mod+Q"])
        #expect(target.actions.isEmpty)
        #expect(p.model.layout == before)
        let close = menu.item(withTitle: "Window")?.submenu?.item(withTitle: "Close Panel")
        #expect(close?.keyEquivalent == "w")
        #expect(close?.keyEquivalentModifierMask == .command)
    }

    // The menu keeps its keys until a key records, and gets them again after the recording.
    @Test func theMenuKeepsItsKeysUntilAKeyRecordsThenGivesThemToTheRecorder() async throws {
        let p = try await Parts()
        let (menu, target) = menu(p)
        let (recorder, keys) = recorder(in: p)
        appSend(p, "w", [.meta], menu: menu)
        #expect(target.actions == [.closePanel])
        recorder.begin()
        appSend(p, "w", [.meta], menu: menu)
        #expect(keys() == ["Mod+W"])
        #expect(target.actions == [.closePanel])
        recorder.cancel()
        appSend(p, "w", [.meta], menu: menu)
        #expect(target.actions == [.closePanel, .closePanel])
        #expect(keys() == ["Mod+W"])
    }

    // During the recording no Bifrost key acts: Cmd keys, single keys, a hold key and Tab are
    // recorded and run nothing. Esc ends the recording and does not go to AppKit.
    @Test func aBifrostKeyDuringTheRecordingRunsNoCommand() async throws {
        let p = try await Parts()
        let (menu, _) = menu(p)
        let (recorder, keys) = recorder(in: p)
        let before = p.model.layout
        recorder.begin()
        appSend(p, "]", [.meta], menu: menu)
        appSend(p, "1", [.meta], menu: menu)
        appSend(p, "ArrowDown", menu: menu)
        appSend(p, "o", menu: menu)
        p.send("o", down: false)
        p.filter.rowPress(Self.s1)
        #expect(!p.filter.rowClick(Self.s1))
        appSend(p, "Tab", menu: menu)
        // A key down that the window sends to the filter goes to the recorder too.
        p.send("ArrowUp")
        #expect(keys() == ["Mod+]", "Mod+1", "ArrowDown", "O", "Tab", "ArrowUp"])
        #expect(p.model.layout == before)
        #expect(p.selection.selectedId == Self.s2)
        #expect(p.opened.isEmpty)
        #expect(p.window.firstResponder === recorder)
        appSend(p, "Escape", menu: menu)
        #expect(!recorder.isRecording)
        #expect(p.window.cancelOperations == 0)
        #expect(keys().count == 6)
        // After the recording, the keys act again.
        appSend(p, "]", [.meta], menu: menu)
        #expect(p.model.layout.topFrame?.active == panel("selected-item"))
    }

    // The recorder ends after a good key, as the Keys section ends it. The key up of that key
    // comes after the end and runs nothing: O opens no chat, as its key down never got to the
    // key layer.
    @Test func theKeyUpOfAGoodKeyRunsNothingAfterTheEnd() async throws {
        let p = try await Parts()
        let (menu, _) = menu(p)
        let recorder = p.add(KeyRecorderView(frame: NSRect(x: 300, y: 0, width: 100, height: 30)))
        let keys = KeyList()
        recorder.onKey = { [unowned recorder] in
            keys.items.append(Chord(event: $0)?.text ?? "none")
            recorder.cancel()
        }
        recorder.begin()
        appSend(p, "o", menu: menu)
        #expect(keys.items == ["O"])
        #expect(!recorder.isRecording)
        p.send("o", down: false)
        #expect(p.opened.isEmpty)
        #expect(p.selection.selectedId == Self.s2)
        p.filter.rowPress(Self.s1)
        #expect(!p.filter.rowClick(Self.s1))
    }

    // A modifier key during the recording goes to the recorder only: the view that holds it
    // does not get the event.
    @Test func aModifierKeyDuringTheRecordingDoesNotReachTheViews() async throws {
        let p = try await Parts()
        let holder = p.add(FlagsView(frame: NSRect(x: 300, y: 0, width: 100, height: 30)))
        let recorder = KeyRecorderView(frame: holder.bounds)
        holder.addSubview(recorder)
        recorder.begin()
        let shift = try #require(
            USKeyboard.modifierEvent(id: "Shift", mods: [.shift], window: p.window))
        p.window.sendEvent(shift)
        #expect(holder.flags == 0)
        #expect(recorder.isRecording)
        recorder.cancel()
        #expect(p.window.makeFirstResponder(holder))
        p.window.sendEvent(shift)
        #expect(holder.flags == 1)
    }

    // A Bifrost menu that opens during a recording ends the recording, for example a right-click
    // on a tab while Settings records a key. A Cmd key at the menu then never becomes a key
    // binding: the window does not take it as a key equivalent, so AppKit offers it to the menu
    // bar. The test sends no key to a menu bar: an item that acts would post a notification that
    // closes each open Bifrost menu of the other tests.
    @Test func aMenuThatOpensEndsTheRecording() async throws {
        let p = try await Parts()
        let (recorder, keys) = recorder(in: p)
        var ends = 0
        recorder.onEnd = { ends += 1 }
        recorder.begin()
        #expect(p.window.firstResponder === recorder)
        let driver = MenuDriver()
        driver.show([.item(MenuItemSpec(id: "alpha", label: "Alpha"))], in: p.window)
        defer { driver.menu.close() }
        #expect(!recorder.isRecording)
        #expect(ends == 1)
        #expect(p.window.firstResponder !== recorder)
        let cmdW = try #require(
            USKeyboard.keyEvent(
                down: true, id: "w", mods: [.meta], isRepeat: false, window: p.window))
        #expect(!p.window.performKeyEquivalent(with: cmdW))
        p.window.sendEvent(cmdW)
        #expect(keys().isEmpty)
        #expect(driver.menu.isOpen)
        // The Keys section removes the recorder after the end of its recording. The close of the
        // menu does not give the focus back to it.
        recorder.removeFromSuperview()
        driver.menu.close()
        #expect(p.window.firstResponder !== recorder)
        #expect(!p.window.performKeyEquivalent(with: cmdW))
        #expect(keys().isEmpty)
        #expect(ends == 1)
    }

    // The window gives a key equivalent to the recorder before any other view: a button with
    // the key Cmd+W comes first in the views, but the recorder records the key.
    @Test func theRecorderGetsAKeyEquivalentBeforeAnyOtherView() async throws {
        let p = try await Parts()
        let presses = KeyList()
        let action = ButtonAction { presses.items.append("Close") }
        let button = NSButton(title: "Close", target: action, action: #selector(ButtonAction.run))
        button.keyEquivalent = "w"
        button.keyEquivalentModifierMask = .command
        p.content.addSubview(button, positioned: .below, relativeTo: nil)
        let (recorder, keys) = recorder(in: p)
        recorder.begin()
        let event = try #require(
            USKeyboard.keyEvent(
                down: true, id: "w", mods: [.meta], isRepeat: false, window: p.window))
        #expect(p.window.performKeyEquivalent(with: event))
        #expect(keys() == ["Mod+W"])
        #expect(presses.items.isEmpty)
        // Without a recording the button gets the key.
        recorder.cancel()
        #expect(p.window.performKeyEquivalent(with: event))
        #expect(presses.items == ["Close"])
        withExtendedLifetime(action) {}
    }
}

// A view that counts the modifier changes that get to it.
private final class FlagsView: NSView {
    private(set) var flags = 0
    override var acceptsFirstResponder: Bool { true }
    override func flagsChanged(with event: NSEvent) { flags += 1 }
}

// A list that a closure of a test adds to.
@MainActor
private final class KeyList {
    var items: [String] = []
}

// The target of the Bifrost menu items, as in the app: Close Panel closes the active panel. It
// records the action of each item that it gets.
@MainActor
private final class MenuTarget: NSObject, MainMenuTarget {
    private let commands: KeyCommands
    private(set) var actions: [MenuItemModel.Action] = []

    init(commands: KeyCommands) {
        self.commands = commands
    }

    func runMenuItem(_ sender: NSMenuItem) {
        guard let action = MainMenu.action(of: sender) else { return }
        actions.append(action)
        if action == .closePanel { commands.run(.closePanel) }
    }
}

// The target of a button: it runs a closure.
@MainActor
private final class ButtonAction: NSObject {
    private let action: () -> Void

    init(_ action: @escaping () -> Void) {
        self.action = action
    }

    @objc func run() { action() }
}

// A view that records the key downs that it gets.
final class KeyRecordingView: NSView {
    private(set) var keys: [String] = []
    override var acceptsFirstResponder: Bool { true }
    override var canBecomeKeyView: Bool { true }
    override func keyDown(with event: NSEvent) { keys.append(event.characters ?? "") }
}

// A view that gives each key down to the next responder, as a view that does not use the key.
final class PassingView: NSView {
    override var acceptsFirstResponder: Bool { true }
}

// A filter that records the key state of the window.
@MainActor
final class RecordingFilter: WindowEventFilter {
    private(set) var keyStates: [Bool] = []
    func filter(_ event: NSEvent) -> Bool { false }
    func keyEquivalent(_ event: NSEvent) -> Bool { false }
    func dispatchEnded(_ event: NSEvent) {}
    func endOfChain(_ event: NSEvent) -> Bool { false }
    func focusChanged(from: NSResponder?, to: NSResponder?) {}
    func keyWindowChanged(_ isKey: Bool) { keyStates.append(isKey) }
}
