// The row menu of the Overview (docs/behaviour/actions.md, "The row menu"): the entries in order,
// each with its label and its state, and the items of each submenu. The Bifrost menu draws what
// it gives.

// The value of a submenu item: the action of the entry runs with it.
package enum MenuArg: Sendable, Equatable {
    // A priority, or nil for None.
    case priority(SessionPriority?)
    case app(ProjectAppID)
    case colour(WatchColour)
    // A slash command to send.
    case slash(String)
    // Other...: the send box opens for a slash command.
    case otherSlash
}

// One item of a submenu. The key is unique in its submenu.
package struct SubItem: Sendable, Equatable {
    package var key: String
    package var label: String
    package var arg: MenuArg
    // The item shows a check mark.
    package var checked: Bool
    // A separator comes before the item.
    package var separatorBefore: Bool

    package init(
        key: String, label: String, arg: MenuArg, checked: Bool = false,
        separatorBefore: Bool = false
    ) {
        self.key = key
        self.label = label
        self.arg = arg
        self.checked = checked
        self.separatorBefore = separatorBefore
    }
}

package enum RowMenuEntry: Sendable, Equatable {
    case item(ActionID, label: String, state: ActionState)
    case submenu(ActionID, label: String, state: ActionState, items: [SubItem])
    case separator
}

package enum RowMenuModel {
    // The actions whose entry is a submenu.
    private static let submenuActions: Set<ActionID> = [
        .runSlash, .setPriority, .openProject, .watchAdd, .watchColour,
    ]

    // The entries of the menu of the row, in order. Open shows while the chat window is closed,
    // and Close window while it is open. The watch entries depend on the watch of the row. Take
    // control shows only for an external row, and Resume only for a parked row. Each other entry
    // shows for each row, and is off with its reason where it does not apply.
    package static func entries(_ row: SessionRow, _ ctx: ActionContext) -> [RowMenuEntry] {
        func entry(_ id: ActionID) -> RowMenuEntry {
            let label = id.label(ctx.labels)
            let state = ActionModel.state(id, row, ctx)
            guard submenuActions.contains(id) else { return .item(id, label: label, state: state) }
            return .submenu(id, label: label, state: state, items: items(id, row, ctx))
        }
        let rowClass = ActionModel.rowClass(row)
        // nil is a separator.
        var ids: [ActionID?] = ctx.chatOpen ? [] : [.open]
        ids += [.sendMessage, .runSlash, .compact, .handOver, .interrupt, nil, .setPriority]
        ids += row.watch == nil ? [.watchAdd] : [.watchColour, .watchRemove]
        ids += [.rename, .showInfo, .copyId, .openProject, .openInTerminal, nil]
        if rowClass == .external { ids.append(.takeControl) }
        if rowClass == .parked { ids.append(.resume) }
        if ctx.chatOpen { ids.append(.closeWindow) }
        ids += [.stop, .delete]
        return ids.map { $0.map(entry) ?? .separator }
    }

    // The key of the checked item of a submenu, or nil. Set priority and the colour items of
    // the watchlist show a check mark on it.
    package static func checkedKey(_ items: [SubItem]) -> String? {
        items.first(where: \.checked)?.key
    }

    private static func items(_ id: ActionID, _ row: SessionRow, _ ctx: ActionContext)
        -> [SubItem]
    {
        switch id {
        case .setPriority:
            let priorities = SessionPriority.allCases.map { priority in
                let number = String(priority.rawValue)
                return SubItem(
                    key: number, label: number, arg: .priority(priority),
                    checked: row.priority == priority)
            }
            let none = SubItem(
                key: "none", label: "None", arg: .priority(nil), checked: row.priority == nil)
            return priorities + [none]
        case .watchAdd, .watchColour:
            return WatchColour.allCases.map { colour in
                SubItem(
                    key: colour.rawValue, label: colour.label, arg: .colour(colour),
                    checked: row.watch?.colour == colour)
            }
        case .openProject:
            return ctx.apps.map { SubItem(key: $0.id.rawValue, label: $0.label, arg: .app($0.id)) }
        case .runSlash:
            let favourites = ctx.slashFavourites.map {
                SubItem(key: "fav:\($0)", label: $0, arg: .slash($0))
            }
            let recent = ctx.slashRecent.filter { !ctx.slashFavourites.contains($0) }
                .prefix(ActionModel.slashMenuRecent).enumerated().map { index, command in
                    SubItem(
                        key: "recent:\(command)", label: command, arg: .slash(command),
                        separatorBefore: index == 0)
                }
            let other = SubItem(
                key: "other", label: "Other...", arg: .otherSlash,
                separatorBefore: true)
            return favourites + recent + [other]
        default:
            return []
        }
    }
}

extension WatchColour {
    // The name of the colour in the colour menu, for example "Dark red".
    package var label: String {
        switch self {
        case .darkRed: "Dark red"
        case .red: "Red"
        case .amber: "Amber"
        case .yellow: "Yellow"
        case .green: "Green"
        case .lightBlue: "Light blue"
        case .darkBlue: "Dark blue"
        case .white: "White"
        }
    }
}
