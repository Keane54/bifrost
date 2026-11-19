// The SwiftUI rows of a Bifrost menu (docs/behaviour/menu.md, "The look"): an item row, a
// separator and a field row, in the values of ThemeTokens.Menu. The rows only draw. The AppKit
// views of MenuPanel.swift over them take the pointer, give the accessibility of the rows and
// hold the text field of a field row.
import BifrostLayout
import BifrostLook
import SwiftUI

private typealias M = ThemeTokens.Menu

// The UI font at the text size of the menu.
@MainActor
func menuFont(_ metrics: CanvasMetrics) -> Font {
    Font(Fonts.ui(metrics.points(M.textSize), weight: .regular) as CTFont)
}

// An item, a check box, a check, a radio or a submenu row: the square of a check box row (empty
// while it is off), the check column of a check or a radio row, the colour square, the label, and
// the arrow of a submenu row. The fill shows the press, the highlight, or an open submenu while
// the highlight is inside it. A disabled row is faded.
struct MenuItemRowView: View {
    let row: MenuRow
    let spec: MenuItemSpec
    let metrics: CanvasMetrics
    let highlighted: Bool
    let pressed: Bool
    let open: Bool

    var body: some View {
        let isSubmenu = if case .submenu = row { true } else { false }
        HStack(spacing: metrics.points(M.rowGap)) {
            if case .checkbox(_, let on) = row {
                CheckSquare(on: on, metrics: metrics)
            } else if let checked {
                ZStack {
                    if checked { icon(.check, size: M.checkSize) }
                }
                .frame(width: metrics.points(M.checkColumn))
            }
            if spec.hasSwatchColumn {
                let side = metrics.points(M.swatchSize)
                Rectangle()
                    .fill(spec.swatch?.color ?? .clear)
                    .frame(width: side, height: side)
            }
            // The label takes the free width. A spacer would add one more gap, and the width of
            // the menu counts only one gap between two parts, so the widest label would not fit.
            Text(spec.label)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            if isSubmenu { icon(.chevronRight, size: M.chevronSize) }
        }
        .font(menuFont(metrics))
        .foregroundStyle(ThemeTokens.text.color)
        .padding(.leading, metrics.points(M.rowPaddingX))
        .padding(.trailing, metrics.points(isSubmenu ? M.submenuPaddingRight : M.rowPaddingX))
        .frame(maxWidth: .infinity, minHeight: height, maxHeight: height)
        .background(fill)
        .opacity(spec.enabled ? 1 : M.disabledOpacity)
    }

    private var height: CGFloat { metrics.points(M.rowHeight) }

    // The check state of a check or a radio row, or nil for a row with no check column.
    private var checked: Bool? {
        switch row {
        case .check(_, let checked), .radio(_, let checked): checked
        default: nil
        }
    }

    // A press of an enabled row tints it. A pressed row is always the highlighted row.
    private var fill: Color {
        if pressed && spec.enabled { return ThemeTokens.accent.opacity(0.12).color }
        if highlighted { return M.highlight.color }
        if open { return ThemeTokens.hover.color }
        return .clear
    }

    private func icon(_ name: IconName, size: Double) -> some View {
        Image(nsImage: Icons.image(name))
            .renderingMode(.template)
            .resizable()
            .frame(width: metrics.points(size), height: metrics.points(size))
    }
}

// A line between two groups of rows.
struct MenuSeparatorView: View {
    let metrics: CanvasMetrics

    var body: some View {
        Rectangle()
            .fill(ThemeTokens.panelEdge.color)
            .frame(height: metrics.points(M.separatorHeight))
            .padding(.vertical, metrics.points(M.separatorMargin))
    }
}

// A field row: the label above a box of the background colour with a border. The text field of
// the row (MenuTextField) lies in the box. The border is lighter while the box has the focus.
struct MenuFieldRowView: View {
    let label: String
    let metrics: CanvasMetrics
    let focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: metrics.points(M.fieldGap)) {
            Text(label)
                .lineLimit(1)
                .frame(height: metrics.points(M.lineHeight))
            Rectangle()
                .fill(ThemeTokens.bg.color)
                .overlay(
                    Rectangle().strokeBorder(
                        (focused ? M.fieldFocusBorder : ThemeTokens.panelEdge).color,
                        lineWidth: metrics.points(M.border))
                )
                .frame(height: metrics.points(M.fieldBoxHeight))
        }
        .font(menuFont(metrics))
        .foregroundStyle(ThemeTokens.text.color)
        .padding(.horizontal, metrics.points(M.fieldPaddingX))
        .padding(.vertical, metrics.points(M.fieldPaddingY))
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
