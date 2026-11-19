// The Reviews panel (docs/behaviour/reviews.md, "The panel"): the To review tab and the My PRs
// tab, each with its count, the rows of the tab, Refresh and "Last checked <time>", the Trust
// needed strip (TrustStrip), the line of gh when a poll fails, and the hint of the automatic
// comment handling. SwiftUI in one NSHostingView (ReviewsPanels). The model (ReviewsPanelModel)
// gives each text and each state, so the view only lays them out. The rows are not focusable, and
// the panel never takes the focus.
import AppKit
import BifrostFoundation
import BifrostLook
import BifrostReviews
import SwiftUI

package struct ReviewsPanel: View {
    package let model: ReviewsPanelModel
    // The frames of the rows, for the row menu and Cmd+click (ReviewsHost).
    package let frames = ReviewRowFrames()

    package init(model: ReviewsPanelModel) {
        self.model = model
    }

    package var body: some View {
        let metrics = model.metrics
        VStack(alignment: .leading, spacing: 0) {
            if model.showsTabs { ReviewsTabBar(model: model, metrics: metrics) }
            if !model.trustRows.isEmpty { TrustStrip(model: model, metrics: metrics) }
            if model.showsHint { hint(metrics) }
            content(metrics)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            // The gh line stays until a poll works, so it has no close button.
            if let line = model.ghLine { ErrorLineView(text: line, metrics: metrics, close: nil) }
            if let error = model.error {
                ErrorLineView(text: error, metrics: metrics) { model.closeError() }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .font(model.style.font)
        .foregroundStyle(ThemeTokens.text.color)
        .coordinateSpace(.named(ReviewRowFrames.space))
        .focusable(false)
        .focusEffectDisabled()
    }

    @ViewBuilder
    private func content(_ metrics: CanvasMetrics) -> some View {
        switch model.body {
        case .off:
            VStack(alignment: .leading, spacing: metrics.points(8)) {
                notice(ReviewsPanelModel.offText, metrics)
                OpenSettingsButton(label: ReviewsPanelModel.openSettingsText, style: model.style) {
                    model.openSettings()
                }
            }
            .padding(.horizontal, metrics.points(12))
            .padding(.vertical, metrics.points(8))
        case .starting:
            padded(notice(ReviewsPanelModel.checkingText, metrics), metrics)
        case .notice(let text):
            padded(notice(text, metrics), metrics)
        case .failed:
            Color.clear
        case .empty:
            padded(notice(ReviewsPanelModel.emptyText, metrics), metrics)
        case .rows:
            rowList(metrics)
        }
    }

    private func rowList(_ metrics: CanvasMetrics) -> some View {
        let frames = frames
        let rows = model.rows(model.tab)
        let rowFlash = model.snapshot.rowFlash
        return ScrollView(.vertical) {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                    ReviewRowView(
                        model: model, row: row, first: index == 0, rowFlash: rowFlash,
                        style: model.style)
                        .onGeometryChange(for: CGRect.self) {
                            $0.frame(in: .named(ReviewRowFrames.space))
                        } action: {
                            frames.rows[row.id] = $0
                        }
                        .onDisappear { frames.rows[row.id] = nil }
                }
            }
        }
        .scrollIndicators(.automatic)
        .focusable(false)
        .onGeometryChange(for: CGRect.self) {
            $0.frame(in: .named(ReviewRowFrames.space))
        } action: {
            frames.visible = $0
        }
        .onDisappear { frames.visible = .zero }
    }

    // The hint of the automatic comment handling, with Open Settings.
    private func hint(_ metrics: CanvasMetrics) -> some View {
        HStack(alignment: .top, spacing: metrics.points(8)) {
            Text(ReviewsPanelModel.autoFixHint)
                .foregroundStyle(ThemeTokens.textDim.color)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            OpenSettingsButton(label: ReviewsPanelModel.openSettingsText, style: model.style) {
                model.openSettings()
            }
        }
        .padding(.horizontal, metrics.points(12))
        .padding(.vertical, metrics.points(8))
        .overlay(alignment: .bottom) { EdgeLineView(metrics: metrics) }
    }

    private func notice(_ text: String, _ metrics: CanvasMetrics) -> some View {
        Text(text)
            .foregroundStyle(ThemeTokens.textDim.color)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func padded(_ view: some View, _ metrics: CanvasMetrics) -> some View {
        view
            .padding(.horizontal, metrics.points(12))
            .padding(.vertical, metrics.points(8))
    }
}

// The tab bar: the two tabs with their counts, then "Last checked <time>" and Refresh at the
// right. The open tab has the strong text colour and a line of 2 units under it. The count of a
// tab is red while the tab is hot.
private struct ReviewsTabBar: View {
    let model: ReviewsPanelModel
    let metrics: CanvasMetrics

    var body: some View {
        HStack(spacing: 0) {
            ForEach([ReviewsTab.toReview, .mine], id: \.self) { tab in
                TabButton(
                    title: Self.title(tab), count: model.count(tab), hot: model.isHot(tab),
                    active: model.tab == tab, metrics: metrics
                ) { model.tab = tab }
            }
            Spacer(minLength: metrics.points(8))
            if let text = model.lastChecked {
                Text(text)
                    .font(model.style.font(11))
                    .foregroundStyle(ThemeTokens.textDim.color)
                    .lineLimit(1)
                    .padding(.trailing, metrics.points(4))
            }
            RefreshButton(style: model.style) { model.refresh() }
                .padding(.trailing, metrics.points(4))
        }
        .frame(height: metrics.points(22))
        .overlay(alignment: .bottom) { EdgeLineView(metrics: metrics) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Tabs")
    }

    static func title(_ tab: ReviewsTab) -> String {
        switch tab {
        case .toReview: "To review"
        case .mine: "My PRs"
        }
    }
}

private struct TabButton: View {
    let title: String
    let count: Int
    let hot: Bool
    let active: Bool
    let metrics: CanvasMetrics
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: metrics.points(4)) {
                Text(title)
                Text(String(count))
                    .foregroundStyle(hot ? ThemeTokens.boxRed.color : colour)
            }
            .lineLimit(1)
            .padding(.horizontal, metrics.points(8))
            .frame(maxHeight: .infinity)
            .foregroundStyle(colour)
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(active ? ThemeTokens.textStrong.color : .clear)
                    .frame(height: metrics.points(2))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(PressTintStyle())
        .focusable(false)
        .onHover { hovered = $0 }
        .accessibilityLabel("\(title), \(count)")
        .accessibilityAddTraits(active ? .isSelected : [])
    }

    private var colour: Color {
        if active { return ThemeTokens.textStrong.color }
        return (hovered ? ThemeTokens.text : ThemeTokens.textDim).color
    }
}

// The Refresh button: the refresh icon of 12 in a button of 16, with its Bifrost tooltip.
private struct RefreshButton: View {
    let style: PanelStyle
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ButtonIcon(icon: .refreshCw, size: style.points(12))
                .frame(width: style.points(16), height: style.points(16))
        }
        .buttonStyle(IconButtonStyle(style: style))
        .focusable(false)
        .accessibilityLabel("Refresh")
        .background(TipAnchor(text: "Refresh", side: .top))
    }
}

// The Open Settings button of the panel, in the look of the buttons of a row.
private struct OpenSettingsButton: View {
    let label: String
    let style: PanelStyle
    let action: () -> Void

    var body: some View {
        Button(label, action: action)
            .buttonStyle(RowButtonStyle(tone: .plain, style: style))
            .focusable(false)
    }
}

// The frames of the rows and of the visible part of the list, in the coordinates of the panel
// (top left origin). The host finds the row under a right-click or a Cmd+click with them.
@MainActor
package final class ReviewRowFrames {
    nonisolated static let space = "reviews-panel"
    package var rows: [PRKey: CGRect] = [:]
    package var visible: CGRect = .zero

    // The PR of the row at the point, or nil. A row that the list scrolled out of view is not at
    // a point.
    package func row(at point: CGPoint) -> PRKey? {
        guard visible.contains(point) else { return nil }
        return rows.first { $0.value.contains(point) }?.key
    }
}
