// The SwiftUI popup of one level of a Bifrost menu (docs/behaviour/menu.md, "The look"): the
// title colour with a border of the panel edge colour, a space above and below the rows, and the
// rows of MenuRowViews.swift. BifrostMenu sets the state, and the view follows it through
// Observation.
import BifrostLayout
import BifrostLook
import Observation
import SwiftUI

private typealias M = ThemeTokens.Menu

// What one level of the menu shows: the rows, the highlighted row, the pressed row, the row of
// the open submenu and the focus of a field box. The indexes are in the rows of this level.
@MainActor
@Observable
final class MenuLevelState {
    var rows: [MenuRow]
    var metrics: CanvasMetrics
    var highlighted: Int?
    var pressed: Int?
    var openRow: Int?
    var fieldFocused = false

    init(rows: [MenuRow], metrics: CanvasMetrics) {
        self.rows = rows
        self.metrics = metrics
    }
}

struct MenuView: View {
    let state: MenuLevelState

    var body: some View {
        let metrics = state.metrics
        VStack(spacing: 0) {
            ForEach(Array(state.rows.enumerated()), id: \.offset) { index, row in
                rowView(row, index: index, metrics: metrics)
            }
        }
        .padding(.vertical, metrics.points(M.paddingY))
        .padding(metrics.points(M.border))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(ThemeTokens.title.color)
        .overlay(
            Rectangle().strokeBorder(
                ThemeTokens.panelEdge.color, lineWidth: metrics.points(M.border))
        )
        // The views over the rows give the accessibility of the menu (MenuPanel.swift), so a hit
        // test of VoiceOver reaches only them.
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private func rowView(_ row: MenuRow, index: Int, metrics: CanvasMetrics) -> some View {
        switch row {
        case .separator:
            MenuSeparatorView(metrics: metrics)
        case .field(_, let label, _, _):
            MenuFieldRowView(label: label, metrics: metrics, focused: state.fieldFocused)
        case .item(let spec), .checkbox(let spec, _), .check(let spec, _), .radio(let spec, _),
            .submenu(let spec, _):
            MenuItemRowView(
                row: row, spec: spec, metrics: metrics, highlighted: state.highlighted == index,
                pressed: state.pressed == index, open: state.openRow == index)
        }
    }
}
