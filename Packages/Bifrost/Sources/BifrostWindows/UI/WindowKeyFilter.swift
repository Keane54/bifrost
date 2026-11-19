// The window key filter (docs/behaviour/keys.md). BifrostWindow.sendEvent calls filter(_:) before
// the views get each key event.
//
// The order of one key event:
// 0. The recorder zone: while the key recorder of Settings > Keys records, it takes each key event
//    and each key equivalent (keyEquivalent(_:)). No Bifrost key acts, the key layer keeps no
//    state of the key, and no other view and no menu item gets it. A Bifrost menu that opens ends
//    the recording (BifrostWindow.openMenu).
// 1. The key layer (KeyLayer of BifrostKeyboard): the Bifrost keys for the focus zone. A key that
//    acts stops the event.
// 2. In a chat window, the chat input of the chat (ChatKeyTarget): the dictation hold key, the stop
//    of a dictation at other keys, and Shift+Enter. A key that it takes does not go to the
//    terminal.
// 3. The views get the event. The terminal sends its text to the PTY through the data rule of the
//    chat input.
// 4. An Esc outside the send box acts only when it gets to the end of the responder chain, so a
//    view (a popover, a drag) can take it first.
//
// The three conditions of the key-rules gate (docs/archive/gates/key-rules/RESULTS.md):
// - A flags-changed event is the key down or the key up of its modifier key (KeyEvents.swift).
// - The Bifrost keys stay off the menus and the views: the menu has only the two menu slots, and a
//   key that acts never goes to a view.
// - A view gives an Esc that it does not use to the next responder.
import AppKit
import BifrostKeyboard
import BifrostSettings

// What the filter does with a key that acts. The app uses the key commands. The scenario test gives
// sinks that log each call.
@MainActor
package struct KeySinks {
    // The command of a slot.
    var run: (KeySlot) -> Void
    // The hold click of a hold slot on a row.
    var hold: (KeySlot, String) -> Void
    // The intent of Esc.
    var escape: (EscapeIntent) -> Void
    // True when Settings is the active panel of the top frame (for the Esc rule).
    var settingsOnTop: () -> Bool

    // The Esc of the send box moves the focus of the window, so the commands get the window.
    init(commands: KeyCommands, window: NSWindow) {
        run = { commands.run($0) }
        hold = { commands.runHold($0, row: $1) }
        escape = { [weak window] in commands.escape($0, in: window) }
        settingsOnTop = { commands.settingsOnTop }
    }

    package init(
        run: @escaping (KeySlot) -> Void, hold: @escaping (KeySlot, String) -> Void,
        escape: @escaping (EscapeIntent) -> Void, settingsOnTop: @escaping () -> Bool
    ) {
        self.run = run
        self.hold = hold
        self.escape = escape
        self.settingsOnTop = settingsOnTop
    }
}

@MainActor
public final class WindowKeyFilter: WindowEventFilter {
    // The physical key of the dictation key of the key map, or nil when the key is Off. The chat
    // input reads it.
    package private(set) var dictationKey: KeyCode?

    private weak var window: BifrostWindow?
    private let selection: SelectionModel
    private let sinks: KeySinks
    private(set) var layer: KeyLayer
    // An Esc that waits for the end of the dispatch: the event, the zone at the key down and the
    // repeat flag.
    private var pendingEscape: (event: NSEvent, zone: FocusZone, isRepeat: Bool)?
    // The zone of the press of each key that is down: its key down, or the press of a modifier
    // key. While a Bifrost menu shows, the release of a key that went down in a chat still goes to
    // the chat input, so a held dictation key stops. A key down that the menu took is in the modal
    // zone: its repeats and its release never reach a chat, also after the menu closed.
    private var pressZones: [KeyCode: FocusZone] = [:]

    // The filter becomes the filter of the window. The window keeps a weak reference, so the
    // owner of the window keeps the filter.
    public convenience init(
        window: BifrostWindow, commands: KeyCommands, selection: SelectionModel, keys: KeyMap
    ) {
        self.init(
            window: window, selection: selection, keys: keys,
            sinks: KeySinks(commands: commands, window: window))
    }

    package init(
        window: BifrostWindow, selection: SelectionModel, keys: KeyMap, sinks: KeySinks
    ) {
        self.window = window
        self.selection = selection
        self.sinks = sinks
        layer = KeyLayer(keys: keys)
        dictationKey = keys.dictationKey
        window.filter = self
    }

    // A new key map: a new key layer and a new dictation key. A waiting Esc goes.
    public func setKeys(_ keys: KeyMap) {
        layer = KeyLayer(keys: keys)
        dictationKey = keys.dictationKey
        pendingEscape = nil
    }

    // MARK: - The filter

    // True when the filter took the event: the views must not get it.
    package func filter(_ event: NSEvent) -> Bool {
        // The window gives each event. Only the key events need the focus.
        guard [.keyDown, .keyUp, .flagsChanged].contains(event.type) else { return false }
        if let recorder { return recorder.take(event) }
        let focus = KeyFocus(window?.firstResponder, in: window)
        guard let keyEvent = KeyEvent(event, isComposing: focus.isComposing) else { return false }
        // The repeats and the release of a key that the menu took stay out of the chats and the
        // views (for example a held Return that chose a row and closed the menu). While a dialog
        // shows with no menu over it, a field of the dialog gets the repeats and the release of a
        // held key, for example a held Backspace. After the close of the dialog, the repeats of
        // a key that it had stay out (a held Return that started a session).
        let dialogHasKeys = window?.dialogIsOpen == true && window?.menuIsOpen != true
        if event.type != .flagsChanged, !dialogHasKeys, pressZones[keyEvent.keyCode] == .modal,
            !keyEvent.isDown || keyEvent.isRepeat
        {
            if !keyEvent.isDown { pressZones[keyEvent.keyCode] = nil }
            return true
        }
        // While a Bifrost menu shows, the menu has the key downs (BifrostWindow.sendEvent), and
        // each other key event is in the modal zone for the key layer. While a dialog shows, each
        // key event is in the modal zone too. The release of a key whose press went to a chat goes
        // to the chat input of that chat too.
        let modalShows = window?.menuIsOpen == true || window?.dialogIsOpen == true
        let zone = modalShows ? FocusZone.modal : focus.zone
        let pressZone: FocusZone
        if keyEvent.isDown {
            pressZones[keyEvent.keyCode] = zone
            pressZone = zone
        } else {
            pressZone = pressZones.removeValue(forKey: keyEvent.keyCode) ?? zone
        }
        let chatZone = !keyEvent.isDown && (modalShows || pressZone == .modal) ? pressZone : zone
        let outcome = layer.handle(keyEvent, zone: zone, settingsOnTop: sinks.settingsOnTop())
        var deferEscape = false
        for effect in outcome.effects {
            switch effect {
            case .command(let slot): sinks.run(slot)
            case .escape(let intent): sinks.escape(intent)
            case .deferEscape: deferEscape = true
            }
        }
        if event.type == .flagsChanged {
            // A modifier key alone. The chat input sees its key down or key up. The views keep
            // the event (the terminal uses it for the link preview).
            if chatZone == .chat && !outcome.consumed, let chat = focus.chat {
                _ = chat.chatKey(keyEvent, dictationKey: dictationKey)
            }
            return false
        }
        if outcome.consumed { return true }
        if chatZone == .chat, let chat = focus.chat,
            chat.chatKey(keyEvent, dictationKey: dictationKey)
        {
            return true
        }
        if deferEscape && event.type == .keyDown {
            pendingEscape = (event, zone, keyEvent.isRepeat)
        }
        return false
    }

    // A key equivalent, before the views and the main menu get it. Only the key recorder takes
    // one, while it records. Each other key equivalent goes on.
    package func keyEquivalent(_ event: NSEvent) -> Bool {
        recorder?.take(event) ?? false
    }

    // The key recorder while it records, or nil. It has the focus while it records.
    private var recorder: KeyRecorderView? {
        guard let recorder = window?.firstResponder as? KeyRecorderView, recorder.isRecording
        else { return nil }
        return recorder
    }

    // The views had the event. A waiting Esc that did not get to the end of the responder chain
    // was taken by a view.
    package func dispatchEnded(_ event: NSEvent) {
        guard let pending = pendingEscape, pending.event === event else { return }
        pendingEscape = nil
        sinks.escape(
            layer.finishEscape(
                zone: pending.zone, handled: true, isRepeat: pending.isRepeat,
                settingsOnTop: sinks.settingsOnTop()))
    }

    // The key got to the end of the responder chain: no view took it. True when the Esc of the key
    // layer acted, so the window must not give it to AppKit. An Esc with no intent (a key repeat)
    // goes to AppKit: the window keeps only an Esc that acts.
    @discardableResult
    package func endOfChain(_ event: NSEvent) -> Bool {
        guard let pending = pendingEscape, pending.event === event else { return false }
        pendingEscape = nil
        let intent = layer.finishEscape(
            zone: pending.zone, handled: false, isRepeat: pending.isRepeat,
            settingsOnTop: sinks.settingsOnTop())
        sinks.escape(intent)
        return intent != .none
    }

    // An open Bifrost menu took a key down (BifrostWindow.sendEvent).
    package func menuTookKey(_ event: NSEvent) {
        guard event.type == .keyDown, !event.isARepeat else { return }
        pressZones[KeyCode(rawValue: event.keyCode)] = .modal
    }

    // MARK: - The focus

    // A new first responder. The chat that loses the focus stops a hold of dictation, and the chat
    // that gets it warms the speech engine. A focus in a chat window selects its session, when the
    // session has a row in the session list.
    package func focusChanged(from before: NSResponder?, to after: NSResponder?) {
        let old = KeyFocus(before, in: window)
        let new = KeyFocus(after, in: window)
        if let chat = old.chat, chat !== new.chat {
            chat.chatFocus(false, dictationKey: dictationKey)
        }
        if let chat = new.chat, chat !== old.chat {
            chat.chatFocus(true, dictationKey: dictationKey)
        }
        let select = layer.focus(
            new.target, selectedId: selection.selectedId, rows: selection.listIds)
        if let select { selection.selectedId = select }
    }

    // The window became the key window (true) or stopped being it (false). At a blur no key up
    // comes, so the key layer forgets all keys.
    package func keyWindowChanged(_ isKey: Bool) {
        let chat = KeyFocus(window?.firstResponder, in: window).chat
        chat?.chatFocus(isKey, dictationKey: dictationKey)
        if !isKey {
            layer.blur()
            pressZones = [:]
        }
    }

    // MARK: - The rows

    // A primary mouse down on a row of a session list claims a held hold key for the row (D8).
    package func rowPress(_ row: String) {
        layer.holdPress(row)
    }

    // True while exactly one hold key is down in the other zone. A double-click on a row then
    // does not select or open the row (D8).
    package var isHolding: Bool { layer.holding() }

    // A click on a row. True when the pointer down of this click claimed a held hold key: the
    // hold command then runs on the row, and the click must not select the row (D8).
    package func rowClick(_ row: String) -> Bool {
        guard let slot = layer.holdClick(row) else { return false }
        sinks.hold(slot, row)
        return true
    }
}
