// The texts of the key editor (docs/behaviour/keys.md, "Slots and bindings"): the label of each key
// slot, the title of each slot group and the shown form of a key. A label of an action has no
// three full stops, as a menu item has. The label set is the labels setting (Settings.labels).
import BifrostFoundation

extension KeySlot {
    // The label of the slot in the key editor.
    package func label(_ labels: LabelSet) -> String {
        // The label of an action that has a space label.
        func action(_ plain: String, _ space: String) -> String {
            labels == .plain ? plain : space
        }
        switch command {
        case .newSession: return action("New session", "Launch")
        case .selectRow(let row): return "Select row \(row)"
        case .selectPrev: return "Select the previous row"
        case .selectNext: return "Select the next row"
        case .focusOverview: return "Move focus to the Overview"
        case .open: return action("Open", "Warp to")
        case .sendMessage: return action("Send message", "Hail")
        case .runSlash: return action("Run slash command", "Activate module")
        case .interrupt: return action("Interrupt", "Full stop")
        case .rename: return action("Rename", "Set callsign")
        case .showInfo: return action("Show Info", "Scan")
        case .copyId: return action("Copy session ID", "Copy transponder ID")
        case .openProject:
            return action("Open project", "Open cargo hold") + " in the default app"
        case .openInTerminal: return action("Open in terminal", "Jump to terminal")
        case .takeControl: return action("Take control", "Commandeer")
        case .resume: return action("Resume", "Reactivate")
        case .resumeAll: return action("Resume all", "Reactivate all")
        case .setPriority(0): return "Clear the priority"
        case .setPriority(let priority):
            return action("Set priority", "Set threat level") + " \(priority)"
        case .closePanel: return "Close the focused panel"
        case .stop: return action("Stop session", "Power down")
        case .delete: return action("Delete session", "Self-destruct")
        case .prevStackTab: return "Previous tab in the stack"
        case .nextStackTab: return "Next tab in the stack"
        case .nextOverviewTab: return "Next Overview tab"
        case .prevOverviewTab: return "Previous Overview tab"
        case .loadLayout(let number): return "Load layout \(number)"
        case .saveLayout: return "Save the layout"
        case .eventLog: return "Event log"
        case .usageHud: return "Usage HUD"
        case .settings: return "Settings"
        case .toggleFullscreen: return "Toggle Fullscreen"
        case .escape: return "Open or close Settings, or leave the send box"
        case .dictation: return "Dictation key"
        }
    }
}

extension Chord {
    // The key as the key editor shows it: the symbols of the modifiers in the order of the macOS
    // menus (Control, Option, Shift, Cmd), then the key, with a space between the parts. For
    // example "⇧ ⌘ T", "⌃ ⌘ F" or "⌘ ↑". The search of Settings finds a key by this form
    // (SettingsSearch).
    package var shown: String {
        var parts: [String] = []
        if modifiers.contains(.control) { parts.append("⌃") }
        if modifiers.contains(.option) { parts.append("⌥") }
        if modifiers.contains(.shift) { parts.append("⇧") }
        if modifiers.contains(.command) { parts.append("⌘") }
        parts.append(key.shown)
        return parts.joined(separator: " ")
    }
}

extension Chord.Key {
    // The key in the key editor: a symbol for the arrows, Enter, Backspace, Delete, Tab and
    // Space, "Esc" for Escape, and else the name of the key.
    fileprivate var shown: String {
        guard case .named(let name) = self else { return self.name }
        switch name {
        case .arrowUp: return "↑"
        case .arrowDown: return "↓"
        case .arrowLeft: return "←"
        case .arrowRight: return "→"
        case .enter: return "↵"
        case .escape: return "Esc"
        case .backspace: return "⌫"
        case .delete: return "⌦"
        case .tab: return "⇥"
        case .space: return "␣"
        default: return name.rawValue
        }
    }
}

extension SlotGroup {
    // The title of the group in the key editor.
    package var title: String {
        switch self {
        case .always: "Shortcuts that work at all times"
        case .single: "Single keys (not in a chat window or a text box)"
        case .hold: "Hold a key and click a row"
        case .dictation: "Hold to dictate in a chat window"
        }
    }
}
