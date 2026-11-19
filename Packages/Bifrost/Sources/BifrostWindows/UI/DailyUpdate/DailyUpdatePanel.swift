// The view of the Daily update panel (docs/behaviour/daily-update.md, "The panel"; the model is
// DailyUpdatePanelModel). From the top:
// - The status line: the state, Refresh and Skip today (Undo after a skip), then the deadline,
//   the time of the last refresh and the count of the items that fit no area. A click on the
//   count shows those items.
// - The reason of a failed run.
// - One tab for each area that is on. A tab that is not sent has a marker.
// - The shown tab: the items that moved (a click opens an https link), the offer of a new draft
//   beside a changed one, the draft editor (DraftEditor), and Redo draft, Copy, Mark as sent
//   ("Sent at 09:31" with Undo after it) and Send, which is off with its tip.
// With no area on, the panel has a short text and a button to Settings > Daily update. With no
// service, it says why.
import AppKit
import BifrostDailyUpdate
import BifrostLook
import SwiftUI

package struct DailyUpdatePanel: View {
    let model: DailyUpdatePanelModel

    package init(model: DailyUpdatePanelModel) {
        self.model = model
    }

    package var body: some View {
        let style = model.style
        Group {
            switch model.shown {
            case .starting:
                Color.clear
            case .unavailable(let text):
                Text(text)
                    .foregroundStyle(style.dim)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(style.points(12))
            case .noArea:
                VStack(alignment: .leading, spacing: style.points(8)) {
                    Text(DailyUpdatePanelModel.setUpText).foregroundStyle(style.dim)
                    Button(DailyUpdatePanelModel.openSettingsButton) { model.openSettings() }
                        .buttonStyle(DialogButtonStyle(style: style))
                }
                .padding(style.points(12))
            case .tabs:
                if let snapshot = model.snapshot {
                    DailyContent(model: model, snapshot: snapshot, style: style)
                }
            }
        }
        .font(style.font)
        .foregroundStyle(ThemeTokens.text.color)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .focusEffectDisabled()
    }
}

// The panel with its tabs.
private struct DailyContent: View {
    let model: DailyUpdatePanelModel
    let snapshot: DailySnapshot
    let style: PanelStyle

    var body: some View {
        VStack(spacing: 0) {
            StatusLine(model: model, snapshot: snapshot, style: style)
            edge
            if model.showsUnplaced, !snapshot.unplaced.isEmpty {
                ItemList(model: model, items: snapshot.unplaced, style: style)
                    .padding(.horizontal, style.points(4))
                    .padding(.vertical, style.points(4))
                edge
            }
            if let failure = snapshot.failure {
                Text(failure.text)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, style.points(8))
                    .padding(.vertical, style.points(4))
                edge
            }
            TabBar(model: model, snapshot: snapshot, style: style)
            edge
            if let tab = model.shownTab {
                AreaTab(model: model, tab: tab, style: style)
                    .id(tab.id)
            }
            if let error = model.error {
                ErrorLineView(text: error, metrics: style.metrics) { model.closeError() }
            }
        }
    }

    private var edge: some View {
        Rectangle().fill(style.edge).frame(height: style.points(1)).accessibilityHidden(true)
    }
}

// The state, the buttons that act on the day, and the details of the day.
private struct StatusLine: View {
    let model: DailyUpdatePanelModel
    let snapshot: DailySnapshot
    let style: PanelStyle

    var body: some View {
        let details = [model.dueText, model.refreshText].compactMap { $0 }
        VStack(alignment: .leading, spacing: style.points(2)) {
            HStack(spacing: style.points(8)) {
                Text(model.statusText)
                    .foregroundStyle(ThemeTokens.textStrong.color)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Button("Refresh") { model.refresh() }
                    .buttonStyle(DialogButtonStyle(style: style))
                    .disabled(!model.canRefresh)
                switch model.skipAction {
                case .skip:
                    Button("Skip today") { model.skipToday() }
                        .buttonStyle(DialogButtonStyle(style: style))
                case .undo:
                    Button("Undo") { model.undoSkip() }
                        .buttonStyle(DialogButtonStyle(style: style))
                case nil:
                    EmptyView()
                }
            }
            if !details.isEmpty || model.unplacedText != nil {
                HStack(spacing: style.points(12)) {
                    ForEach(details, id: \.self) { Text($0).foregroundStyle(style.dim) }
                    if let unplaced = model.unplacedText {
                        Button(unplaced) { model.toggleUnplaced() }
                            .buttonStyle(PressTintStyle())
                            .underline()
                    }
                    Spacer(minLength: 0)
                }
                .lineLimit(1)
            }
        }
        .padding(.horizontal, style.points(8))
        .padding(.vertical, style.points(4))
    }
}

// One tab for each area that is on, with the marker of a tab that is not sent.
private struct TabBar: View {
    let model: DailyUpdatePanelModel
    let snapshot: DailySnapshot
    let style: PanelStyle

    var body: some View {
        let shown = model.shownTab?.id
        ScrollView(.horizontal) {
            HStack(spacing: 0) {
                ForEach(snapshot.tabs) { tab in
                    let marker = model.marker(tab)
                    Button {
                        model.choose(tab.id)
                    } label: {
                        HStack(spacing: style.points(6)) {
                            Text(tab.name).lineLimit(1)
                            if marker {
                                Rectangle().fill(ThemeTokens.textStrong.color)
                                    .frame(width: style.points(6), height: style.points(6))
                                    .accessibilityHidden(true)
                            }
                        }
                    }
                    .buttonStyle(StackTabStyle(style: style, active: tab.id == shown))
                }
            }
        }
        .scrollIndicators(.never)
        .frame(height: style.points(22))
    }
}

// The shown tab: the items, the offer of a new draft, the editor and the buttons.
private struct AreaTab: View {
    let model: DailyUpdatePanelModel
    let tab: DailySnapshot.Tab
    let style: PanelStyle

    var body: some View {
        VStack(alignment: .leading, spacing: style.points(8)) {
            if tab.hasDraft {
                Text(model.movedHeader(tab)).foregroundStyle(style.dim)
                if tab.items.isEmpty {
                    Text(DailyUpdatePanelModel.nothingMoved)
                } else {
                    ItemList(model: model, items: tab.items, style: style)
                }
                if tab.pending != nil {
                    HStack(spacing: style.points(8)) {
                        Text(DailyUpdatePanelModel.newDraft)
                            .foregroundStyle(ThemeTokens.textStrong.color)
                        Button("Use new draft") { model.usePending(tab.id) }
                            .buttonStyle(DialogButtonStyle(style: style))
                        Button("Keep mine") { model.keepMine(tab.id) }
                            .buttonStyle(DialogButtonStyle(style: style))
                    }
                }
                DraftEditor(
                    draft: tab.draft, font: style.nsFont,
                    boldFont: Fonts.ui(style.points(12), weight: .semibold)
                ) { model.edit(tab.id, $0) }
                .frame(maxWidth: .infinity, minHeight: style.points(120), maxHeight: .infinity)
                .background(ThemeTokens.bg.color)
                .overlay {
                    Rectangle().strokeBorder(style.edge, lineWidth: style.points(1))
                        .accessibilityHidden(true)
                }
            } else {
                Text(DailyUpdatePanelModel.noDraft).foregroundStyle(style.dim)
                Spacer(minLength: 0)
            }
            buttons
        }
        .padding(style.points(8))
    }

    private var buttons: some View {
        let state = model.buttons(tab)
        return HStack(spacing: style.points(6)) {
            Button("Redo draft") { Task { await model.redo(tab.id) } }
                .buttonStyle(DialogButtonStyle(style: style))
                .disabled(!state.redo)
            Button(state.copyLabel) { model.copy(tab.id) }
                .buttonStyle(DialogButtonStyle(style: style))
                .disabled(!state.copy)
            if let sent = state.sent {
                Text(sent)
                Button("Undo") { model.undoSent(tab.id) }
                    .buttonStyle(DialogButtonStyle(style: style))
            } else {
                Button("Mark as sent") { model.markSent(tab.id) }
                    .buttonStyle(DialogButtonStyle(style: style))
                    .disabled(!state.markSent)
            }
            Button(state.sendLabel) {}
                .buttonStyle(DialogButtonStyle(style: style))
                .disabled(!state.send)
                .background(TipAnchor(text: state.sendTip, side: .top))
            Spacer(minLength: 0)
        }
    }
}

// The tickets and the PRs: the ID, the title and the change of state. An item with an https link
// is a button that opens it. The list scrolls when it is long.
private struct ItemList: View {
    let model: DailyUpdatePanelModel
    let items: [DailyItem]
    let style: PanelStyle

    var body: some View {
        let rowHeight = style.points(18)
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    row(item).frame(height: rowHeight)
                }
            }
        }
        .frame(height: min(rowHeight * CGFloat(items.count), style.points(144)))
    }

    @ViewBuilder
    private func row(_ item: DailyItem) -> some View {
        let parts = HStack(spacing: style.points(8)) {
            Text(item.id).foregroundStyle(style.dim).fixedSize()
            Text(item.title).lineLimit(1).truncationMode(.tail)
            Spacer(minLength: 0)
            if let change = DailyUpdatePanelModel.change(of: item) {
                Text(change).foregroundStyle(style.dim).fixedSize()
            }
        }
        .padding(.horizontal, style.points(4))
        if DailyUpdatePanelModel.link(of: item) != nil {
            Button { model.open(item) } label: { parts }
                .buttonStyle(LinkRowStyle(style: style))
        } else {
            parts
        }
    }
}

// A row that acts as a button: the panel colour under the pointer, the cyan tint during a press.
private struct LinkRowStyle: ButtonStyle {
    let style: PanelStyle

    func makeBody(configuration: Configuration) -> some View {
        Row(configuration: configuration, style: style)
    }

    private struct Row: View {
        let configuration: Configuration
        let style: PanelStyle
        @State private var hovered = false

        var body: some View {
            configuration.label
                .frame(maxHeight: .infinity)
                .background(
                    configuration.isPressed ? style.press : hovered ? style.hover : .clear
                )
                .contentShape(Rectangle())
                .onHover { hovered = $0 }
        }
    }
}
