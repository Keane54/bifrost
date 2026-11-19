// The key slots of the Bifrost keys and the dictation slot (docs/behaviour/keys.md, "Slots and
// bindings"). A slot is one key of one command: the command and the variant of its key. The
// settings file names a slot with its stored ID, for example "select-row.3:mod". The app parses the
// ID once, at the settings edge (KeyChanges), and keeps the typed slot after that. text gives the
// stored ID back.

// The command of a key slot. Three commands take a number: the row (1 to 9), the priority (1 to 5,
// and 0 clears it) and the layout (1 to 9).
package enum KeyCommand: Hashable, Sendable {
    case newSession
    case selectRow(Int)
    case selectPrev, selectNext, focusOverview, open, sendMessage, runSlash, interrupt, rename
    case showInfo, copyId, openProject, openInTerminal, takeControl, resume, resumeAll
    case setPriority(Int)
    case closePanel, stop, delete, prevStackTab, nextStackTab, nextOverviewTab, prevOverviewTab
    case loadLayout(Int)
    case saveLayout, eventLog, usageHud, settings, toggleFullscreen, escape, dictation
}

// The three tables of the Bifrost keys, and the dictation key.
package enum SlotGroup: Hashable, Sendable, CaseIterable {
    case always, single, hold, dictation
}

package struct KeySlot: Hashable, Sendable, CustomStringConvertible {
    // The variant of the key of a slot: the key of an always slot, the first or the second single
    // key, or the hold key.
    package enum Variant: String, Hashable, Sendable {
        case mod, key, key2, hold
    }

    package let command: KeyCommand
    package let variant: Variant
    // The key of the slot when the settings have no change for it.
    package let defaultBinding: Chord

    // Only the slot table makes a slot. So each slot value is a slot of the table.
    private init(_ command: KeyCommand, _ variant: Variant, _ binding: String) {
        guard let chord = Chord(binding) else { preconditionFailure("bad default key \(binding)") }
        self.command = command
        self.variant = variant
        defaultBinding = chord
    }

    // The slot of a stored ID, or nil when no slot has this ID.
    package init?(_ text: String) {
        guard let slot = Self.byText[text] else { return nil }
        self = slot
    }

    // The stored ID: "<command>[.<number>]:<variant>".
    package var text: String { "\(command.storedName):\(variant.rawValue)" }

    package var description: String { text }

    package var group: SlotGroup {
        switch variant {
        case .mod: .always
        case .key, .key2: .single
        case .hold: command == .dictation ? .dictation : .hold
        }
    }

    // True when the menu owns the key: the menu gets it before the key layer (D7).
    package var isMenu: Bool { command == .closePanel || command == .toggleFullscreen }

    // The slots that the code names.
    package static let closePanel = KeySlot(.closePanel, .mod, "Mod+W")
    package static let toggleFullscreen = KeySlot(.toggleFullscreen, .mod, "Mod+Control+F")
    // Hold the key in a chat window to speak (docs/behaviour/keys.md, "The dictation hold key").
    // The chat input reads this key itself. The ID keeps the variant hold.
    package static let dictation = KeySlot(.dictation, .hold, "Space")

    // The 83 slots of the three tables, in the order of the tables, then the dictation slot.
    package static let all: [KeySlot] = {
        let always =
            [KeySlot(.newSession, .mod, "Mod+N")]
            + (1...9).map { KeySlot(.selectRow($0), .mod, "Mod+\($0)") }
            + [
                KeySlot(.selectPrev, .mod, "Mod+ArrowUp"),
                KeySlot(.selectNext, .mod, "Mod+ArrowDown"),
                KeySlot(.focusOverview, .mod, "Mod+0"),
                KeySlot(.open, .mod, "Mod+Enter"),
                KeySlot(.sendMessage, .mod, "Mod+Shift+M"),
                KeySlot(.runSlash, .mod, "Mod+/"),
                KeySlot(.interrupt, .mod, "Mod+."),
                KeySlot(.showInfo, .mod, "Mod+I"),
                KeySlot(.copyId, .mod, "Mod+Shift+C"),
                KeySlot(.openProject, .mod, "Mod+Shift+O"),
                KeySlot(.openInTerminal, .mod, "Mod+Shift+J"),
                KeySlot(.takeControl, .mod, "Mod+Shift+T"),
                KeySlot(.resume, .mod, "Mod+R"),
                KeySlot(.resumeAll, .mod, "Mod+Shift+R"),
            ]
            + (1...5).map { KeySlot(.setPriority($0), .mod, "Mod+Control+\($0)") }
            + [
                KeySlot(.setPriority(0), .mod, "Mod+Control+0"),
                closePanel,
                KeySlot(.stop, .mod, "Mod+Shift+Backspace"),
                KeySlot(.delete, .mod, "Mod+Alt+Shift+Backspace"),
                KeySlot(.prevStackTab, .mod, "Mod+["),
                KeySlot(.nextStackTab, .mod, "Mod+]"),
            ]
            + (1...9).map { KeySlot(.loadLayout($0), .mod, "Mod+Alt+\($0)") }
            + [
                KeySlot(.saveLayout, .mod, "Mod+Alt+S"),
                KeySlot(.eventLog, .mod, "Mod+L"),
                KeySlot(.usageHud, .mod, "Mod+U"),
                KeySlot(.settings, .mod, "Mod+,"),
                toggleFullscreen,
            ]
        let single =
            [
                KeySlot(.selectPrev, .key, "ArrowUp"),
                KeySlot(.selectNext, .key, "ArrowDown"),
                KeySlot(.nextOverviewTab, .key, "Tab"),
                KeySlot(.prevOverviewTab, .key, "Shift+Tab"),
                KeySlot(.open, .key, "O"),
                KeySlot(.open, .key2, "Enter"),
                KeySlot(.sendMessage, .key, "M"),
                KeySlot(.runSlash, .key, "/"),
                KeySlot(.interrupt, .key, "X"),
                KeySlot(.showInfo, .key, "I"),
                KeySlot(.openInTerminal, .key, "J"),
                KeySlot(.openProject, .key, "P"),
                KeySlot(.copyId, .key, "C"),
                KeySlot(.rename, .key, "R"),
                KeySlot(.takeControl, .key, "T"),
            ]
            + (1...5).map { KeySlot(.setPriority($0), .key, "\($0)") }
            + [
                KeySlot(.setPriority(0), .key, "0"),
                KeySlot(.stop, .key, "Backspace"),
                KeySlot(.delete, .key, "Shift+Backspace"),
                KeySlot(.escape, .key, "Escape"),
            ]
        let hold =
            [
                KeySlot(.open, .hold, "O"),
                KeySlot(.sendMessage, .hold, "M"),
                KeySlot(.showInfo, .hold, "I"),
                KeySlot(.openInTerminal, .hold, "J"),
                KeySlot(.interrupt, .hold, "X"),
            ]
            + (1...5).map { KeySlot(.setPriority($0), .hold, "\($0)") }
        return always + single + hold + [dictation]
    }()

    private static let byText: [String: KeySlot] = Dictionary(
        uniqueKeysWithValues: all.map { ($0.text, $0) })
}

extension KeyCommand {
    // The command part of a stored slot ID, with its number.
    fileprivate var storedName: String {
        switch self {
        case .newSession: "new-session"
        case .selectRow(let row): "select-row.\(row)"
        case .selectPrev: "select-prev"
        case .selectNext: "select-next"
        case .focusOverview: "focus-overview"
        case .open: "open"
        case .sendMessage: "send-message"
        case .runSlash: "run-slash"
        case .interrupt: "interrupt"
        case .rename: "rename"
        case .showInfo: "show-info"
        case .copyId: "copy-id"
        case .openProject: "open-project"
        case .openInTerminal: "open-in-terminal"
        case .takeControl: "take-control"
        case .resume: "resume"
        case .resumeAll: "resume-all"
        case .setPriority(let priority): "set-priority.\(priority)"
        case .closePanel: "close-panel"
        case .stop: "stop"
        case .delete: "delete"
        case .prevStackTab: "prev-stack-tab"
        case .nextStackTab: "next-stack-tab"
        case .nextOverviewTab: "next-overview-tab"
        case .prevOverviewTab: "prev-overview-tab"
        case .loadLayout(let number): "load-layout.\(number)"
        case .saveLayout: "save-layout"
        case .eventLog: "event-log"
        case .usageHud: "usage-hud"
        case .settings: "settings"
        case .toggleFullscreen: "toggle-fullscreen"
        case .escape: "escape"
        case .dictation: "dictation"
        }
    }
}
