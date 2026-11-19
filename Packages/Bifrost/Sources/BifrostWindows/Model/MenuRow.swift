import BifrostLook

// The rows of a Bifrost menu (docs/behaviour/menu.md). The owner of a menu gives the rows as
// values. MenuNavigation reads them for the keys and the pointer, and BifrostMenu shows them.

// The parts of an item row: its ID, its label, whether it can act and why not, and its colour
// square.
package struct MenuItemSpec: Sendable, Equatable {
    // The ID that the menu gives back when the user chooses the row.
    package var id: String
    package var label: String
    package var enabled: Bool
    // The tooltip of a disabled row: why the row cannot act. nil shows no tooltip.
    package var reason: String?
    // The colour of an 8 unit colour square before the label, or nil for no square.
    package var swatch: TokenColour?
    // True for a row with no colour square that keeps the space of one, so its label lines up
    // with the rows that have a square (the None row of the priorities).
    package var swatchSpace: Bool

    package init(
        id: String, label: String, enabled: Bool = true, reason: String? = nil,
        swatch: TokenColour? = nil, swatchSpace: Bool = false
    ) {
        self.id = id
        self.label = label
        self.enabled = enabled
        self.reason = reason
        self.swatch = swatch
        self.swatchSpace = swatchSpace
    }

    // True when the row has a colour square or keeps its space.
    package var hasSwatchColumn: Bool { swatch != nil || swatchSpace }
}

package enum MenuRow: Sendable, Equatable {
    // A row that acts and closes the menu.
    case item(MenuItemSpec)
    // A row with a check box: an empty box while it is off, and a box with a check mark while it
    // is on. A choice keeps the menu open (the Lock row of the Panel menu).
    case checkbox(MenuItemSpec, checked: Bool)
    // A row with a check mark while it is on and an empty column while it is off, as a menu item
    // of macOS. A choice keeps the menu open (the filters and the columns of an Overview tab).
    case check(MenuItemSpec, checked: Bool)
    // A row of a group with one checked row. A choice closes the menu.
    case radio(MenuItemSpec, checked: Bool)
    // A row that opens the menu of its rows at its right.
    case submenu(MenuItemSpec, rows: [MenuRow])
    // A label above a text box. Enter saves the text. maxLength counts Characters, as each length
    // limit of the app does (row OV6 of the Overview port).
    case field(id: String, label: String, text: String, maxLength: Int)
    // A line between two groups of rows.
    case separator

    // The parts of an item row, or nil for a field and a separator.
    package var spec: MenuItemSpec? {
        switch self {
        case .item(let spec), .checkbox(let spec, _), .check(let spec, _), .radio(let spec, _),
            .submenu(let spec, _):
            spec
        case .field, .separator:
            nil
        }
    }

    // The ID that the menu gives back for the row, or nil for a separator.
    package var id: String? {
        switch self {
        case .field(let id, _, _, _): id
        default: spec?.id
        }
    }

    // True when the keys can move the highlight to the row: each row but a separator. A disabled
    // row takes the highlight too, so the keys reach its reason, but it does not act.
    package var takesHighlight: Bool {
        switch self {
        case .separator: false
        default: true
        }
    }

    // The rows of an enabled submenu, or nil.
    package var submenu: [MenuRow]? {
        guard case .submenu(let spec, let rows) = self, spec.enabled else { return nil }
        return rows
    }

    // The height of the row in layout units (ThemeTokens.Menu).
    package var height: Double {
        switch self {
        case .separator:
            ThemeTokens.Menu.separatorHeight + 2 * ThemeTokens.Menu.separatorMargin
        case .field:
            ThemeTokens.Menu.fieldRowHeight
        default:
            ThemeTokens.Menu.rowHeight
        }
    }
}

extension [MenuRow] {
    // The row at a path of row indexes: the first index is in these rows, and each next index is
    // in the rows of the submenu before it. nil for a path that names no row.
    package func row(at path: [Int]) -> MenuRow? {
        guard let first = path.first, indices.contains(first) else { return nil }
        let row = self[first]
        guard path.count > 1 else { return row }
        guard case .submenu(_, let rows) = row else { return nil }
        return rows.row(at: [Int](path.dropFirst()))
    }

    // The rows of the level of a path: these rows for an empty path, else the rows of the
    // submenu at the path. nil when the path names no submenu.
    package func level(_ path: [Int]) -> [MenuRow]? {
        guard !path.isEmpty else { return self }
        guard case .submenu(_, let rows) = row(at: path) else { return nil }
        return rows
    }
}
