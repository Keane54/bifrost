import BifrostLook
import Foundation
import Testing

@testable import BifrostWindows

// The keys and the pointer of a Bifrost menu: each rule of docs/behaviour/menu.md, "Keys and the
// pointer", has a test here. The times are the times of the presenter, on its clock.
@Suite("menu navigation")
struct MenuNavigationTests {
    private static func item(_ id: String, enabled: Bool = true) -> MenuRow {
        .item(MenuItemSpec(id: id, label: id.capitalized, enabled: enabled))
    }

    // Alpha, a disabled Bravo, a separator, Charlie, and the submenu Delta with Echo and Foxtrot.
    private static let rows: [MenuRow] = [
        item("alpha"), item("bravo", enabled: false), .separator, item("charlie"),
        .submenu(
            MenuItemSpec(id: "delta", label: "Delta"), rows: [item("echo"), item("foxtrot")]),
    ]

    private static func menu(_ rows: [MenuRow] = rows) -> MenuNavigation {
        MenuNavigation(rows: rows)
    }

    private static let t0 = Duration.zero

    @Test func downFromNothingHighlightsTheFirstRow() {
        var menu = Self.menu()
        #expect(menu.highlighted == nil)
        menu.key(.down, now: Self.t0)
        #expect(menu.highlighted == [0])
        #expect(menu.takeEffects() == [.highlight([0])])
        // The effects go after a take.
        #expect(menu.takeEffects().isEmpty)
    }

    @Test func upFromNothingHighlightsTheLastRow() {
        var menu = Self.menu()
        menu.key(.up, now: Self.t0)
        #expect(menu.highlighted == [4])
    }

    @Test func theKeysWrapAtTheEnds() {
        var menu = Self.menu()
        menu.key(.up, now: Self.t0)
        menu.key(.down, now: Self.t0)
        #expect(menu.highlighted == [0])
        menu.key(.up, now: Self.t0)
        #expect(menu.highlighted == [4])
    }

    // Home and End skip a separator at the ends, and a disabled row at the ends takes them.
    @Test func homeAndEndGoToTheFirstAndLastRow() {
        var menu = Self.menu([Self.item("x", enabled: false)] + Self.rows + [.separator])
        menu.key(.end, now: Self.t0)
        #expect(menu.highlighted == [5])
        menu.key(.home, now: Self.t0)
        #expect(menu.highlighted == [0])
    }

    // The keys land on a disabled row, so its reason shows. Return and Space on it do nothing. A
    // separator is skipped.
    @Test func aDisabledRowTakesTheHighlightAndASeparatorIsSkipped() {
        var menu = Self.menu()
        menu.key(.down, now: Self.t0)
        menu.key(.down, now: Self.t0)
        #expect(menu.highlighted == [1])
        _ = menu.takeEffects()
        menu.key(.enter, now: Self.t0)
        menu.key(.space, now: Self.t0)
        #expect(menu.takeEffects().isEmpty)
        menu.key(.down, now: Self.t0)
        #expect(menu.highlighted == [3])
        menu.key(.up, now: Self.t0)
        #expect(menu.highlighted == [1])
        // A menu of a disabled row and a separator highlights the disabled row.
        var off = Self.menu([Self.item("x", enabled: false), .separator])
        off.key(.down, now: Self.t0)
        #expect(off.highlighted == [0])
        off.key(.down, now: Self.t0)
        #expect(off.highlighted == [0])
    }

    @Test func rightOpensASubmenuAndHighlightsItsFirstRow() {
        var menu = Self.menu()
        menu.key(.end, now: Self.t0)
        _ = menu.takeEffects()
        menu.key(.right, now: Self.t0)
        #expect(menu.open == [[4]])
        #expect(menu.highlighted == [4, 0])
        #expect(menu.takeEffects() == [.openSubmenu([4]), .highlight([4, 0])])
        // Up and Down move inside the submenu and wrap there.
        menu.key(.up, now: Self.t0)
        #expect(menu.highlighted == [4, 1])
        // Right on a row with no submenu does nothing.
        _ = menu.takeEffects()
        menu.key(.right, now: Self.t0)
        #expect(menu.takeEffects().isEmpty)
    }

    @Test func leftClosesTheSubmenuAndKeepsTheParentHighlighted() {
        var menu = Self.menu()
        menu.key(.end, now: Self.t0)
        menu.key(.right, now: Self.t0)
        _ = menu.takeEffects()
        menu.key(.left, now: Self.t0)
        #expect(menu.open.isEmpty)
        #expect(menu.highlighted == [4])
        #expect(menu.takeEffects() == [.closeSubmenu([4]), .highlight([4])])
        // Left in the root menu does nothing.
        menu.key(.left, now: Self.t0)
        #expect(menu.takeEffects().isEmpty)
        // A move to another row of the parent closes an open submenu.
        menu.key(.right, now: Self.t0)
        menu.key(.left, now: Self.t0)
        _ = menu.takeEffects()
        menu.key(.right, now: Self.t0)
        _ = menu.takeEffects()
        menu.hover([0], now: Self.t0)
        #expect(menu.open.isEmpty)
        #expect(menu.takeEffects() == [.highlight([0]), .closeSubmenu([4])])
    }

    @Test func aDisabledSubmenuDoesNotOpen() {
        let sub = MenuRow.submenu(
            MenuItemSpec(id: "s", label: "Sub", enabled: false), rows: [Self.item("x")])
        var menu = Self.menu([Self.item("a"), sub])
        // The keys and the pointer highlight it, but no key, hover or click opens it.
        menu.key(.down, now: Self.t0)
        menu.key(.down, now: Self.t0)
        #expect(menu.highlighted == [1])
        menu.hover([1], now: Self.t0)
        #expect(menu.openDue == nil)
        menu.key(.right, now: Self.t0)
        menu.key(.enter, now: Self.t0)
        menu.click([1])
        menu.timerFired(now: .seconds(1))
        #expect(menu.open.isEmpty)
        #expect(menu.takeEffects() == [.highlight([0]), .highlight([1])])
    }

    @Test func returnAndSpaceChooseTheHighlightedRow() {
        var menu = Self.menu()
        menu.key(.down, now: Self.t0)
        _ = menu.takeEffects()
        menu.key(.enter, now: Self.t0)
        #expect(menu.takeEffects() == [.choose([0]), .dismiss])
        menu.key(.space, now: Self.t0)
        #expect(menu.takeEffects() == [.choose([0]), .dismiss])
        // Return on a submenu row opens it.
        menu.key(.end, now: Self.t0)
        _ = menu.takeEffects()
        menu.key(.enter, now: Self.t0)
        #expect(menu.takeEffects() == [.openSubmenu([4]), .highlight([4, 0])])
        // With no highlight, Return does nothing.
        var none = Self.menu()
        none.key(.enter, now: Self.t0)
        #expect(none.takeEffects().isEmpty)
        // A click chooses an enabled row, and a click on a disabled row or a separator does
        // nothing.
        var clicked = Self.menu()
        clicked.click([3])
        #expect(clicked.takeEffects() == [.highlight([3]), .choose([3]), .dismiss])
        clicked.click([1])
        clicked.click([2])
        #expect(clicked.takeEffects() == [.highlight([1])])
    }

    @Test func aCheckboxRowKeepsTheMenuOpen() {
        let lock = MenuRow.checkbox(MenuItemSpec(id: "lock", label: "Lock"), checked: false)
        var menu = Self.menu([lock, Self.item("other")])
        menu.key(.down, now: Self.t0)
        _ = menu.takeEffects()
        menu.key(.enter, now: Self.t0)
        menu.key(.space, now: Self.t0)
        menu.click([0])
        #expect(menu.takeEffects() == [.choose([0]), .choose([0]), .choose([0])])
        // A new row list with the same shape keeps the highlight.
        menu.setRows([
            .checkbox(MenuItemSpec(id: "lock", label: "Lock"), checked: true), Self.item("other"),
        ])
        #expect(menu.highlighted == [0])
        #expect(menu.takeEffects().isEmpty)
    }

    // A check row (a check mark with no box) keeps the menu open, as a check box row does.
    @Test func aCheckRowKeepsTheMenuOpen() {
        let filter = MenuRow.check(MenuItemSpec(id: "box", label: "Box only"), checked: false)
        var menu = Self.menu([filter, Self.item("other")])
        menu.key(.down, now: Self.t0)
        _ = menu.takeEffects()
        menu.key(.enter, now: Self.t0)
        menu.click([0])
        #expect(menu.takeEffects() == [.choose([0]), .choose([0])])
    }

    @Test func aRadioRowClosesTheMenu() {
        let rows: [MenuRow] = [
            .radio(
                MenuItemSpec(id: "p1", label: "P1", swatch: ThemeTokens.icons[0]), checked: true),
            .radio(MenuItemSpec(id: "none", label: "None", swatchSpace: true), checked: false),
        ]
        var menu = Self.menu(rows)
        menu.key(.up, now: Self.t0)
        _ = menu.takeEffects()
        menu.key(.enter, now: Self.t0)
        #expect(menu.takeEffects() == [.choose([1]), .dismiss])
    }

    @Test func escClosesTheSubmenuThenTheMenu() {
        var menu = Self.menu()
        menu.key(.end, now: Self.t0)
        menu.key(.right, now: Self.t0)
        _ = menu.takeEffects()
        menu.key(.escape, now: Self.t0)
        #expect(menu.open.isEmpty)
        #expect(menu.highlighted == [4])
        #expect(menu.takeEffects() == [.closeSubmenu([4]), .highlight([4])])
        menu.key(.escape, now: Self.t0)
        #expect(menu.takeEffects() == [.dismiss])
    }

    @Test func typingHighlightsTheNextRowThatStartsWithTheText() {
        let rows: [MenuRow] = [
            Self.item("stop"), Self.item("start"), Self.item("send", enabled: false),
            Self.item("rename"), Self.item("resume"),
        ]
        var menu = Self.menu(rows)
        // The case does not matter, and a disabled row takes the highlight too.
        menu.key(.text("s"), now: .milliseconds(0))
        #expect(menu.highlighted == [0])
        // The same letter again goes to the next row with that letter, also within the reset time:
        // a repeat of one letter cycles through its rows.
        menu.key(.text("s"), now: .seconds(1))
        #expect(menu.highlighted == [1])
        menu.key(.text("S"), now: .seconds(1) + .milliseconds(100))
        #expect(menu.highlighted == [2])
        menu.key(.text("s"), now: .seconds(1) + .milliseconds(200))
        #expect(menu.highlighted == [0])
        menu.key(.text("s"), now: .seconds(2))
        menu.key(.text("s"), now: .seconds(2) + .milliseconds(100))
        #expect(menu.highlighted == [2])
        // A longer text matches from the row of the highlight.
        menu.key(.text("r"), now: .seconds(3))
        menu.key(.text("e"), now: .seconds(3) + .milliseconds(100))
        menu.key(.text("s"), now: .seconds(3) + .milliseconds(200))
        #expect(menu.highlighted == [4])
        // A text that no row starts with keeps the highlight.
        menu.key(.text("q"), now: .seconds(5))
        #expect(menu.highlighted == [4])
    }

    // Space during a type-ahead adds to the typed text, and Space after the reset time chooses.
    @Test func spaceAddsToARunningTypeaheadAndElseChooses() {
        let rows: [MenuRow] = [
            .item(MenuItemSpec(id: "terminal", label: "Open in terminal")),
            .item(MenuItemSpec(id: "project", label: "Open project")),
        ]
        var menu = Self.menu(rows)
        var now = Duration.zero
        for character in ["o", "p", "e", "n"] {
            menu.key(.text(character), now: now)
            now += .milliseconds(100)
        }
        #expect(menu.highlighted == [0])
        menu.key(.space, now: now)
        menu.key(.text("p"), now: now + .milliseconds(100))
        #expect(menu.highlighted == [1])
        _ = menu.takeEffects()
        menu.key(.space, now: now + .seconds(2))
        #expect(menu.takeEffects() == [.choose([1]), .dismiss])
    }

    @Test func theTypedTextResetsAfter750ms() {
        let rows: [MenuRow] = [Self.item("bravo"), Self.item("echo"), Self.item("beta")]
        var menu = Self.menu(rows)
        menu.key(.text("b"), now: .zero)
        menu.key(.text("e"), now: .milliseconds(749))
        // "be" goes to Beta.
        #expect(menu.highlighted == [2])
        // 750 ms after the last key, the text starts again: "e" goes to Echo.
        menu.key(.text("e"), now: .milliseconds(749 + 750))
        #expect(menu.highlighted == [1])
        #expect(MenuNavigation.typeaheadReset == .milliseconds(750))
    }

    @Test func aHoverOnASubmenuRowOpensItAfter100ms() {
        var menu = Self.menu()
        menu.hover([4], now: .seconds(1))
        #expect(menu.highlighted == [4])
        #expect(menu.openDue == .seconds(1) + .milliseconds(100))
        // A move on the same row does not start the delay again.
        menu.hover([4], now: .seconds(1) + .milliseconds(50))
        #expect(menu.openDue == .seconds(1) + .milliseconds(100))
        menu.timerFired(now: .seconds(1) + .milliseconds(99))
        #expect(menu.open.isEmpty)
        menu.timerFired(now: .seconds(1) + .milliseconds(100))
        #expect(menu.open == [[4]])
        #expect(menu.openDue == nil)
        // The highlight stays on the row: the pointer is on it.
        #expect(menu.takeEffects() == [.highlight([4]), .openSubmenu([4])])
        // The pointer goes into the submenu: its row gets the highlight, and the submenu stays.
        menu.hover(nil, now: .seconds(2))
        menu.hover([4, 1], now: .seconds(2))
        #expect(menu.open == [[4]])
        #expect(menu.takeEffects() == [.highlight([]), .highlight([4, 1])])
        #expect(MenuNavigation.submenuDelay == .milliseconds(100))
    }

    @Test func aHoverOnAnotherRowClosesTheSubmenu() {
        var menu = Self.menu()
        menu.hover([4], now: .zero)
        menu.timerFired(now: .milliseconds(100))
        _ = menu.takeEffects()
        menu.hover([3], now: .seconds(1))
        #expect(menu.open.isEmpty)
        #expect(menu.takeEffects() == [.highlight([3]), .closeSubmenu([4])])
        // A pointer that leaves the submenu row before the delay cancels the open.
        menu.hover([4], now: .seconds(2))
        menu.hover([0], now: .seconds(2) + .milliseconds(50))
        #expect(menu.openDue == nil)
        menu.timerFired(now: .seconds(3))
        #expect(menu.open.isEmpty)
        // A pointer over a disabled row highlights it, and one over a separator changes nothing.
        menu.hover([1], now: .seconds(4))
        #expect(menu.highlighted == [1])
        menu.hover([2], now: .seconds(4))
        #expect(menu.highlighted == [1])
    }

    @Test func aFieldRowTakesTheTypedTextAndEnterSaves() {
        let rows: [MenuRow] = [
            .checkbox(MenuItemSpec(id: "lock", label: "Lock"), checked: false),
            .field(id: "name", label: "Tab set name", text: "Default", maxLength: 40),
        ]
        var menu = Self.menu(rows)
        // The keys reach the field, and a hover does not take the highlight to it.
        menu.hover([1], now: .zero)
        #expect(menu.highlighted == nil)
        menu.key(.up, now: .zero)
        #expect(menu.highlighted == [1])
        _ = menu.takeEffects()
        // The field takes the text and the keys that edit it: no row of the menu changes.
        for key: MenuKey in [.text("l"), .left, .right, .home, .end, .space] {
            menu.key(key, now: .zero)
        }
        #expect(menu.highlighted == [1])
        #expect(menu.takeEffects().isEmpty)
        // The pointer does not take the highlight from the field.
        menu.hover([0], now: .zero)
        menu.hover(nil, now: .zero)
        #expect(menu.highlighted == [1])
        // Enter saves and keeps the menu open.
        menu.key(.enter, now: .zero)
        #expect(menu.takeEffects() == [.choose([1])])
        // Up leaves the field, and Esc still closes the menu.
        menu.key(.up, now: .zero)
        #expect(menu.highlighted == [0])
        menu.focusField([1])
        #expect(menu.highlighted == [1])
        _ = menu.takeEffects()
        menu.key(.escape, now: .zero)
        #expect(menu.takeEffects() == [.dismiss])
    }
}
