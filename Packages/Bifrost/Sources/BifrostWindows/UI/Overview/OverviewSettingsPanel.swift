// The Overview Settings panel (docs/behaviour/overview.md, Overview Settings): the body of
// overview-settings:<n>, which edits the tabs of overview:<n>. SwiftUI in one NSHostingView
// (OverviewSettingsPanels). From the top:
// - the Tab picker: the tab that the panel edits is the active tab of the Overview, so a choice
//   activates the tab and the Overview shows each change at once;
// - the Colour row: a radio group of the 12 tab colours (TabColourPicker);
// - the parts Columns and Filters;
// - Columns: a row with a check box for each column, in the tab order. A drag of a row moves the
//   column (ColumnDrop). The kind row is locked;
// - Filters: the groups States, Kinds, Boxes and Watchlist;
// - Reset to default, off for a tab with the default columns and filter. It stays below the part
//   that scrolls, so it always shows (row OV16).
// A closed Overview shows no rows, so the panel then shows only a text. A minimised Overview is
// open.
//
// Each change goes through OverviewModel: an action through update, and a filter rule of
// OverviewSettingsRules through edit. The controls of the panel are values with their actions, so
// the tests read them and call the actions. SwiftUI takes no synthetic click or drag in a window
// that is never ordered front.
//
// No SwiftUI control of the panel is focusable (the section "The UI" of the architecture design).
// The colour group is an AppKit control, so its arrow keys work.
import AppKit
import BifrostLayout
import BifrostLook
import BifrostSessions
import SwiftUI

// One choice of the Tab picker.
package struct TabChoice: Identifiable, Equatable {
    package let id: String
    package let name: String
    package let colour: Int
    // The tab that the panel edits: the active tab.
    package let chosen: Bool
}

// One switch of the Filters part.
package enum FilterSwitch: Hashable, Sendable {
    case state(SessionState)
    case kind(SessionKind)
    case boxOnly
    case watchedOnly
}

// One check box of the Filters part.
package struct FilterChoice: Identifiable, Equatable {
    package let filter: FilterSwitch
    package let label: String
    package let on: Bool
    package var id: FilterSwitch { filter }
}

// One group of the Filters part, with its title.
package struct FilterGroup: Identifiable, Equatable {
    package let title: String
    package let items: [FilterChoice]
    package var id: String { title }
}

// Reset to default: on or off, the text of its tooltip and its action.
@MainActor
package struct ResetButton {
    package let title: String
    package let enabled: Bool
    // The reason why the button is off, or nil.
    package let tip: String?
    package let action: () -> Void
}

package struct OverviewSettingsPanel: View {
    package static let closedText = "This Overview is closed."
    // The names of the tab colours, in the order of the index: the labels of the swatches.
    package static let colourNames = [
        "Cyan", "Light blue", "Green", "Teal", "Blue", "Mint", "Red", "Amber", "Yellow", "Lime",
        "White", "Sky blue",
    ]

    package let model: OverviewModel
    // The Overview that the panel edits.
    package let overview: PanelID
    private let look: PanelLook

    package init(model: OverviewModel, overview: PanelID, look: PanelLook) {
        self.model = model
        self.overview = overview
        self.look = look
    }

    // MARK: - The values and the actions

    package var isOpen: Bool { model.isOpen(overview) }
    private var config: OverviewConfig { model.config(overview) }
    // The tab that the panel edits: the active tab of the Overview.
    private var tab: OverviewTab { config.activeTab }

    package var tabChoices: [TabChoice] {
        let config = config
        return config.tabs.map {
            TabChoice(id: $0.id, name: $0.name, colour: $0.colour, chosen: $0.id == config.active)
        }
    }

    // A choice of the Tab picker activates the tab in the Overview.
    package func choose(tab id: String) {
        model.update(overview, .activate(id))
    }

    package func setColour(_ colour: Int) {
        model.update(overview, .setTabColour(tab.id, colour))
    }

    package var columnRows: [ColumnRow] {
        OverviewSettingsRules.columnRows(config, tab: tab.id)
    }

    // The tooltip of a column row: the reason of the locked kind row.
    package func tip(for row: ColumnRow) -> String? {
        row.locked ? OverviewRefusal.kindColumn.message : nil
    }

    // The check box of a column. The kind column stays on.
    package func setColumn(_ column: OverviewColumn, visible: Bool) {
        let tab = tab
        guard tab.columns.contains(column) != visible else { return }
        model.update(overview, .toggleColumn(tab.id, column))
    }

    // True when a release at the drop moves the column. Only then the list shows the drop line.
    package func moves(_ drop: ColumnDrop) -> Bool {
        guard let action = drop.action(tab: tab.id) else { return false }
        return config.changes(action)
    }

    package func release(_ drop: ColumnDrop) {
        guard let action = drop.action(tab: tab.id) else { return }
        model.update(overview, action)
    }

    package var filterGroups: [FilterGroup] {
        let filter = tab.filter
        let states = TabFilter.allStates.map {
            FilterChoice(
                filter: .state($0), label: OverviewFormat.stateLabel($0),
                on: filter.states.contains($0))
        }
        let kinds = TabFilter.allKinds.map {
            FilterChoice(
                filter: .kind($0), label: Self.kindLabel($0), on: filter.kinds.contains($0))
        }
        return [
            FilterGroup(title: "States", items: states),
            FilterGroup(title: "Kinds", items: kinds),
            FilterGroup(
                title: "Boxes",
                items: [
                    FilterChoice(
                        filter: .boxOnly, label: "Only rows with a box", on: filter.boxOnly)
                ]),
            FilterGroup(
                title: "Watchlist",
                items: [
                    FilterChoice(
                        filter: .watchedOnly, label: "Only watched sessions",
                        on: filter.watchedOnly)
                ]),
        ]
    }

    // A check box of the Filters part: the rule of OverviewSettingsRules, on the config of now.
    package func setFilter(_ filter: FilterSwitch, on: Bool) {
        let id = tab.id
        model.edit(overview) { config in
            switch filter {
            case .state(let state):
                config = OverviewSettingsRules.showState(config, tab: id, state, on)
            case .kind(let kind): config = OverviewSettingsRules.showKind(config, tab: id, kind, on)
            case .boxOnly: config = OverviewSettingsRules.setBoxOnly(config, tab: id, on)
            case .watchedOnly: config = OverviewSettingsRules.setWatchedOnly(config, tab: id, on)
            }
        }
    }

    package var reset: ResetButton {
        let id = tab.id
        let isDefault = !config.changes(.resetTab(id))
        let (model, overview) = (model, overview)
        return ResetButton(
            title: "Reset to default", enabled: !isDefault,
            tip: isDefault ? OverviewRefusal.defaultTab.message : nil,
            action: { model.update(overview, .resetTab(id)) })
    }

    private static func kindLabel(_ kind: SessionKind) -> String {
        switch kind {
        case .owned: "Owned"
        case .external: "External"
        }
    }

    // MARK: - The view

    package var body: some View {
        let metrics = look.metrics
        Group {
            if isOpen {
                SettingsContent(panel: self, metrics: metrics)
            } else {
                Text(Self.closedText)
                    .foregroundStyle(ThemeTokens.textDim.color)
                    .padding(metrics.points(12))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .font(Font(Fonts.ui(metrics.points(12), weight: .regular) as CTFont))
        .foregroundStyle(ThemeTokens.text.color)
        .focusable(false)
        .focusEffectDisabled()
    }
}

// The parts of the panel below the Tab picker.
private enum SettingsPage: CaseIterable {
    case columns, filters

    var label: String {
        switch self {
        case .columns: "Columns"
        case .filters: "Filters"
        }
    }
}

private struct SettingsContent: View {
    let panel: OverviewSettingsPanel
    let metrics: CanvasMetrics
    @State private var page = SettingsPage.columns

    var body: some View {
        let edge = ThemeTokens.panelEdge.color
        VStack(alignment: .leading, spacing: 0) {
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 0) {
                    TabPicker(panel: panel, metrics: metrics)
                        .padding(.horizontal, metrics.points(8))
                        .padding(.top, metrics.points(8))
                        .padding(.bottom, metrics.points(4))
                    ColourRow(panel: panel, metrics: metrics)
                        .padding(.horizontal, metrics.points(8))
                        .padding(.bottom, metrics.points(4))
                    pages(edge)
                    switch page {
                    case .columns: ColumnList(panel: panel, metrics: metrics)
                    case .filters: FilterList(panel: panel, metrics: metrics)
                    }
                }
            }
            .scrollIndicators(.automatic)
            .focusable(false)
            Rectangle().fill(edge).frame(height: metrics.points(1)).accessibilityHidden(true)
            HStack {
                Spacer()
                ResetView(button: panel.reset, metrics: metrics)
            }
            .padding(metrics.points(8))
        }
    }

    // The two parts as tabs, with a line of the panel edge colour under them.
    private func pages(_ edge: Color) -> some View {
        HStack(spacing: 0) {
            ForEach(SettingsPage.allCases, id: \.self) { item in
                PageTab(label: item.label, chosen: item == page, metrics: metrics) {
                    page = item
                }
            }
        }
        .padding(.horizontal, metrics.points(4))
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .bottom) {
            Rectangle().fill(edge).frame(height: metrics.points(1)).accessibilityHidden(true)
        }
    }
}

// One part tab: the strong text colour with a line of 2 units under it while it is chosen, else
// the dim text colour, and the text colour under the pointer.
private struct PageTab: View {
    let label: String
    let chosen: Bool
    let metrics: CanvasMetrics
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        let colour =
            chosen ? ThemeTokens.textStrong : hovered ? ThemeTokens.text : ThemeTokens.textDim
        Button(action: action) {
            Text(label)
                .padding(.horizontal, metrics.points(8))
                .padding(.vertical, metrics.points(4))
        }
        .buttonStyle(PressTintStyle())
        .foregroundStyle(colour.color)
        .overlay(alignment: .bottom) {
            if chosen {
                Rectangle().fill(ThemeTokens.textStrong.color).frame(height: metrics.points(2))
            }
        }
        .onHover { hovered = $0 }
        .focusable(false)
        .accessibilityAddTraits(chosen ? .isSelected : [])
    }
}

// The Tab picker: "Tab", then a box with the name of the tab in its colour and a down arrow. A
// click opens a native menu of the tabs, with a check mark at the tab that the panel edits.
private struct TabPicker: View {
    let panel: OverviewSettingsPanel
    let metrics: CanvasMetrics
    @State private var hovered = false

    var body: some View {
        let choices = panel.tabChoices
        let chosen = choices.first(where: \.chosen)
        let selection = Binding(
            get: { chosen?.id ?? "" }, set: { panel.choose(tab: $0) })
        HStack(spacing: metrics.points(8)) {
            Text("Tab").foregroundStyle(ThemeTokens.textDim.color)
            Menu {
                Picker("Tab", selection: selection) {
                    ForEach(choices) { Text($0.name).tag($0.id) }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            } label: {
                HStack(spacing: metrics.points(8)) {
                    Text(chosen?.name ?? "")
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .foregroundStyle(ThemeTokens.tab(chosen?.colour ?? 0).color)
                    Spacer(minLength: 0)
                    ButtonIcon(icon: .chevronDown, size: metrics.points(12))
                        .foregroundStyle(ThemeTokens.textDim.color)
                }
                .padding(.horizontal, metrics.points(8))
                .frame(maxWidth: .infinity)
                .frame(height: metrics.points(24))
                .background(ThemeTokens.bg.color)
                .overlay {
                    let edge = ThemeTokens.panelEdge.color
                    let strong = ThemeTokens.textStrong.color.opacity(0.3)
                    Rectangle().strokeBorder(hovered ? strong : edge, lineWidth: metrics.points(1))
                }
                .contentShape(Rectangle())
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .onHover { hovered = $0 }
            .focusable(false)
            .accessibilityLabel("Tab")
        }
    }
}

// The Colour row: "Colour", then the radio group of the tab colours.
private struct ColourRow: View {
    let panel: OverviewSettingsPanel
    let metrics: CanvasMetrics

    var body: some View {
        let colour = panel.tabChoices.first(where: \.chosen)?.colour ?? 0
        HStack(alignment: .top, spacing: metrics.points(8)) {
            Text("Colour")
                .foregroundStyle(ThemeTokens.textDim.color)
                .padding(.top, metrics.points(2))
            TabColourGroup(selected: colour, metrics: metrics) { panel.setColour($0) }
                .padding(.top, metrics.points(2))
        }
    }
}

// The column list. A drag of a row starts after the pointer moves 4 units, as a frame drag does
// before it can stack (Hit.stackDistance), so a click on a row changes only its box. The order
// changes on the release. A line shows the drop place while the release would move the column. A
// release more than 24 units outside the list moves nothing. The drop is the state of the drag
// gesture, so a cancelled drag clears it too.
private struct ColumnList: View {
    let panel: OverviewSettingsPanel
    let metrics: CanvasMetrics
    @GestureState private var drop: ColumnDrop?
    // The size of the rows, without the padding of the list.
    @State private var size = CGSize.zero
    private static let space = "overview-settings-columns"

    var body: some View {
        let rows = panel.columnRows
        let order = rows.map(\.column)
        let moves = drop.map(panel.moves) ?? false
        VStack(alignment: .leading, spacing: 0) {
            ForEach(rows, id: \.column) { row in
                ColumnRowView(
                    row: row, tip: panel.tip(for: row), metrics: metrics,
                    dragged: drop?.column == row.column,
                    line: moves ? line(for: row.column, drop: drop, last: order.last) : nil
                ) { panel.setColumn(row.column, visible: $0) }
                // The drag comes before the click of the check box: a press that moves 4 units
                // is a drag, and then its release does not change the box. The kind row has no
                // drag.
                .highPriorityGesture(
                    drag(row.column, order: order), including: row.locked ? .subviews : .all)
            }
        }
        .coordinateSpace(.named(Self.space))
        .onGeometryChange(for: CGSize.self, of: \.size) { size = $0 }
        .padding(.vertical, metrics.points(ColumnDrop.listPadding))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Columns")
    }

    // The drop line of a row: above the row that the drop goes before, or below the last row.
    private func line(
        for column: OverviewColumn, drop: ColumnDrop?, last: OverviewColumn?
    ) -> VerticalEdge? {
        guard let drop else { return nil }
        if drop.before == column { return .top }
        return drop.before == nil && column == last ? .bottom : nil
    }

    private func drag(_ column: OverviewColumn, order: [OverviewColumn]) -> some Gesture {
        DragGesture(
            minimumDistance: metrics.points(Hit.stackDistance), coordinateSpace: .named(Self.space))
            .updating($drop) { value, drop, _ in
                let next = place(column, value.location, order)
                if next != drop { drop = next }
            }
            .onEnded { value in
                if let end = place(column, value.location, order) { panel.release(end) }
            }
    }

    // The drop of the column at a point of the rows, in layout units.
    private func place(
        _ column: OverviewColumn, _ point: CGPoint, _ order: [OverviewColumn]
    ) -> ColumnDrop? {
        let scale = metrics.scale
        return ColumnDrop(
            column: column, at: LayoutPoint(x: point.x / scale, y: point.y / scale),
            rows: LayoutSize(w: size.width / scale, h: size.height / scale), order: order)
    }
}

// One row of the column list: the check box with the label, then the drag handle. The kind row
// has no handle, its box is off, and its tooltip gives the reason. A dragged row is at 40 %
// opacity.
private struct ColumnRowView: View {
    let row: ColumnRow
    let tip: String?
    let metrics: CanvasMetrics
    let dragged: Bool
    let line: VerticalEdge?
    let set: @MainActor (Bool) -> Void
    @State private var hovered = false

    var body: some View {
        HStack(spacing: metrics.points(8)) {
            // The closure literal is necessary: Swift 6.3.3 stops with an error in the IR
            // generation when the stored main-actor closure goes directly to Binding(set:).
            Toggle(row.label, isOn: Binding(get: { row.visible }, set: { set($0) }))
                .toggleStyle(BifrostCheckboxStyle(metrics: metrics))
                .disabled(row.locked)
            if !row.locked {
                ButtonIcon(icon: .gripVertical, size: metrics.points(12))
                    .foregroundStyle(ThemeTokens.textDim.color)
                    .pointerStyle(.grabIdle)
            }
        }
        .padding(.horizontal, metrics.points(8))
        .frame(height: metrics.points(ColumnDrop.rowHeight))
        .background(hovered && !row.locked ? ThemeTokens.hover.color : .clear)
        .opacity(dragged ? 0.4 : 1)
        .overlay(alignment: line == .bottom ? .bottom : .top) {
            if line != nil {
                Rectangle().fill(ThemeTokens.textStrong.color)
                    .frame(height: metrics.points(1))
                    .padding(.horizontal, metrics.points(4))
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
        .background { if let tip { TipAnchor(text: tip, side: .top) } }
    }
}

// The Filters part: a group for the states, the kinds, the boxes and the watchlist.
private struct FilterList: View {
    let panel: OverviewSettingsPanel
    let metrics: CanvasMetrics

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(panel.filterGroups) { group in
                VStack(alignment: .leading, spacing: 0) {
                    Text(group.title)
                        .font(Font(Fonts.ui(metrics.points(11), weight: .regular) as CTFont))
                        .foregroundStyle(ThemeTokens.textDim.color)
                        .padding(.horizontal, metrics.points(8))
                        .padding(.bottom, metrics.points(2))
                        .accessibilityAddTraits(.isHeader)
                    ForEach(group.items) { item in
                        FilterRow(item: item, metrics: metrics) {
                            panel.setFilter(item.filter, on: $0)
                        }
                    }
                }
                .padding(.vertical, metrics.points(4))
            }
        }
        .padding(.vertical, metrics.points(4))
    }
}

private struct FilterRow: View {
    let item: FilterChoice
    let metrics: CanvasMetrics
    let set: @MainActor (Bool) -> Void
    @State private var hovered = false

    var body: some View {
        // The closure literal is necessary: Swift 6.3.3 stops with an error in the IR generation
        // when the stored main-actor closure goes directly to Binding(set:).
        Toggle(item.label, isOn: Binding(get: { item.on }, set: { set($0) }))
            .toggleStyle(BifrostCheckboxStyle(metrics: metrics))
            .padding(.horizontal, metrics.points(8))
            .frame(height: metrics.points(22))
            .background(hovered ? ThemeTokens.hover.color : .clear)
            .onHover { hovered = $0 }
    }
}

// Reset to default: a box of the panel edge colour, the hover colour under the pointer, and 40 %
// opacity while it is off. Its tooltip shows also while it is off.
private struct ResetView: View {
    let button: ResetButton
    let metrics: CanvasMetrics
    @State private var hovered = false

    var body: some View {
        Button(action: button.action) {
            Text(button.title)
                .padding(.horizontal, metrics.points(8))
                .padding(.vertical, metrics.points(2))
                .background(hovered && button.enabled ? ThemeTokens.hover.color : .clear)
                .overlay {
                    Rectangle().strokeBorder(
                        ThemeTokens.panelEdge.color, lineWidth: metrics.points(1))
                }
        }
        .buttonStyle(PressTintStyle())
        .disabled(!button.enabled)
        .opacity(button.enabled ? 1 : 0.4)
        .onHover { hovered = $0 }
        .focusable(false)
        .background { if let tip = button.tip { TipAnchor(text: tip, side: .top) } }
    }
}
