// The body of a section that a later build of Bifrost fills (row S1 of docs/ports/settings): one
// line of dim text. The section keeps its tab, and the search does not look at it.
import BifrostLook
import SwiftUI

package struct LaterSection: View {
    package static let text = "This section comes in a later build of Bifrost Dev."

    let model: SettingsModel

    package init(model: SettingsModel) {
        self.model = model
    }

    package var body: some View {
        let style = PanelStyle(model)
        Text(Self.text)
            .foregroundStyle(style.dim)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, style.points(12))
            .padding(.vertical, style.points(8))
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
