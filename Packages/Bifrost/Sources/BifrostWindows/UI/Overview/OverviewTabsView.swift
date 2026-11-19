// The tab bar of an Overview (docs/behaviour/overview.md, The tab bar), in SwiftUI in one
// NSHostingView above the rows (OverviewPanel): one tab for each tab of the config, in order and in
// its tab colour, with a line under the active tab, then the Add tab button.
//
// - A click on a tab activates it. A double-click, or Rename... of the tab menu, shows the name
//   field "Tab name" in place of the tab. Each end of the rename saves the name, except Esc
//   (TabRename).
// - A right-click on a tab opens the tab menu (OverviewTabMenu) on the Bifrost menu of the
//   window, at the click point. The tab bar knows the frame of each tab (TabFrames), so the host
//   finds the tab under the click.
// - The Add tab button is off at 12 tabs, and its tooltip then gives the reason.
// - No tab and no button is focusable (the section "The UI" of the architecture design). Only
//   the name field takes the focus, during a rename. After each other action of the tab bar and
//   of the tab menu, the rows of the Overview get the focus, so the Bifrost keys act on this
//   Overview.
//
// The tabs and the Add tab button are values with their actions (TabItem, AddTabButton), so the
// tests read them and call the action of a click.
import AppKit
import BifrostLayout
import BifrostLook
import BifrostSessions
import SwiftUI

// The rename of a tab in the tab bar: the tab whose name field shows, and the text of the field.
// Each end of a rename saves the name, except Esc:
// - Enter, and the loss of the focus;
// - a press of a mouse button outside the field: on another tab, on Add tab, on the rows or on the
//   canvas;
// - the loss of the key state of the window, for example a switch to another app;
// - each action of the tab bar and of the tab menu, and the start of another rename.
// Only while a rename runs, a local monitor watches the presses and a task follows the window.
// After Enter and Esc, and after an end while the field has the focus, the focus goes back to the
// rows of the Overview.
@MainActor
@Observable
package final class TabRename {
    package private(set) var tab: String?
    package var draft = ""
    // Saves a name: the action renameTab of the Overview.
    @ObservationIgnored private let save: (_ tab: String, _ name: String) -> Void
    // The host of the tab bar, which holds the name field.
    @ObservationIgnored weak var host: NSView?
    // Gives the focus to the rows of the Overview, so the Bifrost keys act on it again. The tab
    // bar also calls it after each action that is not a rename.
    @ObservationIgnored package var refocus: () -> Void = {}
    @ObservationIgnored private var presses: Any?
    @ObservationIgnored private var resigns: Task<Void, Never>?

    package init(save: @escaping (_ tab: String, _ name: String) -> Void) {
        self.save = save
    }

    isolated deinit {
        unwatch()
    }

    // True while the monitor of the presses is on: only during a rename.
    package var watching: Bool { presses != nil }

    // Show the name field of the tab. A rename that runs saves first.
    package func begin(_ tab: OverviewTab) {
        finish()
        self.tab = tab.id
        draft = tab.name
        watch()
    }

    // End the rename and save the name. With no rename, nothing happens. Enter removes the
    // field, and then the field loses the focus: the second end does nothing.
    package func finish() {
        end(save: true, fromKey: false)
    }

    // Enter: end the rename and save the name. The field can lose the focus before its submit,
    // so the rows get the focus also then.
    package func submit() {
        end(save: true, fromKey: true)
    }

    // Esc: end the rename and keep the old name.
    package func cancel() {
        end(save: false, fromKey: true)
    }

    // A press of a mouse button in the app, from the monitor, before the view under the pointer
    // gets it. A press outside the name field ends the rename with a save.
    package func pointerDown(_ event: NSEvent) {
        guard tab != nil else { return }
        if let field, event.window === field.window,
            field.bounds.contains(field.convert(event.locationInWindow, from: nil))
        {
            return
        }
        finish()
    }

    // fromKey: Enter or Esc of the field ends the rename.
    private func end(save: Bool, fromKey: Bool) {
        guard let tab else { return }
        let focused = field != nil
        self.tab = nil
        unwatch()
        if save { self.save(tab, draft) }
        if fromKey {
            // A change of the first responder during the key event of the field leaves the focus
            // of SwiftUI in a bad state, so the change comes after the event. A rename that
            // starts before then keeps its focus.
            Task { [weak self] in
                guard let self, self.tab == nil else { return }
                refocus()
            }
        } else if focused {
            // The field gives up the focus now, before the field of a next rename shows.
            refocus()
        }
    }

    // The text field of the rename while it has the focus: the field editor is the first
    // responder of the window, and the field is its delegate.
    private var field: NSView? {
        guard let host, let editor = host.window?.firstResponder as? NSText,
            let field = editor.delegate as? NSView, field.isDescendant(of: host)
        else { return nil }
        return field
    }

    private func watch() {
        if presses == nil {
            let mask: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown]
            presses = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
                self?.pointerDown(event)
                return event
            }
        }
        guard resigns == nil, let window = host?.window else { return }
        let changes = NotificationCenter.default.notifications(
            named: NSWindow.didResignKeyNotification, object: window)
        resigns = Task { [weak self] in
            for await _ in changes { self?.finish() }
        }
    }

    private func unwatch() {
        if let presses { NSEvent.removeMonitor(presses) }
        presses = nil
        resigns?.cancel()
        resigns = nil
    }
}

// One tab of the tab bar, with the actions of a click and of a double-click.
@MainActor
package struct TabItem: Identifiable {
    package let id: String
    package let name: String
    // The index of the tab colour.
    package let colour: Int
    package let active: Bool
    package let activate: () -> Void
    // A double-click and Rename... of the tab menu: the name field shows.
    package let rename: () -> Void
    // The accessibility action "Show menu": the tab menu opens below the tab.
    package let showMenu: () -> Void
}

// The frames of the tabs and of the visible part of the tab list, in the coordinates of the tab
// bar (top left origin). The host finds the tab under a right-click with them.
@MainActor
package final class TabFrames {
    nonisolated static let space = "overview-tabs"
    package var tabs: [String: CGRect] = [:]
    package var visible: CGRect = .zero
    // The host of the tab bar.
    weak var host: NSView?

    // The tab at the point, or nil. A tab that the list scrolled out of view is not at a point.
    package func tab(at point: CGPoint) -> String? {
        guard visible.contains(point) else { return nil }
        return tabs.first { $0.value.contains(point) }?.key
    }

    // The rect of the tab in screen coordinates, or nil.
    func screenRect(of tab: String) -> NSRect? {
        guard let host, let window = host.window, let rect = tabs[tab] else { return nil }
        let local =
            host.isFlipped
            ? rect
            : NSRect(
                x: rect.minX, y: host.bounds.height - rect.maxY, width: rect.width,
                height: rect.height)
        return window.convertToScreen(host.convert(local, to: nil))
    }
}

// The Add tab button: on or off, the text of its tooltip and its action.
@MainActor
package struct AddTabButton {
    package let enabled: Bool
    package let tip: String
    package let action: () -> Void
}

package struct OverviewTabsView: View {
    package let model: OverviewModel
    package let panel: PanelID
    private let look: PanelLook
    // The rename of this tab bar. The host keeps the view, so the view keeps one rename.
    package let rename: TabRename
    // The frames of the tabs, for the tab menu.
    package let frames = TabFrames()

    package init(model: OverviewModel, panel: PanelID, look: PanelLook) {
        self.model = model
        self.panel = panel
        self.look = look
        rename = TabRename { model.update(panel, .renameTab($0, name: $1)) }
    }

    // The tabs in the order of the config.
    package var tabs: [TabItem] {
        let config = model.config(panel)
        let (model, panel, rename, frames) = (model, panel, rename, frames)
        return config.tabs.map { tab in
            TabItem(
                id: tab.id, name: tab.name, colour: tab.colour, active: tab.id == config.active,
                activate: {
                    rename.finish()
                    model.update(panel, .activate(tab.id))
                    rename.refocus()
                },
                rename: { rename.begin(tab) },
                showMenu: {
                    guard let rect = frames.screenRect(of: tab.id), let window = frames.host?.window
                    else { return }
                    OverviewTabMenu.show(
                        model: model, panel: panel, tab: tab.id, rename: rename,
                        at: .below(rect, rightEdge: false), in: window)
                })
        }
    }

    package var addButton: AddTabButton {
        let full = model.config(panel).tabs.count >= OverviewConfig.maxTabs
        let (model, panel, rename) = (model, panel, rename)
        return AddTabButton(
            enabled: !full, tip: full ? OverviewRefusal.maxTabs.message : "Add tab",
            action: {
                rename.finish()
                model.update(panel, .addTab)
                rename.refocus()
            })
    }

    package var body: some View {
        let metrics = look.metrics
        HStack(spacing: 0) {
            // The tabs scroll sideways when they do not fit. The bar shows no scroll bar.
            ScrollView(.horizontal) {
                HStack(spacing: 0) {
                    ForEach(tabs) { item in
                        if rename.tab == item.id {
                            TabNameField(rename: rename, item: item, metrics: metrics)
                        } else {
                            TabButton(item: item, metrics: metrics)
                                .onGeometryChange(for: CGRect.self) {
                                    $0.frame(in: .named(TabFrames.space))
                                } action: { [frames] in
                                    frames.tabs[item.id] = $0
                                }
                                .onDisappear { [frames] in frames.tabs[item.id] = nil }
                        }
                    }
                }
                .frame(maxHeight: .infinity)
            }
            .scrollIndicators(.never)
            .focusable(false)
            .onGeometryChange(for: CGRect.self) {
                $0.frame(in: .named(TabFrames.space))
            } action: { [frames] in
                frames.visible = $0
            }
            AddButton(button: addButton, metrics: metrics)
        }
        .padding(.trailing, metrics.points(4))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .font(Font(Fonts.ui(metrics.points(12), weight: .medium) as CTFont))
        .coordinateSpace(.named(TabFrames.space))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Tabs")
    }
}

// One tab: the name in the tab colour, at 70 % opacity unless the tab is active or under the
// pointer. The active tab has a line of 2 units in its colour under it. A press gives the cyan
// tint.
private struct TabButton: View {
    let item: TabItem
    let metrics: CanvasMetrics
    @State private var hovered = false

    var body: some View {
        let colour = ThemeTokens.tab(item.colour).color
        Button(action: item.activate) {
            Text(item.name)
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, metrics.points(8))
                .frame(maxHeight: .infinity)
        }
        .buttonStyle(PressTintStyle())
        .foregroundStyle(colour)
        .overlay(alignment: .bottom) {
            if item.active {
                Rectangle().fill(colour).frame(height: metrics.points(2))
            }
        }
        .opacity(item.active || hovered ? 1 : 0.7)
        .onHover { hovered = $0 }
        .simultaneousGesture(TapGesture(count: 2).onEnded { item.rename() })
        .focusable(false)
        .accessibilityAddTraits(item.active ? .isSelected : [])
        .accessibilityAction(named: "Rename") { item.rename() }
        .accessibilityAction(.showMenu) { item.showMenu() }
    }
}

// The name field of a rename, in place of the tab: the text in the tab colour on the background
// colour, with a line of 1 unit around it. The field takes the focus and selects its text. A name
// has at most 24 Characters (row OV6).
private struct TabNameField: View {
    @Bindable var rename: TabRename
    let item: TabItem
    let metrics: CanvasMetrics
    @FocusState private var focused: Bool

    var body: some View {
        let colour = ThemeTokens.tab(item.colour).color
        TextField("", text: $rename.draft)
            .textFieldStyle(.plain)
            .font(Font(Fonts.ui(metrics.points(12), weight: .regular) as CTFont))
            .foregroundStyle(colour)
            .focused($focused)
            .padding(.horizontal, metrics.points(4))
            .frame(width: metrics.points(128))
            .background(ThemeTokens.bg.color)
            .overlay { Rectangle().strokeBorder(colour, lineWidth: metrics.points(1)) }
            .frame(maxHeight: .infinity)
            .overlay(alignment: .bottom) {
                if item.active {
                    Rectangle().fill(colour).frame(height: metrics.points(2))
                }
            }
            .opacity(item.active ? 1 : 0.7)
            .onSubmit { rename.submit() }
            .onExitCommand { rename.cancel() }
            .onChange(of: focused) { old, new in
                if old && !new { rename.finish() }
            }
            .onChange(of: rename.draft) { _, new in
                if new.count > OverviewConfig.maxTabName {
                    rename.draft = String(new.prefix(OverviewConfig.maxTabName))
                }
            }
            .onAppear { focused = true }
            .accessibilityLabel("Tab name")
    }
}

// The Add tab button: the plus icon at 14 units in the dim text colour, the text colour under
// the pointer, and 40 % opacity while it is off. Its tooltip shows also while it is off.
private struct AddButton: View {
    let button: AddTabButton
    let metrics: CanvasMetrics
    @State private var hovered = false

    var body: some View {
        Button(action: button.action) {
            ButtonIcon(icon: .plus, size: metrics.points(14))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .buttonStyle(PressTintStyle())
        .disabled(!button.enabled)
        .foregroundStyle(
            (hovered && button.enabled ? ThemeTokens.text : ThemeTokens.textDim).color)
        .opacity(button.enabled ? 1 : 0.4)
        .frame(width: metrics.points(24))
        .frame(maxHeight: .infinity)
        .onHover { hovered = $0 }
        .focusable(false)
        .background(TipAnchor(text: button.tip, side: .top))
        .accessibilityLabel("Add tab")
    }
}

// The tab menu of one tab on the Bifrost menu: Rename..., the Filter and Columns submenus, Reset,
// Move left, Move right and Remove tab. A filter row and a column row are check rows: a
// choice changes the config and the menu stays open with the new checks. Reset is off for a tab
// with the default columns and filter, and Remove tab is off for the last tab, each with its
// reason as the tooltip. The rows come from the config of now at the open and after each change.
// Each choice first ends a rename that runs, with a save. Rename... shows the name field after
// the menu closed. Each other row that closes the menu gives the focus to the rows of the
// Overview, and so does the close of a menu where a check row changed the config. It is a
// context menu at each place: a press outside only closes it (BifrostMenu.OutsidePress).
// A row of the tab menu. The Bifrost menu gives back the text ID of a row, and init(id:) reads
// it at that edge, so the rest of the tab menu uses this type.
package enum TabMenuChoice: Hashable, Sendable {
    case rename, filter, columns, reset, moveLeft, moveRight, remove, boxOnly, watchedOnly
    case state(SessionState)
    case column(OverviewColumn)

    // The text ID of the row. A state has its place in TabFilter.allStates.
    package var id: String {
        switch self {
        case .rename: "rename"
        case .filter: "filter"
        case .columns: "columns"
        case .reset: "reset"
        case .moveLeft: "move-left"
        case .moveRight: "move-right"
        case .remove: "remove"
        case .boxOnly: "box-only"
        case .watchedOnly: "watched-only"
        case .state(let state): "state:\(TabFilter.allStates.firstIndex(of: state) ?? -1)"
        case .column(let column): "column:\(column.rawValue)"
        }
    }

    // The choice of a text ID, or nil for an ID that is not a row of the tab menu.
    package init?(id: String) {
        let fixed: [TabMenuChoice] = [
            .rename, .filter, .columns, .reset, .moveLeft, .moveRight, .remove, .boxOnly,
            .watchedOnly,
        ]
        if let choice = fixed.first(where: { $0.id == id }) {
            self = choice
        } else if id.hasPrefix("state:"), let index = Int(id.dropFirst("state:".count)),
            TabFilter.allStates.indices.contains(index)
        {
            self = .state(TabFilter.allStates[index])
        } else if id.hasPrefix("column:"),
            let column = OverviewColumn(rawValue: String(id.dropFirst("column:".count))),
            column != .kind
        {
            self = .column(column)
        } else {
            return nil
        }
    }
}

@MainActor
package enum OverviewTabMenu {
    // The columns of the Columns submenu: each column but kind, which is always on.
    private static let columns = OverviewColumn.allCases.filter { $0 != .kind }

    // The rows of the menu of the tab.
    package static func rows(_ config: OverviewConfig, tab: OverviewTab) -> [MenuRow] {
        let isDefault = !config.changes(.resetTab(tab.id))
        let only = config.tabs.count <= 1
        func spec(
            _ choice: TabMenuChoice, _ label: String, enabled: Bool = true, reason: String? = nil
        ) -> MenuItemSpec {
            MenuItemSpec(id: choice.id, label: label, enabled: enabled, reason: reason)
        }
        let states = TabFilter.allStates.map { state in
            MenuRow.check(
                spec(.state(state), OverviewFormat.stateLabel(state)),
                checked: tab.filter.states.contains(state))
        }
        let filter: [MenuRow] =
            states + [
                .separator,
                .check(spec(.boxOnly, "Only rows with a box"), checked: tab.filter.boxOnly),
                .check(
                    spec(.watchedOnly, "Only watched sessions"), checked: tab.filter.watchedOnly),
            ]
        let columns = Self.columns.map { column in
            MenuRow.check(
                spec(.column(column), column.label), checked: tab.columns.contains(column))
        }
        return [
            .item(spec(.rename, "Rename...")),
            .submenu(spec(.filter, "Filter"), rows: filter),
            .submenu(spec(.columns, "Columns"), rows: columns),
            .item(
                spec(
                    .reset, "Reset", enabled: !isDefault,
                    reason: isDefault ? OverviewRefusal.defaultTab.message : nil)),
            .item(spec(.moveLeft, "Move left")),
            .item(spec(.moveRight, "Move right")),
            .separator,
            .item(
                spec(
                    .remove, "Remove tab", enabled: !only,
                    reason: only ? OverviewRefusal.lastTab.message : nil)),
        ]
    }

    // Show the menu of the tab on the Bifrost menu of the Overviews (OverviewModel.menu). With no
    // menu, nothing shows.
    package static func show(
        model: OverviewModel, panel: PanelID, tab: String, rename: TabRename,
        at placement: BifrostMenu.Placement, in window: NSWindow
    ) {
        guard let menu = model.menu else { return }
        let rows = { () -> [MenuRow]? in
            let config = model.config(panel)
            return config.tabs.first { $0.id == tab }.map { Self.rows(config, tab: $0) }
        }
        guard let first = rows() else { return }
        // True after a check row changed the config. The rows get the focus at the close.
        let changed = ChangeMark()
        menu.show(
            first, width: nil, at: placement, in: window, outsidePress: .closesOnly,
            onChoose: { [weak menu] id in
                choose(id, model: model, panel: panel, tab: tab, rename: rename)
                // A check row keeps the menu open: it shows the new checks.
                guard let menu, menu.isOpen else { return }
                changed.on = true
                if let next = rows() { menu.update(next) }
            }, onField: { _, _ in },
            onClose: { if changed.on { rename.refocus() } })
    }

    // The action of the row with the ID on the tab. An ID that is not a row does nothing.
    package static func choose(
        _ id: String, model: OverviewModel, panel: PanelID, tab tabId: String, rename: TabRename
    ) {
        guard let choice = TabMenuChoice(id: id),
            let tab = model.config(panel).tabs.first(where: { $0.id == tabId })
        else { return }
        func update(_ action: OverviewAction) {
            rename.finish()
            model.update(panel, action)
            rename.refocus()
        }
        func edit(_ rule: (OverviewConfig) -> OverviewConfig) {
            rename.finish()
            model.edit(panel) { $0 = rule($0) }
        }
        switch choice {
        case .rename: rename.begin(tab)
        case .reset: update(.resetTab(tabId))
        case .moveLeft: update(.moveTab(tabId, by: -1))
        case .moveRight: update(.moveTab(tabId, by: 1))
        case .remove: update(.removeTab(tabId))
        case .boxOnly:
            edit { OverviewSettingsRules.setBoxOnly($0, tab: tabId, !tab.filter.boxOnly) }
        case .watchedOnly:
            edit { OverviewSettingsRules.setWatchedOnly($0, tab: tabId, !tab.filter.watchedOnly) }
        case .state(let state):
            let on = !tab.filter.states.contains(state)
            edit { OverviewSettingsRules.showState($0, tab: tabId, state, on) }
        case .column(let column):
            rename.finish()
            model.update(panel, .toggleColumn(tabId, column))
        // A submenu row opens its submenu and is no choice.
        case .filter, .columns: break
        }
    }
}

// A mark that a closure of the tab menu sets and another one reads.
@MainActor
private final class ChangeMark {
    var on = false
}

// The host of a tab bar. It never takes the first responder, and it is not in the Tab loop of the
// window. The name field of a rename is a text field in it, and takes the focus itself.
package final class OverviewTabsHost: PassiveHostingView<OverviewTabsView> {

    // A right-click on a tab opens its tab menu at the click point. A Control-click does the
    // same. The host never gives a system menu.
    override package func rightMouseDown(with event: NSEvent) {
        if !showTabMenu(event) { super.rightMouseDown(with: event) }
    }

    override package func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.control), showTabMenu(event) { return }
        super.mouseDown(with: event)
    }

    override package func menu(for event: NSEvent) -> NSMenu? { nil }

    // Show the tab menu of the tab under the event. False when no tab is there.
    @discardableResult
    package func showTabMenu(_ event: NSEvent) -> Bool {
        guard let window else { return false }
        var point = convert(event.locationInWindow, from: nil)
        if !isFlipped { point.y = bounds.height - point.y }
        guard let tab = rootView.frames.tab(at: point) else { return false }
        let view = rootView
        OverviewTabMenu.show(
            model: view.model, panel: view.panel, tab: tab, rename: view.rename,
            at: .point(window.convertPoint(toScreen: event.locationInWindow)), in: window)
        return true
    }
}

extension OverviewTabsView {
    // The host of the tab bar of the Overview panel. The panel sets its size.
    package static func host(
        model: OverviewModel, panel: PanelID, look: PanelLook
    ) -> OverviewTabsHost {
        let view = OverviewTabsView(model: model, panel: panel, look: look)
        let host = OverviewTabsHost(rootView: view)
        host.sizingOptions = []
        view.rename.host = host
        view.frames.host = host
        return host
    }
}
