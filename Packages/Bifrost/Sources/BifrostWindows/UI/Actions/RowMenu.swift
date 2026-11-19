// The row menu of the Overview (docs/behaviour/actions.md, "The row menu") on the Bifrost menu:
// the rows of RowMenuModel.entries. An item is an item row, a submenu is a submenu row and a
// separator is a separator. A disabled entry keeps its place, and its tooltip is the title and
// the reason (ActionModel.buttonTip). Set priority and Change colour give radio rows with the
// current one checked, each with the colour square of the priority or of the watch colour. The
// other submenu items are item rows, with a separator before an item with separatorBefore.
//
// The menu shows the row of now. While it is open, each change of the row or of its context
// gives the menu the new entries (BifrostMenu.update keeps the highlight and the open submenus
// while their rows are still there), and the menu closes when the row leaves the list
// (FollowingMenu, which the row menu of the Reviews panel uses too). A choice
// runs ActionRunner.run with the ID of the row and the choice of the submenu, so the runner reads
// the row of now: the menu never acts on the row value that it was opened with. It is a context
// menu: a press outside only closes it (BifrostMenu.OutsidePress.closesOnly). The colour menu of
// Add to watchlist in the Selected Item panel uses the same watch of the row.
import AppKit
import BifrostFoundation
import BifrostLook
import BifrostSessions
import Observation

@MainActor
package enum RowMenu {
    // The rows of the menu, and the action and the choice of each row ID.
    package struct Menu: Sendable {
        package let rows: [MenuRow]
        package let choices: [String: (ActionID, MenuArg?)]
    }

    // The rows of the menu of the row, with the context of the runner now.
    package static func rows(_ row: SessionRow, runner: ActionRunner) -> [MenuRow] {
        menu(row, runner: runner).rows
    }

    // Show the menu of the row at the point (in the coordinates of the view) over the window of
    // the view. The rows come from the row of now. A row that went shows no menu.
    package static func show(
        _ row: SessionRow, at point: NSPoint, in view: NSView, runner: ActionRunner,
        menu: BifrostMenu
    ) {
        guard let window = view.window else { return }
        let screen = window.convertPoint(toScreen: view.convert(point, to: nil))
        show(
            row.sessionId, at: .point(screen), in: window, runner: runner, menu: menu,
            make: { row, runner in Self.menu(row, runner: runner) })
    }

    // Show the menu that make gives for the row of now, as a context menu that follows the row
    // (FollowingMenu): it closes when the row leaves the list or make gives nil. A choice uses
    // the choices of the rows that show. A row that went, or a nil from make, shows no menu.
    package static func show(
        _ sessionId: String, at placement: BifrostMenu.Placement, in window: NSWindow,
        runner: ActionRunner, menu: BifrostMenu,
        make: @escaping @MainActor (SessionRow, ActionRunner) -> Menu?
    ) {
        FollowingMenu.show(
            { [weak runner] () -> Menu? in
                guard let runner, let row = runner.row(sessionId) else { return nil }
                return make(row, runner)
            }, rows: \.rows, at: placement, in: window, menu: menu,
            onChoose: { [weak runner] id, shown in
                guard let runner, let (action, arg) = shown.choices[id] else { return }
                runner.run(action, sessionId, arg: arg)
            })
    }

    package static func menu(_ row: SessionRow, runner: ActionRunner) -> Menu {
        let ctx = runner.context(row.sessionId)
        var choices: [String: (ActionID, MenuArg?)] = [:]
        let rows = RowMenuModel.entries(row, ctx).map { entry -> MenuRow in
            switch entry {
            case .separator:
                return .separator
            case .item(let action, let label, let state):
                choices[action.rawValue] = (action, nil)
                return .item(spec(action, label, state, ctx.labels))
            case .submenu(let action, let label, let state, let items):
                var sub: [MenuRow] = []
                let checked = RowMenuModel.checkedKey(items)
                let radio = action == .setPriority || action == .watchColour
                for item in items {
                    if item.separatorBefore { sub.append(.separator) }
                    let id = "\(action.rawValue)/\(item.key)"
                    choices[id] = (action, item.arg)
                    let itemSpec = MenuItemSpec(
                        id: id, label: item.label, swatch: swatch(item.arg),
                        swatchSpace: radio && swatch(item.arg) == nil)
                    sub.append(
                        radio ? .radio(itemSpec, checked: item.key == checked) : .item(itemSpec))
                }
                return .submenu(spec(action, label, state, ctx.labels), rows: sub)
            }
        }
        return Menu(rows: rows, choices: choices)
    }

    // The parts of an entry row. A disabled entry has the title and the reason as its tooltip.
    private static func spec(
        _ action: ActionID, _ label: String, _ state: ActionState, _ labels: LabelSet
    ) -> MenuItemSpec {
        MenuItemSpec(
            id: action.rawValue, label: label, enabled: state.enabled,
            reason: state.enabled ? nil : ActionModel.buttonTip(action, state, labels))
    }

    // The colour square of a choice: the colour of a priority or of a watch colour. None and the
    // other choices have none.
    private static func swatch(_ arg: MenuArg) -> TokenColour? {
        switch arg {
        case .priority(let priority?): ThemeTokens.priority(priority.rawValue)
        case .colour(let colour): colour.token
        default: nil
        }
    }
}

// A context menu that follows a value of now, for example the row menu of a session or of a
// Reviews row. current gives the value of now, or nil when its row went. While the menu is open,
// a watch of current gives the menu the new rows at each change (only rows that changed redraw),
// and closes it at a nil. A choice gets its ID with the value that shows, so it never acts on the
// value that the menu opened with. A press outside only closes the menu
// (BifrostMenu.OutsidePress.closesOnly). The watch ends at each close of the menu, so it never
// changes or closes a later menu.
@MainActor
package enum FollowingMenu {
    package static func show<Value: Sendable>(
        _ current: @escaping @MainActor () -> Value?,
        rows: @escaping @MainActor (Value) -> [MenuRow], at placement: BifrostMenu.Placement,
        in window: NSWindow, menu: BifrostMenu,
        onChoose: @escaping @MainActor (String, Value) -> Void
    ) {
        guard let first = current() else { return }
        let shown = Shown(first)
        // The watch starts before the menu shows, so the close of the menu always has it. The
        // task runs after this call, when the menu shows.
        let changes = Observations { current() }
        let watch = Task { [weak menu] in
            for await next in changes {
                guard !Task.isCancelled, let menu else { return }
                guard let next else {
                    menu.close()
                    return
                }
                // A source can change at each update of any row, so only new rows redraw.
                let old = rows(shown.value)
                shown.value = next
                let new = rows(next)
                if new != old { menu.update(new) }
            }
        }
        menu.show(
            rows(first), width: nil, at: placement, in: window, outsidePress: .closesOnly,
            onChoose: { id in onChoose(id, shown.value) }, onField: { _, _ in },
            onClose: { watch.cancel() })
    }

    // The value that an open menu shows. The watch changes it.
    @MainActor
    private final class Shown<Kept> {
        var value: Kept

        init(_ value: Kept) {
            self.value = value
        }
    }
}
