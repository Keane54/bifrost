// The Trust needed strip of the Reviews panel (docs/behaviour/reviews.md, "Clones and trust"): a
// line for each repository whose clone needs the trust of the user, with the count of its pull
// requests that wait and a Trust button. The button opens the trust panel, where the user answers
// the trust prompt of Claude Code. Bifrost never accepts the prompt itself.
import BifrostLook
import BifrostReviews
import SwiftUI

struct TrustStrip: View {
    let model: ReviewsPanelModel
    let metrics: CanvasMetrics

    var body: some View {
        VStack(alignment: .leading, spacing: metrics.points(2)) {
            Text(ReviewsPanelModel.trustTitle)
                .font(model.style.font(11))
                .foregroundStyle(ThemeTokens.textStrong.color)
            ForEach(model.trustRows, id: \.repo) { line in
                HStack(spacing: metrics.points(8)) {
                    Text(line.repo.description)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text(ReviewsPanelModel.waitingText(line.waiting))
                        .foregroundStyle(ThemeTokens.textDim.color)
                        .lineLimit(1)
                        .fixedSize()
                    Button(ReviewsPanelModel.trustButton) { model.trust(line.repo) }
                        .buttonStyle(RowButtonStyle(tone: .plain, style: model.style))
                        .focusable(false)
                        .background(TipAnchor(text: ReviewsPanelModel.trustTip, side: .top))
                }
                .font(model.style.font(11))
            }
        }
        .padding(.horizontal, metrics.points(12))
        .padding(.vertical, metrics.points(6))
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .bottom) { EdgeLineView(metrics: metrics) }
    }
}
