// The body of the Watchlist panel (docs/behaviour/panels.md, "The Watchlist"). There is one
// Watchlist panel, so the part has at most one body. The Watchlist shares the model of the
// Overview panels: the rows of the session list, their one place, the selection, the Row flash
// setting, the icons of the terminal apps, and the Open and row menu actions that the action
// runner links (ActionRunner.attach).
import AppKit
import BifrostFoundation
import BifrostLayout
import BifrostSessions

@MainActor
package final class WatchlistPanels: PanelBodiesPart {
    private let model: OverviewModel
    private let registry: () -> RegistryService?
    private let labels: () -> LabelSet
    private let look: PanelLook
    private let filter: () -> WindowKeyFilter?
    private var body: WatchlistPanel?

    // registry gives the registry of a move, or nil before the start of the services made it.
    // labels gives the label set of the settings, for the empty text; it can read observed
    // values, so the text follows a change. The window makes the key filter after the parts, so
    // the body reads it at each click.
    package init(
        model: OverviewModel, registry: @escaping () -> RegistryService?,
        labels: @escaping () -> LabelSet, look: PanelLook,
        filter: @escaping () -> WindowKeyFilter?
    ) {
        self.model = model
        self.registry = registry
        self.labels = labels
        self.look = look
        self.filter = filter
    }

    package func body(for panel: PanelID) -> NSView? {
        guard panel == .watchlist else { return nil }
        if let body { return body }
        let body = WatchlistPanel(
            model: model, registry: registry, labels: labels, look: look, filter: filter)
        self.body = body
        return body
    }

    // The panel is in no frame now: its body goes.
    package func releaseBody(for panel: PanelID) {
        guard panel == .watchlist else { return }
        body = nil
    }

    #if DEBUG
    // The body while the panel is in a frame, or nil. The debug test port reads its rows.
    package var shown: WatchlistPanel? { body }
    #endif
}
