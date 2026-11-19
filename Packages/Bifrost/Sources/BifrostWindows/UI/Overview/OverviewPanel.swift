// The body of an Overview panel (docs/behaviour/overview.md): the tab bar on top
// (OverviewTabsView), the rows of the active tab below it (OverviewRowsView), and the error line of
// the session list at the bottom. The tab bar is SwiftUI in one host view; the body puts the host
// above the rows.
//
// While the body is in a window, it follows the model with Observations: each change of a value
// that it shows (the config, the rows, the selection, the open chats, the Row flash setting, the
// icons of the terminal apps, the Interface scale, the Panel transparency and the status of the
// session list) gives the table a new input. Out of a window the body follows nothing and its age
// timer stops. Back in a window, the age texts show the time of now.
import AppKit
import BifrostKeyboard
import BifrostLayout
import BifrostLook
import BifrostSessions
import Observation
import SwiftUI

// The values of one Overview body.
package struct OverviewPanelState: Equatable, Sendable {
    package var table: TableInput
    // The text of the error line: the error of the last update of the session list, or the text
    // of a missing claude. nil hides the line.
    package var error: String?

    @MainActor
    package init(model: OverviewModel, panel: PanelID, look: PanelLook) {
        table = TableInput(model: model, panel: panel, look: look)
        switch model.sessions.status {
        case .failed(let error): self.error = error.message
        case .claudeNotFound: error = AgentListError.claudeNotFound.message
        case .starting, .ready: error = nil
        }
    }
}

@MainActor
package final class OverviewPanel: NSView {
    package let panel: PanelID
    package let rows: OverviewRowsView
    package let errorLine = PanelErrorLine()
    private let model: OverviewModel
    private let look: PanelLook
    private var following: Task<Void, Never>?

    // The host of the tab bar of the Overview, above the rows.
    package let tabBar: OverviewTabsHost

    package init(
        panel: PanelID, model: OverviewModel, look: PanelLook,
        filter: @escaping () -> WindowKeyFilter?
    ) {
        self.panel = panel
        self.model = model
        self.look = look
        rows = OverviewRowsView(panel: panel, model: model, filter: filter)
        tabBar = OverviewTabsView.host(model: model, panel: panel, look: look)
        super.init(frame: .zero)
        // At the end of a rename that had the focus, the rows get the focus.
        tabBar.rootView.rename.refocus = { [weak rows] in rows?.focus() }
        addSubview(tabBar)
        addSubview(rows)
        errorLine.isHidden = true
        addSubview(errorLine)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    isolated deinit {
        following?.cancel()
    }

    override package var isFlipped: Bool { true }

    override package func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            following?.cancel()
            following = nil
            rows.stop()
        } else {
            follow()
            rows.resume()
        }
    }

    private func follow() {
        guard following == nil else { return }
        let (model, look, panel) = (model, look, panel)
        let changes = Observations {
            OverviewPanelState(model: model, panel: panel, look: look)
        }
        following = Task { [weak self] in
            for await state in changes { self?.show(state) }
        }
    }

    private func show(_ state: OverviewPanelState) {
        rows.apply(state.table)
        errorLine.show(state.error, metrics: state.table.metrics)
        needsLayout = true
    }

    override package func layout() {
        super.layout()
        let metrics = rows.input?.metrics ?? look.metrics
        let top = metrics.points(Self.tabBarHeight)
        tabBar.frame = NSRect(x: 0, y: 0, width: bounds.width, height: top)
        var bottom = bounds.height
        if !errorLine.isHidden {
            let height = errorLine.height(for: bounds.width)
            bottom -= height
            errorLine.frame = NSRect(x: 0, y: bottom, width: bounds.width, height: height)
        }
        rows.frame = NSRect(x: 0, y: top, width: bounds.width, height: max(0, bottom - top))
    }

    // The height of the tab bar, in layout units.
    package static let tabBarHeight = 22.0
}

// The bodies of the Overview panels: one body for each Overview panel in a frame. All bodies
// share one model. The parts also give the dim set name after the title of an Overview, and the
// focus of the rows of each Overview for the key commands.
@MainActor
package final class OverviewPanels: PanelBodiesPart {
    // The model that all bodies share.
    package let model: OverviewModel
    private let look: PanelLook
    // The key filter of the window, for the hold keys of a row click (D8). The window makes the
    // filter after the parts, so the parts read it at each click.
    private let filter: () -> WindowKeyFilter?
    private var bodies: [PanelID: OverviewPanel] = [:]

    package init(
        model: OverviewModel, look: PanelLook, filter: @escaping () -> WindowKeyFilter?
    ) {
        self.model = model
        self.look = look
        self.filter = filter
    }

    package func body(for panel: PanelID) -> NSView? {
        guard panel.kind == .overview else { return nil }
        if let body = bodies[panel] { return body }
        let body = OverviewPanel(panel: panel, model: model, look: look, filter: filter)
        bodies[panel] = body
        return body
    }

    package func releaseBody(for panel: PanelID) {
        bodies[panel] = nil
    }

    // The title of an Overview shows the name of its tab set in brackets, in the dim text colour
    // (OverviewTitle).
    package func titleSuffix(for panel: PanelID) -> String? {
        guard panel.kind == .overview else { return nil }
        return "(\(model.config(panel).name))"
    }

    // The Overview whose rows view is the first responder of its window and shows, or nil.
    package var focusedPanel: PanelID? {
        bodies.first { _, body in
            body.rows.window?.firstResponder === body.rows
                && !body.rows.isHiddenOrHasHiddenAncestor
        }?.key
    }

    // Make the rows view of the Overview the first responder, so that the Bifrost keys act on its
    // rows. An Overview with no body, or with a body in no window, does not change the focus.
    package func focusRows(_ panel: PanelID) {
        bodies[panel]?.rows.focus()
    }
}
