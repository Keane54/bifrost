// The body of a panel of a later phase of the native app: a short text in the middle of the panel,
// in SwiftUI in one NSHostingView. The text has no control, so the body is not focusable.
import AppKit
import BifrostLook
import SwiftUI

package struct LaterPanel: View {
    // The text of each panel of a later phase.
    package static let text = "This panel comes in a later build of Bifrost Dev."

    let look: PanelLook

    package init(look: PanelLook) {
        self.look = look
    }

    package var body: some View {
        let metrics = look.metrics
        Text(Self.text)
            .font(.system(size: metrics.points(14)))
            .foregroundStyle(ThemeTokens.textDim.color)
            .multilineTextAlignment(.center)
            .padding(metrics.points(24))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// The host of a panel of a later phase. It never takes the first responder.
package typealias LaterPanelHost = PassiveHostingView<LaterPanel>

extension LaterPanel {
    package static func host(look: PanelLook) -> LaterPanelHost {
        let host = LaterPanelHost(rootView: LaterPanel(look: look))
        host.sizingOptions = []
        return host
    }
}
