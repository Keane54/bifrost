// The row menu of the Overview (docs/behaviour/actions.md, "The row menu"): the entries in order
// for each row class, and the items of each submenu.
import BifrostFoundation
import BifrostTestSupport
import Testing

@testable import BifrostSessions

private let owned = SessionRow.test(sessionId: "o", shortId: "abcd1234", pid: 10)
private let external = SessionRow.test(sessionId: "e", shortId: nil, kind: .external, pid: 20)
private let parked = SessionRow.test(sessionId: "p", state: .parked)

private func context(
    chatOpen: Bool = true, labels: LabelSet = .plain, slashFavourites: [String] = [],
    slashRecent: [String] = []
) -> ActionContext {
    ActionContext(
        chatOpen: chatOpen, folderShared: false,
        apps: [ProjectApp(id: .finder, label: "Finder"), ProjectApp(id: .warp, label: "Warp")],
        labels: labels, running: false, slashFavourites: slashFavourites,
        slashRecent: slashRecent)
}

private func watching(_ row: SessionRow, _ colour: WatchColour) -> SessionRow {
    var row = row
    row.watch = RowWatch(colour: colour, order: 0)
    return row
}

// The label of each entry, with "-" for a separator.
private func labels(_ entries: [RowMenuEntry]) -> [String] {
    entries.map { entry in
        switch entry {
        case .item(_, let label, _), .submenu(_, let label, _, _): label
        case .separator: "-"
        }
    }
}

private func actions(_ entries: [RowMenuEntry]) -> [ActionID?] {
    entries.map { entry in
        switch entry {
        case .item(let id, _, _), .submenu(let id, _, _, _): id
        case .separator: nil
        }
    }
}

private func entry(_ id: ActionID, in entries: [RowMenuEntry]) -> RowMenuEntry? {
    entries.first { entry in
        switch entry {
        case .item(let action, _, _), .submenu(let action, _, _, _): action == id
        case .separator: false
        }
    }
}

// The items of the submenu of the action, or nil when the entry is not a submenu.
private func items(_ id: ActionID, _ row: SessionRow, _ ctx: ActionContext = context())
    -> [SubItem]?
{
    guard case .submenu(_, _, _, let items) = entry(id, in: RowMenuModel.entries(row, ctx)) else {
        return nil
    }
    return items
}

@Suite("the row menu")
struct RowMenuModelTests {
    @Test func anOwnedRowWithAnOpenChatWindowGivesTheEntriesInOrder() {
        #expect(
            labels(RowMenuModel.entries(owned, context())) == [
                "Send message...", "Run slash command", "Compact", "Hand over", "Interrupt", "-",
                "Set priority", "Add to watchlist", "Rename...", "Show Info", "Copy session ID",
                "Open project", "Open in terminal", "-", "Close window", "Stop session...",
                "Delete session...",
            ])
    }

    @Test func openShowsOnlyWhileTheChatWindowIsClosed() {
        let closed = RowMenuModel.entries(owned, context(chatOpen: false))
        #expect(actions(closed).first == .open)
        #expect(entry(.closeWindow, in: closed) == nil)
        let open = RowMenuModel.entries(owned, context(chatOpen: true))
        #expect(entry(.open, in: open) == nil)
        #expect(entry(.closeWindow, in: open) != nil)
    }

    @Test func takeControlIsOnlyForAnExternalRowAndResumeOnlyForAParkedRow() {
        let externalMenu = RowMenuModel.entries(external, context())
        let parkedMenu = RowMenuModel.entries(parked, context())
        let ownedMenu = RowMenuModel.entries(owned, context())
        #expect(entry(.takeControl, in: externalMenu) != nil)
        #expect(entry(.resume, in: externalMenu) == nil)
        #expect(entry(.resume, in: parkedMenu) != nil)
        #expect(entry(.takeControl, in: parkedMenu) == nil)
        #expect(entry(.takeControl, in: ownedMenu) == nil)
        #expect(entry(.resume, in: ownedMenu) == nil)
        let ids = actions(externalMenu)
        #expect(Array(ids.suffix(4)) == [.takeControl, .closeWindow, .stop, .delete])
        #expect(Array(actions(parkedMenu).suffix(4)) == [.resume, .closeWindow, .stop, .delete])
    }

    // Each entry shows for each row class. An entry that does not fit is off, with its reason.
    @Test func anEntryThatDoesNotFitTheRowIsOffWithItsReason() {
        let compact = ActionState(enabled: false, reason: ActionReasons.external)
        #expect(
            entry(.compact, in: RowMenuModel.entries(external, context()))
                == .item(.compact, label: "Compact", state: compact))
        let menu = RowMenuModel.entries(parked, context())
        for case .item(let id, _, let state) in menu {
            #expect(state == ActionModel.state(id, parked, context()))
        }
    }

    @Test func handOverIsOnInTheMenuOfAnOwnedIdleRow() {
        #expect(
            entry(.handOver, in: RowMenuModel.entries(owned, context()))
                == .item(.handOver, label: "Hand over", state: .on))
    }

    @Test func theSpaceLabelsChangeEachLabel() {
        let menu = labels(RowMenuModel.entries(owned, context(chatOpen: false, labels: .space)))
        #expect(menu.first == "Warp to")
        #expect(menu.contains("Hail..."))
        #expect(menu.contains("Compress cargo"))
        #expect(menu.contains("Transfer command"))
        #expect(menu.contains("Power down..."))
        #expect(menu.contains("Track"))
        let watched = RowMenuModel.entries(watching(owned, .green), context(labels: .space))
        #expect(labels(watched).contains("Stop tracking"))
    }

    @Test func anUnwatchedRowGetsAddToWatchlistWithTheEightColours() {
        let menu = RowMenuModel.entries(owned, context())
        #expect(entry(.watchColour, in: menu) == nil)
        #expect(entry(.watchRemove, in: menu) == nil)
        let add = items(.watchAdd, owned)
        #expect(
            add?.map(\.label) == [
                "Dark red", "Red", "Amber", "Yellow", "Green", "Light blue", "Dark blue", "White",
            ])
        #expect(add?.map(\.arg) == WatchColour.allCases.map(MenuArg.colour))
        #expect(add?.map(\.key) == WatchColour.allCases.map(\.rawValue))
        #expect(add.map(RowMenuModel.checkedKey) == .some(nil))
        guard case .submenu(_, let label, let state, _) = entry(.watchAdd, in: menu) else {
            Issue.record("Add to watchlist is not a submenu")
            return
        }
        #expect(label == "Add to watchlist")
        #expect(state == ActionState(enabled: true, reason: nil))
    }

    @Test func aWatchedRowGetsChangeColourWithItsColourCheckedAndRemove() {
        let row = watching(owned, .lightBlue)
        let menu = RowMenuModel.entries(row, context())
        #expect(entry(.watchAdd, in: menu) == nil)
        let remove = ActionState(enabled: true, reason: nil)
        #expect(
            entry(.watchRemove, in: menu)
                == .item(.watchRemove, label: "Remove from watchlist", state: remove))
        let change = items(.watchColour, row)
        #expect(change?.filter(\.checked).map(\.arg) == [.colour(.lightBlue)])
        #expect(change.map(RowMenuModel.checkedKey) == "light-blue")
        let ids = actions(menu)
        let colour = ids.firstIndex(of: .watchColour)
        #expect(colour.map { ids[$0 + 1] } == .watchRemove)
    }

    @Test func setPriorityChecksThePriorityOfTheRowOrNone() {
        var row = owned
        row.priority = .p2
        let withPriority = items(.setPriority, row)
        #expect(withPriority?.map(\.label) == ["1", "2", "3", "4", "5", "None"])
        #expect(withPriority?.map(\.key) == ["1", "2", "3", "4", "5", "none"])
        let args = SessionPriority.allCases.map { MenuArg.priority($0) } + [.priority(nil)]
        #expect(withPriority?.map(\.arg) == args)
        #expect(withPriority?.filter(\.checked).map(\.arg) == [.priority(.p2)])
        #expect(items(.setPriority, owned).map(RowMenuModel.checkedKey) == "none")
    }

    @Test func openProjectListsTheApps() {
        #expect(
            items(.openProject, owned) == [
                SubItem(key: "finder", label: "Finder", arg: .app(.finder)),
                SubItem(key: "warp", label: "Warp", arg: .app(.warp)),
            ])
    }

    // The favourites come first, then up to 5 recent commands that are not favourites, then
    // Other... A separator comes before the first recent command and before Other...
    @Test func runSlashCommandGivesTheFavouritesFiveRecentCommandsAndOther() throws {
        let ctx = context(
            slashFavourites: ["/compact", "/clear", "/context"],
            slashRecent: ["/context", "/a", "/b", "/c", "/d", "/e", "/f"])
        let slash = try #require(items(.runSlash, owned, ctx))
        #expect(
            slash.map(\.label) == [
                "/compact", "/clear", "/context", "/a", "/b", "/c", "/d", "/e", "Other...",
            ])
        #expect(
            slash.map(\.key) == [
                "fav:/compact", "fav:/clear", "fav:/context", "recent:/a", "recent:/b",
                "recent:/c", "recent:/d", "recent:/e", "other",
            ])
        #expect(slash.filter(\.separatorBefore).map(\.label) == ["/a", "Other..."])
        #expect(slash.last?.arg == .otherSlash)
        #expect(slash.dropLast().map(\.arg) == slash.dropLast().map { .slash($0.label) })
        #expect(ActionModel.slashMenuRecent == 5)
    }

    @Test func runSlashCommandWithNoCommandsHasOnlyOther() {
        let other = SubItem(
            key: "other", label: "Other...", arg: .otherSlash, separatorBefore: true)
        #expect(items(.runSlash, owned) == [other])
    }

    @Test func theOtherEntriesHaveNoSubmenu() {
        let menu = RowMenuModel.entries(owned, context(chatOpen: false))
        let submenus = menu.compactMap { entry -> ActionID? in
            if case .submenu(let id, _, _, _) = entry { id } else { nil }
        }
        #expect(submenus == [.runSlash, .setPriority, .watchAdd, .openProject])
    }

    @Test func theCheckedKeyIsTheKeyOfTheFirstCheckedItem() {
        let one = SubItem(key: "1", label: "One", arg: .priority(.p1))
        let two = SubItem(key: "2", label: "Two", arg: .priority(.p2), checked: true)
        #expect(RowMenuModel.checkedKey([one, two]) == "2")
        #expect(RowMenuModel.checkedKey([one]) == nil)
        #expect(RowMenuModel.checkedKey([]) == nil)
    }
}
