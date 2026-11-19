// The SwiftUI part of the Selected Item panel (docs/behaviour/actions.md, "The Selected Item
// panel"): the data and the buttons of the selected session. From the top:
// 1. the name line: the row icon at 22, the name (its tooltip is aliasTip), the state label in
//    its tone, the priority in its colour (a row with no priority shows nothing), and the status
//    icon only when a text exists. The icon has the error, the notice and the line of the send
//    box in its tooltip. A click on the error icon closes the errors;
// 2. a button for each action of ActionModel.selectedItemActions(chatOpen:), then the watch
//    button: Add to watchlist (its colour menu) or Remove from watchlist;
// 3. the Project, Branch, Model (with its context bar) and Cost rows, with "-" for no value. The
//    panel shows no preview of the last reply;
// 4. the AppKit send box (SendBoxView), in the view as a representable.
// With no selected row, the panel says "No session selected.", with the notice line and the error
// line at the bottom. The content scrolls in a SwiftUI scroll view when the panel is lower than
// the content. Content that fits fills the panel and does not bounce.
//
// SelectedItemModel gives the content as values (SelectedItemContent) and runs the actions of the
// controls, so the tests read the values and call the actions: SwiftUI takes no synthetic click
// in a window that is never ordered front. The model reads the selected row by its ID from the
// session list at each change (SelectionModel.selectedRow), never a copy.
//
// No SwiftUI control of the view is focusable (the section "The UI" of the architecture design).
// Only the AppKit send box takes the focus.
import AppKit
import BifrostLook
import BifrostSessions
import Observation
import SwiftUI

// The priority of the name line, in its colour.
package struct PriorityMark: Equatable {
    package var text: String
    package var colour: TokenColour
}

// The status icon of the name line: its look, and the tooltip with all texts.
package struct StatusMark: Equatable {
    package var kind: StatusTexts.Kind
    package var text: String

    package var icon: IconName { kind == .error ? .circleAlert : .info }
    package var colour: TokenColour {
        kind == .error ? ThemeTokens.textStrong : ThemeTokens.textDim
    }
}

// One row of the facts: the label, the value ("-" for no value) and the tooltip of the value.
package struct FactRow: Identifiable, Equatable {
    package var label: String
    package var value: String
    package var tip: String?
    package var id: String { label }
}

// The context bar of the Model row: the fill from 0 to 100, its colour (the band of the shown
// percent, or the strong text colour with no band) and the text after it.
package struct ContextBar: Equatable {
    package var fill: Double
    package var colour: TokenColour
    package var text: String
}

package struct SelectedItemDetails: Equatable {
    package var sessionId: String
    package var icon: SessionIconLook
    package var name: String
    package var nameTip: String
    package var state: String
    package var stateColour: TokenColour
    package var priority: PriorityMark?
    package var status: StatusMark?
    package var buttons: [ActionButtonItem]
    // Project, Branch, Model and Cost.
    package var facts: [FactRow]
    package var context: ContextBar

    // The details of the row with the context of the runner now and the texts of the status
    // icon. appIcon is the icon of the app that shows the row, when the row has one.
    package static func of(
        _ row: SessionRow, _ ctx: ActionContext, status texts: StatusTexts, appIcon: AppIcon?,
        rowFlash: Bool
    ) -> SelectedItemDetails {
        let watch: ActionID = row.watch == nil ? .watchAdd : .watchRemove
        let actions = ActionModel.selectedItemActions(chatOpen: ctx.chatOpen) + [watch]
        let percent = row.usage?.contextPercent
        let shown = OverviewFormat.percent(percent)
        let tone = OverviewFormat.stateTone(row)
        return SelectedItemDetails(
            sessionId: row.sessionId,
            icon: SessionIconLook(row: row, appIcon: appIcon, rowFlash: rowFlash),
            name: row.name, nameTip: aliasTip(row), state: OverviewFormat.stateLabel(row.state),
            stateColour: CellContent("", .tone(tone)).textColour(parked: false),
            priority: row.priority.map {
                PriorityMark(text: "\($0.rawValue)", colour: ThemeTokens.priority($0.rawValue))
            },
            status: texts.kind.map { StatusMark(kind: $0, text: texts.text) },
            buttons: actions.compactMap { ActionButtonItem.of($0, row, ctx) },
            facts: [
                FactRow(
                    label: "Project", value: orDash(OverviewFormat.projectLabel(row.cwd)),
                    tip: row.cwd.isEmpty ? nil : row.cwd),
                FactRow(label: "Branch", value: orDash(row.branch)),
                FactRow(label: "Model", value: orDash(row.model), tip: row.model),
                FactRow(label: "Cost", value: orDash(OverviewFormat.cost(row.usage?.costUsd))),
            ],
            context: ContextBar(
                fill: OverviewFormat.barFill(percent),
                colour: bandColour(OverviewFormat.shownContextBand(percent)),
                text: shown.isEmpty ? "-" : "\(shown) context"))
    }

    // The fill colour of each band of the context bar, and the strong text colour with no band.
    package static func bandColour(_ band: ContextBand?) -> TokenColour {
        switch band {
        case .low: ThemeTokens.ctxLow
        case .mid: ThemeTokens.ctxMid
        case .high: ThemeTokens.ctxHigh
        case nil: ThemeTokens.textStrong
        }
    }

    // An empty value shows "-".
    private static func orDash(_ text: String?) -> String {
        guard let text, !text.isEmpty else { return "-" }
        return text
    }
}

package enum SelectedItemContent: Equatable {
    // No selected row: the notice and the error of the actions show as lines.
    case none(notice: String?, error: String?)
    case details(SelectedItemDetails)
}

@MainActor
@Observable
package final class SelectedItemModel {
    // The text of the panel with no selected row.
    package static let noSelection = "No session selected."

    @ObservationIgnored package let runner: ActionRunner
    @ObservationIgnored package let sendBox: SendBoxModel
    // The Overviews give the icon of the terminal app of an external row, the Row flash setting
    // and the Bifrost menu of the window.
    @ObservationIgnored package let overviews: OverviewModel
    @ObservationIgnored package let look: PanelLook

    package init(runner: ActionRunner, overviews: OverviewModel, look: PanelLook) {
        self.runner = runner
        self.overviews = overviews
        self.look = look
        sendBox = SendBoxModel(runner: runner)
    }

    package var selection: SelectionModel { runner.selection }

    // The content of now.
    package var content: SelectedItemContent {
        guard let row = selection.selectedRow else {
            return .none(notice: runner.notice, error: runner.error)
        }
        return .details(details(row))
    }

    private func details(_ row: SessionRow) -> SelectedItemDetails {
        let line = sendBox.line(row.sessionId)
        let texts = StatusTexts.of(
            error: runner.error, notice: runner.notice, sendLine: line?.text,
            sendFailed: line?.failed ?? false)
        return .of(
            row, runner.context(row.sessionId), status: texts,
            appIcon: overviews.appIcon(row), rowFlash: overviews.rowFlash)
    }

    // MARK: - The actions

    // A click on a button. Add to watchlist opens its colour menu below the button (anchor), with
    // the same watch of the row as the row menu (RowMenu.show): the menu follows the row of now,
    // and it closes when the row leaves the list or Add to watchlist turns off. A press outside
    // only closes it, and a choice runs on the row of now. Each other button runs its action on
    // the row of now.
    package func press(_ item: ActionButtonItem, sessionId: String, anchor: NSView?) {
        guard item.action == .watchAdd else {
            runner.run(item.action, sessionId)
            return
        }
        guard let anchor, let window = anchor.window, let menu = overviews.menu else { return }
        let rect = window.convertToScreen(anchor.convert(anchor.bounds, to: nil))
        RowMenu.show(
            sessionId, at: .below(rect, rightEdge: false), in: window, runner: runner,
            menu: menu, make: Self.watchMenu)
    }

    // The colour menu of Add to watchlist: the items of its submenu in the row menu, so the
    // colours and the labels are the same. nil while Add to watchlist is off.
    package func watchMenu(_ sessionId: String) -> RowMenu.Menu? {
        runner.row(sessionId).flatMap { Self.watchMenu($0, runner: runner) }
    }

    private static func watchMenu(_ row: SessionRow, runner: ActionRunner) -> RowMenu.Menu? {
        let menu = RowMenu.menu(row, runner: runner)
        let entry = menu.rows.first { $0.spec?.id == ActionID.watchAdd.rawValue }
        guard let rows = entry?.submenu else { return nil }
        return RowMenu.Menu(rows: rows, choices: menu.choices)
    }

    // A click on the error icon closes the error of the actions and the failed send.
    package func closeErrors() {
        runner.closeError()
        sendBox.clearFailure()
    }
}

// MARK: - The view

package struct SelectedItemView: View {
    let model: SelectedItemModel
    // The send box of the body. The body keeps it, so its focus and its follow stay while the
    // content changes.
    let sendBox: SendBoxView

    package init(model: SelectedItemModel, sendBox: SendBoxView) {
        self.model = model
        self.sendBox = sendBox
    }

    package var body: some View {
        let style = PanelStyle(look: model.look)
        GeometryReader { viewport in
            ScrollView(.vertical) {
                content(style)
                    .frame(
                        maxWidth: .infinity, minHeight: viewport.size.height,
                        alignment: .topLeading)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
    }

    @ViewBuilder
    private func content(_ style: PanelStyle) -> some View {
        Group {
            switch model.content {
            case .none(let notice, let error):
                NoSelectionView(
                    notice: notice, error: error, style: style, close: { model.closeErrors() })
            case .details(let details):
                DetailsView(details: details, style: style, model: model, sendBox: sendBox)
            }
        }
        .font(style.font(12))
        .foregroundStyle(ThemeTokens.text.color)
    }
}

private struct DetailsView: View {
    let details: SelectedItemDetails
    let style: PanelStyle
    let model: SelectedItemModel
    let sendBox: SendBoxView

    var body: some View {
        VStack(alignment: .leading, spacing: style.points(8)) {
            NameLine(details: details, style: style) { model.closeErrors() }
            HStack(spacing: style.points(4)) {
                ForEach(details.buttons) { item in
                    ActionButton(item: item, style: style) { item, anchor in
                        model.press(item, sessionId: details.sessionId, anchor: anchor)
                    }
                }
            }
            Facts(details: details, style: style)
            SendBoxSlot(box: sendBox, metrics: style.metrics)
                .frame(maxWidth: .infinity)
                .frame(height: SendBoxView.height(metrics: style.metrics))
        }
        .padding(style.points(12))
    }
}

// The AppKit send box in the view. The body makes the box one time and keeps it, so the slot
// gives that box to SwiftUI and gives it the metrics of the Interface scale.
private struct SendBoxSlot: NSViewRepresentable {
    let box: SendBoxView
    let metrics: CanvasMetrics

    func makeNSView(context: Context) -> SendBoxView {
        box.setMetrics(metrics)
        return box
    }

    func updateNSView(_ box: SendBoxView, context: Context) {
        if box.metrics != metrics { box.setMetrics(metrics) }
    }
}

private struct NameLine: View {
    let details: SelectedItemDetails
    let style: PanelStyle
    let closeErrors: () -> Void

    var body: some View {
        HStack(spacing: style.points(8)) {
            SessionIcon(look: details.icon, unit: style.points(1))
                .frame(width: style.points(22), height: style.points(22))
            Text(details.name)
                .font(style.font(13, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.tail)
                .background(TipAnchor(text: details.nameTip, side: .top))
            Text(details.state)
                .foregroundStyle(details.stateColour.color)
                .lineLimit(1)
                .fixedSize()
            if let priority = details.priority {
                Text(priority.text)
                    .foregroundStyle(priority.colour.color)
                    .fixedSize()
                    .background(TipAnchor(text: "Priority", side: .top))
            }
            if let status = details.status {
                StatusButton(status: status, style: style, closeErrors: closeErrors)
            }
            Spacer(minLength: 0)
        }
        .onChange(of: details.status?.text) { _, text in
            // A screen reader hears a new error, notice or line of the send box.
            guard let text, let app = NSApp else { return }
            NSAccessibility.post(
                element: app, notification: .announcementRequested,
                userInfo: [
                    .announcement: text,
                    .priority: NSAccessibilityPriorityLevel.medium.rawValue,
                ])
        }
    }
}

// The status icon: 16 units with an icon of 14. A click on the error icon closes the errors.
private struct StatusButton: View {
    let status: StatusMark
    let style: PanelStyle
    let closeErrors: () -> Void

    var body: some View {
        Button {
            if status.kind == .error { closeErrors() }
        } label: {
            Image(nsImage: Icons.image(status.icon))
                .renderingMode(.template)
                .resizable()
                .frame(width: style.points(14), height: style.points(14))
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
        .buttonStyle(
            IconButtonStyle(
                style: style, colour: status.colour.color, hoverColour: status.colour.color,
                hoverFill: ThemeTokens.hover.color, fills: true))
        .frame(width: style.points(16), height: style.points(16))
        .focusable(false)
        .focusEffectDisabled()
        .background(TipAnchor(text: status.text, side: .top))
        .accessibilityLabel(status.text)
    }
}

// Project, Branch, Model with its context bar, and Cost: the labels in the dim colour, 12 units
// between the columns.
private struct Facts: View {
    let details: SelectedItemDetails
    let style: PanelStyle

    var body: some View {
        Grid(
            alignment: .leading, horizontalSpacing: style.points(12),
            verticalSpacing: style.points(2)
        ) {
            ForEach(details.facts) { fact in
                GridRow {
                    Text(fact.label).foregroundStyle(style.dim)
                    if fact.label == "Model" {
                        ModelValue(fact: fact, context: details.context, style: style)
                    } else {
                        Value(fact: fact)
                    }
                }
            }
        }
    }
}

private struct Value: View {
    let fact: FactRow

    var body: some View {
        Text(fact.value)
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(fact.tip.map { TipAnchor(text: $0, side: .top) })
    }
}

// The model name keeps its width and is cut off only when the row is too narrow. The bar takes
// the free width, at least 32 units, and is empty with no percent.
private struct ModelValue: View {
    let fact: FactRow
    let context: ContextBar
    let style: PanelStyle

    var body: some View {
        HStack(spacing: style.points(8)) {
            Text(fact.value)
                .lineLimit(1)
                .truncationMode(.tail)
                .layoutPriority(1)
                .background(fact.tip.map { TipAnchor(text: $0, side: .top) })
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Rectangle().fill(style.edge)
                    Rectangle().fill(context.colour.color)
                        .frame(width: proxy.size.width * context.fill / 100)
                }
            }
            .frame(minWidth: style.points(32), maxWidth: .infinity)
            .frame(height: style.points(4))
            .background(TipAnchor(text: "Context", side: .top))
            .accessibilityHidden(true)
            Text(context.text)
                .lineLimit(1)
                .fixedSize()
                .background(TipAnchor(text: "Context", side: .top))
        }
    }
}

// The row icon of the Overview in the name line.
private struct SessionIcon: NSViewRepresentable {
    let look: SessionIconLook
    let unit: CGFloat

    func makeNSView(context: Context) -> SessionIconView {
        SessionIconView(frame: .zero)
    }

    func updateNSView(_ view: SessionIconView, context: Context) {
        view.show(look, unit: unit)
    }
}

// With no selected row: the text at the top, then the notice line and the error line at the
// bottom. Each line has a line of the panel edge colour on top, and its text wraps. The space
// between them fills the panel: the scroll view gives the content at least the height of the
// panel.
private struct NoSelectionView: View {
    let notice: String?
    let error: String?
    let style: PanelStyle
    let close: @MainActor () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(SelectedItemModel.noSelection)
                .font(style.font(13))
                .foregroundStyle(style.dim)
                .padding(style.points(12))
            Spacer(minLength: 0)
            lines
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var lines: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let notice {
                Text(notice)
                    .foregroundStyle(style.dim)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, style.points(8))
                    .overlay(alignment: .top) { edge }
            }
            if let error {
                ErrorLineView(text: error, metrics: style.metrics, close: close)
            }
        }
    }

    private var edge: some View {
        Rectangle().fill(style.edge).frame(height: style.points(1)).accessibilityHidden(true)
    }
}
