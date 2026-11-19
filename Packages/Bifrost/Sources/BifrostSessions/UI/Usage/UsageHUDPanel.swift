// The Usage HUD panel (docs/behaviour/usage.md, "The Usage HUD"): one bar for each limit window,
// then the source line at the bottom. SwiftUI in one NSHostingView (UsageHUDPanels). Each text
// and each value comes from UsageView.of through UsageHUD, so the view only lays them out. The
// HUD has no control, so it takes no focus.
//
// The sizes are in layout units at the interface scale: a padding of 12, 12 between the bars, a
// text of 12 for the label and the percent, a bar of 6 with 4 above and below it, and a text of
// 11 for the detail and the source line.
import AppKit
import BifrostLook
import SwiftUI

package struct UsageHUDPanel: View {
    package let hud: UsageHUD

    package init(hud: UsageHUD) {
        self.hud = hud
    }

    package var body: some View {
        let metrics = hud.metrics
        let content = hud.content
        // The source line is at the bottom, at least 12 below the last bar.
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: metrics.points(12)) {
                ForEach(content.bars, id: \.label) { bar in
                    UsageBarView(bar: bar, metrics: metrics)
                }
            }
            Spacer(minLength: metrics.points(12))
            Text(content.source)
                .font(Self.font(11, metrics))
                .foregroundStyle(ThemeTokens.textDim.color)
        }
        .padding(metrics.points(12))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .font(Self.font(12, metrics))
        .foregroundStyle(ThemeTokens.text.color)
        .focusable(false)
        .focusEffectDisabled()
    }

    // The font of the UI at a size in layout units.
    static func font(_ size: Double, _ metrics: CanvasMetrics) -> Font {
        Font(Fonts.ui(metrics.points(size), weight: .regular) as CTFont)
    }
}

// One bar: the label and the percent on one line, the bar, then the detail. VoiceOver reads the
// three texts as one element. The bar itself is hidden from accessibility.
struct UsageBarView: View {
    let bar: UsageBar
    let metrics: CanvasMetrics

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text(bar.label)
                Spacer(minLength: metrics.points(8))
                Text(bar.percentText).foregroundStyle(ThemeTokens.textStrong.color)
            }
            ZStack(alignment: .leading) {
                Rectangle().fill(ThemeTokens.panelEdge.color)
                Rectangle().fill(bar.colour.color)
                    .scaleEffect(x: bar.fill, y: 1, anchor: .leading)
            }
            .frame(height: metrics.points(6))
            .padding(.vertical, metrics.points(4))
            .accessibilityHidden(true)
            Text(bar.detail)
                .font(UsageHUDPanel.font(11, metrics))
                .foregroundStyle(ThemeTokens.textDim.color)
        }
        .accessibilityElement(children: .combine)
    }
}

extension UsageBar {
    // The percent as the HUD shows it: "42%", or "-" when no value is known.
    package var percentText: String { percent.map { "\($0)%" } ?? "-" }

    // The part of the bar in the colour of the bar, from 0 to 1. A bar with no value is empty.
    package var fill: Double { Double(percent ?? 0) / 100 }

    // The colour of the bar, from its level: teal, amber or red.
    package var colour: TokenColour { level.colour }
}

extension UsageLevel {
    // The one place that maps a level to a token.
    package var colour: TokenColour {
        switch self {
        case .normal: ThemeTokens.usage
        case .raised: ThemeTokens.usageRaised
        case .high: ThemeTokens.usageHigh
        }
    }
}
