// The body of the Selected Item panel (docs/behaviour/actions.md, "The Selected Item panel"): the
// SwiftUI host of SelectedItemView over the whole body. The view scrolls in a SwiftUI scroll view
// when the panel is lower than its content, and it holds the AppKit send box of the body as a
// representable. With no selected row, the view shows no send box.
//
// SelectedItemPanels makes the body of the one panel selected-item. The send box model lives in
// the part, so the drafts stay when the panel closes.
import AppKit
import BifrostLayout
import BifrostLook
import BifrostSessions
import SwiftUI

@MainActor
package final class SelectedItemPanels: PanelBodiesPart {
    package let model: SelectedItemModel
    private var panel: SelectedItemPanel?

    // The part takes the focus calls of the runner: Send message and Run slash command focus the
    // send box of the body.
    package init(runner: ActionRunner, overviews: OverviewModel, look: PanelLook) {
        model = SelectedItemModel(runner: runner, overviews: overviews, look: look)
        runner.focusSendBox = { [weak self] id, slash in
            self?.panel?.focusSendBox(id, slash: slash)
        }
    }

    package func body(for panel: PanelID) -> NSView? {
        guard panel == .selectedItem else { return nil }
        if let body = self.panel { return body }
        let body = SelectedItemPanel(model: model)
        self.panel = body
        return body
    }

    package func releaseBody(for panel: PanelID) {
        if panel == .selectedItem { self.panel = nil }
    }
}

// The body of the panel: the host of the view, and the send box that the view holds. The body
// keeps the box, so its focus and its follow stay while the content of the view changes.
@MainActor
package final class SelectedItemPanel: NSView {
    package let host: SelectedItemHost
    package let sendBox: SendBoxView

    package init(model: SelectedItemModel) {
        let selection = model.selection
        sendBox = SendBoxView(model: model.sendBox) { selection.selectedRow?.sessionId }
        host = SelectedItemHost(rootView: SelectedItemView(model: model, sendBox: sendBox))
        host.sizingOptions = []
        super.init(frame: .zero)
        host.autoresizingMask = [.width, .height]
        addSubview(host)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override package var isFlipped: Bool { true }
    override package var acceptsFirstResponder: Bool { false }

    override package func layout() {
        super.layout()
        host.frame = bounds
    }

    // Focus the send box for the session. The selection changed just before the call, and the
    // view shows the send box only for a selected row, so the host first lays out the view of
    // now: then the box is in the window.
    func focusSendBox(_ id: String, slash: Bool) {
        host.layoutSubtreeIfNeeded()
        sendBox.takeFocus(for: id, slash: slash)
    }
}

// The host of the SwiftUI part. It never takes the first responder, and it is not in the Tab loop
// of the window. The send box in it takes the focus itself.
package typealias SelectedItemHost = PassiveHostingView<SelectedItemView>
