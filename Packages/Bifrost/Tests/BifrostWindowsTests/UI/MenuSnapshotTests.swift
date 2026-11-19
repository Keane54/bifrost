import AppKit
import BifrostTestSupport
import Testing

@testable import BifrostLook
@testable import BifrostWindows

// The snapshot of the Bifrost menu (docs/behaviour/menu.md, "The look"): one row of each kind, at
// the Interface scale 100. The rows are test rows.
@Suite("menu snapshot", .serialized, .testTimeLimit, .tags(.window))
@MainActor
struct MenuSnapshotTests {
    private let snapshot = Snapshot(bundle: .module, target: "BifrostWindowsTests")

    // An item, a disabled item, a separator, a check box that is on (a box with a check mark), a
    // check box that is off (an empty box), a check row that is on (a check mark with no box), a
    // checked radio with a colour square, a radio that keeps the space of a colour square (its
    // label lines up) and a submenu with the highlight.
    @Test func theMenuWithEachRowKindMatchesItsSnapshot() throws {
        let d = MenuDriver()
        let window = MenuDriver.window()
        defer { window.close() }
        let rows: [MenuRow] = [
            .item(MenuItemSpec(id: "open", label: "Open project")),
            .item(MenuItemSpec(id: "off", label: "Hand over", enabled: false, reason: "Later.")),
            .separator,
            .checkbox(MenuItemSpec(id: "lock", label: "Lock"), checked: true),
            .checkbox(MenuItemSpec(id: "wrap", label: "Wrap"), checked: false),
            .check(MenuItemSpec(id: "box", label: "Only rows with a box"), checked: true),
            .radio(
                MenuItemSpec(id: "p1", label: "Priority 1", swatch: ThemeTokens.icons[0]),
                checked: true),
            .radio(MenuItemSpec(id: "none", label: "None", swatchSpace: true), checked: false),
            .submenu(
                MenuItemSpec(id: "more", label: "More"),
                rows: [.item(MenuItemSpec(id: "x", label: "X"))]),
        ]
        d.show(rows, in: window)
        try d.key("End")
        let list = try d.root.list
        #expect(list.state.highlighted == 8)
        snapshot.check(list, named: "menu-row-kinds", background: ThemeTokens.bg.nsColor)
    }
}
