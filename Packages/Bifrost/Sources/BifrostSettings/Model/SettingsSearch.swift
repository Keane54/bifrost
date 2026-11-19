// The search of the Settings panel (docs/behaviour/settings.md, "The search"). The search finds
// the rows of the sections by their text. In Keys, it also finds a row by its key: in the shown
// form (for example "⇧ ⌘ T") or in a typed form (for example "cmd shift t"). The search changes
// a text to lower case with the rules of String.
import BifrostFoundation
import BifrostKeyboard

// One row that the search can find. The ID is the label of a General row, the slash command, the
// stored ID of a key slot, or the ID of the section for Live details and Skills.
package struct SearchRow: Sendable, Equatable {
    package var id: String
    package var text: String
    // The key of a key row. nil: the row is not a key row.
    package var key: KeyBinding?

    package init(id: String, text: String, key: KeyBinding? = nil) {
        self.id = id
        self.text = text
        self.key = key
    }
}

// The rows of one section that the search reads.
package struct SearchSection: Sendable, Equatable {
    package var id: SettingsSection
    package var title: String
    package var rows: [SearchRow]

    package init(id: SettingsSection, title: String, rows: [SearchRow]) {
        self.id = id
        self.title = title
        self.rows = rows
    }
}

// The matches of one section. whole is true when the query matches the title of the section.
// Then the section shows all its rows. rows has the IDs of the rows that match, in the order of
// the section.
package struct SearchHit: Sendable, Equatable {
    package var id: SettingsSection
    package var title: String
    package var whole: Bool
    package var rows: [String]

    package init(id: SettingsSection, title: String, whole: Bool, rows: [String]) {
        self.id = id
        self.title = title
        self.whole = whole
        self.rows = rows
    }
}

// The place of the focus for Cmd+F: in Settings, nowhere, or in another place.
package enum SearchFocus: Sendable {
    case settings, none, other
}

package enum SettingsSearch {
    // What Esc does in the search field.
    package enum EscapeAction: Sendable {
        case clear, close, ignore
    }

    // The rows of the shown sections, in the order of the tabs. general has the General rows that
    // the section shows. keys has one row for each key slot: the slot ID, the label and the key.
    // Reviews always has all its rows (ReviewsSettingsRow). updates has the rows of Updates, and
    // dailyUpdate the rows of Daily update. live and skills are the words of Live details and of
    // Skills, and each section gets one row with all its words. A section with no rows is not in
    // the index: a section that shows the later text, and Live details or Skills with no words.
    // The Slash commands section stays in the index with no command, so its title still finds
    // it, and the user can add a command there.
    package static func index(
        general: [GeneralRow], slash: [String], keys: [SearchRow], live: [String],
        skills: [String], updates: [UpdatesRow] = [], dailyUpdate: [DailyUpdateRow] = [],
        shown: Set<SettingsSection>
    ) -> [SearchSection] {
        // The rows of a section, or nil when the section has no rows.
        func rows(of section: SettingsSection) -> [SearchRow]? {
            switch section {
            case .general: general.isEmpty ? nil : general.map(row(of:))
            case .slash: slash.map { SearchRow(id: $0, text: $0) }
            case .keys: keys.isEmpty ? nil : keys
            case .live: wordsRow(of: section, live)
            case .skills: wordsRow(of: section, skills)
            case .reviews: ReviewsSettingsRow.allCases.map(row(of:))
            case .updates: updates.isEmpty ? nil : updates.map(row(of:))
            case .dailyUpdate:
                dailyUpdate.isEmpty
                    ? nil : dailyUpdate.map { SearchRow(id: $0.rawValue, text: $0.rawValue) }
            case .modules: nil
            }
        }
        return SettingsSection.allCases.compactMap { section in
            guard shown.contains(section), let rows = rows(of: section) else { return nil }
            return SearchSection(id: section, title: section.title, rows: rows)
        }
    }

    // The matches of a query, by section. nil for a query with no word: then the tabs show. A
    // section with no match is not in the list.
    package static func search(_ query: String, _ sections: [SearchSection]) -> [SearchHit]? {
        if words(query).isEmpty { return nil }
        return sections.compactMap { section in
            let whole = textMatches(section.title, query)
            let rows = section.rows
                .filter { whole || rowMatches($0, title: section.title, query) }
                .map(\.id)
            guard whole || !rows.isEmpty else { return nil }
            return SearchHit(id: section.id, title: section.title, whole: whole, rows: rows)
        }
    }

    // True when each word of the query is in the text, in any order and in any case.
    package static func textMatches(_ text: String, _ query: String) -> Bool {
        let list = words(query)
        let lower = text.lowercased()
        return !list.isEmpty && list.allSatisfy { lower.contains($0) }
    }

    // True when each part of the query names a part of the key. Off is no key and never matches.
    package static func keyMatches(_ key: KeyBinding, _ query: String) -> Bool {
        guard let chord = key.chord else { return false }
        let parts = keyParts(query)
        let chordNames = names(of: chord)
        return !parts.isEmpty && parts.allSatisfy { namesPart(chordNames, $0) }
    }

    // The line when nothing matches.
    package static func noMatchText(_ query: String) -> String {
        "No settings match \"\(query.trimmed())\"."
    }

    // The text of the live line for a screen reader: the number of the matching rows, or the
    // line when nothing matches. With no search, the text is empty.
    package static func resultCountText(_ hits: [SearchHit]?, _ query: String) -> String {
        guard let hits else { return "" }
        if hits.isEmpty { return noMatchText(query) }
        let count = hits.reduce(0) { $0 + $1.rows.count }
        return count == 1 ? "1 setting matches." : "\(count) settings match."
    }

    // Esc in the search field clears the query first. In an empty field, Esc closes Settings, as
    // Esc does outside a text field. During the composition of an input method, Esc only cancels
    // the composition.
    package static func escape(value: String, composing: Bool) -> EscapeAction {
        if composing { return .ignore }
        return value.isEmpty ? .close : .clear
    }

    // True for a key down of Cmd+F with no other modifier, while Settings has the focus. With no
    // focus, Settings must be the front panel. The key matches as each Bifrost key does
    // (Chord.match): on a layout of another script, the place of the F key stands in. A key of a
    // composition never matches.
    package static func isSearchShortcut(
        _ event: KeyEvent, focus: SearchFocus, settingsOnTop: Bool
    ) -> Bool {
        guard event.isDown, searchChord.match(event) != nil else { return false }
        switch focus {
        case .settings: return true
        case .none: return settingsOnTop
        case .other: return false
        }
    }
}

// MARK: - The rules of the match

extension SettingsSearch {
    // The key of the search field.
    private static let searchChord = Chord(.command, key: .character("F"))

    // The names of the modifiers, in the order of a binding: the symbol of the key list, then the
    // typed names.
    private static let modifierNames: [(modifier: KeyEvent.Modifiers, names: [String])] = [
        (.command, ["⌘", "cmd", "command", "mod", "meta"]),
        (.control, ["⌃", "^", "ctrl", "control"]),
        (.option, ["⌥", "alt", "opt", "option"]),
        (.shift, ["⇧", "shift"]),
    ]

    // The names of a named key: the symbols, then the typed names. A function key has no symbol,
    // so its name in lower case is its one name, for example "f5".
    private static func keyNames(of name: KeyName) -> [String] {
        switch name {
        case .arrowDown: ["↓", "down", "arrowdown"]
        case .arrowLeft: ["←", "left", "arrowleft"]
        case .arrowRight: ["→", "right", "arrowright"]
        case .arrowUp: ["↑", "up", "arrowup"]
        case .backspace: ["⌫", "backspace", "delete"]
        case .delete: ["⌦", "delete", "del", "forwarddelete"]
        case .end: ["↘", "end"]
        case .enter: ["↵", "↩", "enter", "return"]
        case .escape: ["⎋", "esc", "escape"]
        case .home: ["↖", "home"]
        case .pageDown: ["⇟", "pagedown", "pgdn"]
        case .pageUp: ["⇞", "pageup", "pgup"]
        case .space: ["␣", "space"]
        case .tab: ["⇥", "tab"]
        case .f1, .f2, .f3, .f4, .f5, .f6, .f7, .f8, .f9, .f10, .f11, .f12:
            [name.rawValue.lowercased()]
        }
    }

    // The symbols that a query can write with no space between them, for example "⌘⇧T". The
    // caret ^ is a typed form of ⌃ (Control).
    private static let symbols: Set<Character> = [
        "⌘", "⇧", "⌃", "^", "⌥", "↑", "↓", "←", "→", "↵", "↩", "⌫", "⌦", "⇥", "␣", "⎋", "↖", "↘",
        "⇞", "⇟",
    ]

    // The row of a General row: its label is its ID and its text.
    private static func row(of general: GeneralRow) -> SearchRow {
        SearchRow(id: general.rawValue, text: general.rawValue)
    }

    // The row of a row of Settings > Reviews: its label is its ID and its text.
    private static func row(of reviews: ReviewsSettingsRow) -> SearchRow {
        SearchRow(id: reviews.rawValue, text: reviews.rawValue)
    }

    // The row of an Updates row: its label is its ID and its text.
    private static func row(of updates: UpdatesRow) -> SearchRow {
        SearchRow(id: updates.rawValue, text: updates.rawValue)
    }

    // A row with all the words of a section, or nil when the section has no words.
    private static func wordsRow(of section: SettingsSection, _ words: [String]) -> [SearchRow]? {
        words.isEmpty ? nil : [SearchRow(id: section.rawValue, text: words.joined(separator: " "))]
    }

    // The words of a text in lower case. White space separates the words.
    private static func words(_ text: String) -> [String] {
        text.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
    }

    // The parts of a key query: "cmd+shift+t", "cmd shift t" and "⌘⇧T" all give cmd, shift and t.
    private static func keyParts(_ query: String) -> [String] {
        var text = ""
        for character in query.lowercased() {
            if character == "+" {
                text.append(" ")
            } else if symbols.contains(character) {
                text += " \(character) "
            } else {
                text.append(character)
            }
        }
        return words(text)
    }

    // The names of each part of a chord: each modifier, then the key.
    private static func names(of chord: Chord) -> [[String]] {
        var names = modifierNames.filter { chord.modifiers.contains($0.modifier) }.map(\.names)
        switch chord.key {
        case .named(let name): names.append(keyNames(of: name))
        case .character(let character): names.append([character.lowercased()])
        }
        return names
    }

    // True when the part of a query names a part of a chord. A part of one character must be a
    // name, for example "t" is only the key T. A longer part can be the start of a name, for
    // example "sh" for Shift or "ta" for Tab.
    private static func namesPart(_ names: [[String]], _ part: String) -> Bool {
        names.contains { list in
            list.contains { part.count == 1 ? $0 == part : $0.hasPrefix(part) }
        }
    }

    // True when the row matches the query. Each word of the query can be in the text of the row,
    // as in textMatches. Or each part of the query is in the title of the section, in the text of
    // the row or names a part of the key. In such a mix, a part of one character must be a key
    // name, so "cmd shift t" stays an exact key search.
    private static func rowMatches(_ row: SearchRow, title: String, _ query: String) -> Bool {
        if textMatches(row.text, query) { return true }
        let parts = keyParts(query)
        if parts.isEmpty { return false }
        let text = row.text.lowercased()
        let head = title.lowercased()
        let chordNames = row.key?.chord.map(names(of:))
        return parts.allSatisfy { part in
            (part.count > 1 && (text.contains(part) || head.contains(part)))
                || chordNames.map { namesPart($0, part) } == true
        }
    }
}
