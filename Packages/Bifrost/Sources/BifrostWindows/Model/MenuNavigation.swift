// The keys and the pointer of a Bifrost menu (docs/behaviour/menu.md, "Keys and the pointer"): a
// loop at the ends, a type-ahead and a submenu that opens under the pointer. The rules are pure:
// the presenter gives each key and each pointer move with the time of its clock, and runs the
// effects. A path is the row indexes from the root menu into the submenus, so [4, 1] is the second
// row of the submenu of the fifth row.

// A key of the menu. The panel maps each key event to one.
package enum MenuKey: Sendable, Equatable {
    case up, down, left, right, home, end, enter, space, escape
    // The text of a typed character.
    case text(String)
}

// What the presenter does after a key or a pointer move.
package enum MenuEffect: Sendable, Equatable {
    // Show the highlight on the row of the path. An empty path is no highlight.
    case highlight([Int])
    // Show or hide the submenu of the row of the path.
    case openSubmenu([Int]), closeSubmenu([Int])
    // The user chose the row: an item, a check box or a radio row acts, and a field row saves.
    case choose([Int])
    // Close the menu.
    case dismiss
}

package struct MenuNavigation: Sendable {
    // The typed text of the type-ahead starts again this long after the last typed character.
    package static let typeaheadReset = Duration.milliseconds(750)
    // A submenu opens after the pointer rests this long on its row.
    package static let submenuDelay = Duration.milliseconds(100)

    package private(set) var rows: [MenuRow]
    // The path of the highlighted row, or nil.
    package private(set) var highlighted: [Int]?
    // The paths of the rows whose submenus show, the outer first. Each path starts with the path
    // before it.
    package private(set) var open: [[Int]] = []

    // The text of the type-ahead and the time of its last character.
    private var typed: (text: String, at: Duration)?
    // The submenu row under the pointer and the time the pointer came to it.
    private var hovered: (path: [Int], at: Duration)?
    private var effects: [MenuEffect] = []

    package init(rows: [MenuRow]) {
        self.rows = rows
    }

    // The time when the submenu under the pointer opens, or nil. The presenter starts its timer
    // for it and then calls timerFired.
    package var openDue: Duration? {
        hovered.map { $0.at + Self.submenuDelay }
    }

    // The effects since the last take, in their order.
    package mutating func takeEffects() -> [MenuEffect] {
        defer { effects = [] }
        return effects
    }

    // New rows, for example after a check box changed. The highlight and the open submenus stay
    // while their rows are still there.
    package mutating func setRows(_ rows: [MenuRow]) {
        self.rows = rows
        while let last = open.last, rows.row(at: last)?.submenu == nil {
            open.removeLast()
        }
        if let path = highlighted, rows.row(at: path) == nil || rows.row(at: path) == .separator {
            highlighted = nil
        }
        if let hovered, rows.row(at: hovered.path)?.submenu == nil { self.hovered = nil }
    }

    // MARK: - The keys

    // False for a key that the field of the highlight takes: the text and the keys that edit
    // the text. The menu does not use them, so the panel gives them to the field.
    package func usesKey(_ key: MenuKey) -> Bool {
        guard isOnField else { return true }
        switch key {
        case .text, .left, .right, .home, .end, .space: return false
        case .up, .down, .enter, .escape: return true
        }
    }

    package mutating func key(_ key: MenuKey, now: Duration) {
        guard usesKey(key) else { return }
        switch key {
        case .down: move(by: 1)
        case .up: move(by: -1)
        case .home: moveToEnd(last: false)
        case .end: moveToEnd(last: true)
        case .right: openHighlighted(highlightFirst: true)
        case .left: closeInner()
        case .enter: chooseHighlighted()
        // Space during a type-ahead adds to the typed text, so a label with a space can match.
        case .space:
            if isTyping(now) { typeahead(" ", now: now) } else { chooseHighlighted() }
        case .escape: escape()
        case .text(let text): typeahead(text, now: now)
        }
    }

    // True while a typed text is less than the reset time old.
    private func isTyping(_ now: Duration) -> Bool {
        guard let typed else { return false }
        return now - typed.at < Self.typeaheadReset
    }

    private var isOnField: Bool {
        guard let path = highlighted, case .field = rows.row(at: path) else { return false }
        return true
    }

    // Up and Down move over the rows that take the highlight (each row but a separator), in the
    // level of the highlight, and go round at the ends. With no highlight, they start in the root
    // menu.
    private mutating func move(by step: Int) {
        let parent = highlighted.map { [Int]($0.dropLast()) } ?? []
        let targets = targets(in: parent)
        guard let first = targets.first, let last = targets.last else { return }
        let next: Int
        if let current = highlighted?.last {
            if let at = targets.firstIndex(of: current) {
                next = targets[(at + step + targets.count) % targets.count]
            } else if step > 0 {
                // A highlight on a row that does not take it (after new rows): the move starts at
                // its place.
                next = targets.first { $0 > current } ?? first
            } else {
                next = targets.last { $0 < current } ?? last
            }
        } else {
            next = step > 0 ? first : last
        }
        setHighlight(parent + [next])
    }

    private mutating func moveToEnd(last: Bool) {
        let parent = highlighted.map { [Int]($0.dropLast()) } ?? []
        let targets = targets(in: parent)
        guard let index = last ? targets.last : targets.first else { return }
        setHighlight(parent + [index])
    }

    // The indexes of the rows of a level that take the highlight.
    private func targets(in parent: [Int]) -> [Int] {
        guard let level = rows.level(parent) else { return [] }
        return level.indices.filter { level[$0].takesHighlight }
    }

    // Right, and Return or a click on a submenu row: the submenu of the highlighted row opens. The
    // keys also take the highlight to its first row.
    private mutating func openHighlighted(highlightFirst: Bool) {
        guard let path = highlighted, let sub = rows.row(at: path)?.submenu else { return }
        hovered = nil
        if !open.contains(path) {
            open.append(path)
            effects.append(.openSubmenu(path))
        }
        if highlightFirst, let first = sub.indices.first(where: { sub[$0].takesHighlight }) {
            setHighlight(path + [first])
        }
    }

    // Left in a submenu: the submenu closes, and its row keeps the highlight.
    private mutating func closeInner() {
        guard let path = highlighted, path.count > 1 else { return }
        let parent = [Int](path.dropLast())
        if open.last == parent {
            open.removeLast()
            effects.append(.closeSubmenu(parent))
        }
        setHighlight(parent)
    }

    // Esc closes the inner open submenu, else the menu.
    private mutating func escape() {
        guard let last = open.popLast() else {
            effects.append(.dismiss)
            return
        }
        effects.append(.closeSubmenu(last))
        setHighlight(last)
    }

    private mutating func chooseHighlighted() {
        guard let path = highlighted else { return }
        choose(path, fromKeys: true)
    }

    // A choice of an enabled row. A check box, a check row and a field keep the menu open. A
    // submenu row opens.
    // A disabled row does nothing.
    private mutating func choose(_ path: [Int], fromKeys: Bool) {
        guard let row = rows.row(at: path) else { return }
        switch row {
        case .item(let spec), .radio(let spec, _):
            guard spec.enabled else { return }
            effects += [.choose(path), .dismiss]
        case .checkbox(let spec, _), .check(let spec, _):
            guard spec.enabled else { return }
            effects.append(.choose(path))
        case .submenu:
            openHighlighted(highlightFirst: fromKeys)
        case .field:
            effects.append(.choose(path))
        case .separator:
            return
        }
    }

    // The type-ahead: the highlight goes to the next row of its level whose label starts with
    // the typed text, with no regard to case. A new character within the reset time adds to the
    // text, except a repeat of the one typed letter: it cycles through the rows that start with
    // that letter. One character looks from the row after the highlight, so the same letter again
    // goes to the next row with that letter. A longer text looks from the highlighted row.
    private mutating func typeahead(_ character: String, now: Duration) {
        var text = character
        if let typed, isTyping(now), typed.text.lowercased() != character.lowercased() {
            text = typed.text + character
        }
        typed = (text, now)
        let parent = highlighted.map { [Int]($0.dropLast()) } ?? []
        guard let level = rows.level(parent) else { return }
        let current = highlighted?.last ?? -1
        let start = text.count == 1 ? current + 1 : max(current, 0)
        let wanted = text.lowercased()
        for offset in 0..<level.count {
            let index = (start + offset) % level.count
            let row = level[index]
            guard let spec = row.spec, row.takesHighlight else { continue }
            if spec.label.lowercased().hasPrefix(wanted) {
                setHighlight(parent + [index])
                return
            }
        }
    }

    // MARK: - The pointer

    // The pointer is over the row of the path, or over no row (nil). A row gets the highlight,
    // also a disabled row. The pointer over a separator or a field row changes nothing: a field
    // takes the focus only from a click or the keys. While a field has the highlight, the pointer
    // does not move it, so the field keeps the focus for the typed text. A submenu row opens after
    // the delay.
    package mutating func hover(_ path: [Int]?, now: Duration) {
        guard !isOnField else { return }
        guard let path else {
            hovered = nil
            if highlighted != nil {
                highlighted = nil
                effects.append(.highlight([]))
            }
            return
        }
        guard let row = rows.row(at: path) else { return }
        switch row {
        case .separator, .field: return
        default: break
        }
        setHighlight(path)
        if row.submenu != nil, !open.contains(path), hovered?.path != path {
            hovered = (path, now)
        }
    }

    // The timer of the submenu delay ran out: the submenu under the pointer opens.
    package mutating func timerFired(now: Duration) {
        guard let hovered, let due = openDue, now >= due else { return }
        self.hovered = nil
        guard highlighted == hovered.path, rows.row(at: hovered.path)?.submenu != nil,
            !open.contains(hovered.path)
        else { return }
        open.append(hovered.path)
        effects.append(.openSubmenu(hovered.path))
    }

    // A click: the press and the release on the row of the path. An enabled row acts as for
    // Return, a submenu opens at once, and a field takes the focus.
    package mutating func click(_ path: [Int]) {
        guard let row = rows.row(at: path) else { return }
        switch row {
        case .separator: return
        case .field: focusField(path)
        default:
            setHighlight(path)
            choose(path, fromKeys: false)
        }
    }

    // The field of the path took the focus, for example from a click in its box.
    package mutating func focusField(_ path: [Int]) {
        guard case .field = rows.row(at: path) else { return }
        setHighlight(path)
    }

    // MARK: - The highlight

    // A new highlight closes each open submenu that does not hold it, and stops a submenu that
    // waits to open on another row.
    private mutating func setHighlight(_ path: [Int]) {
        guard path != highlighted else { return }
        highlighted = path
        effects.append(.highlight(path))
        if let hovered, hovered.path != path { self.hovered = nil }
        while let last = open.last, !path.starts(with: last) {
            open.removeLast()
            effects.append(.closeSubmenu(last))
        }
    }
}
