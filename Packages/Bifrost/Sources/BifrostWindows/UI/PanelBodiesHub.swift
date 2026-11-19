// The bodies and the titles of the panels of the canvas: the one PanelBodies of the canvas. It
// joins the parts, for example the chat terminals, the Overview panels and the Settings panel
// (SettingsPanels). The first part that gives a body for a panel makes the body of that panel.
// Each other panel is a panel of a later phase, and it shows the text of LaterPanel. The titles
// are the titles of panelTitle (PanelTitle) with the rows of now. The first part that gives a
// title suffix for a panel gives the dim text after its title, for example the name of the tab
// set of an Overview.
//
// A part can come after the start (add(_:)), for example the Selected Item panel, which needs the
// action runner of the services. Until then, a panel that waits for its part shows an empty body,
// and not the text of LaterPanel: the panel is in this build.
import AppKit
import BifrostLayout
import BifrostLook
import BifrostSessions
import Observation

// The values of the look that the panel bodies read: the Interface scale and the Panel
// transparency. The app sets them at each change of the settings.
@MainActor
@Observable
package final class PanelLook {
    package var interfaceScale = 100
    // The Panel transparency in percent: the header of an Overview table has the panel colour.
    package var panelTransparency = ThemeTokens.defaultTransparency

    package init() {}

    var metrics: CanvasMetrics { CanvasMetrics(interfaceScale: interfaceScale) }
}

@MainActor
package final class PanelBodiesHub: PanelBodies {
    private var parts: [any PanelBodiesPart]
    private let look: PanelLook
    private let rows: () -> [SessionRow]
    // The panels whose part comes after the start. After add(_:), the parts come first, so the
    // set has no effect on the panels of the part.
    private let waiting: Set<PanelID>
    // The body of each panel of a later phase in a frame, and of each panel that waits for its
    // part.
    private var later: [PanelID: NSView] = [:]

    // rows gives the rows of the last session list, for the titles. waiting gives the panels
    // whose part comes after the start.
    package init(
        parts: [any PanelBodiesPart], look: PanelLook, rows: @escaping () -> [SessionRow],
        waiting: Set<PanelID> = []
    ) {
        self.parts = parts
        self.look = look
        self.rows = rows
        self.waiting = waiting
    }

    // Add a part after the start. Each panel of the part that had a body of the hub (the empty
    // body of a waiting panel, or the text of LaterPanel) gets the body of the part. The result
    // is these panels, in order, so the canvas shows their new bodies (CanvasView.reloadBodies).
    package func add(_ part: any PanelBodiesPart) -> [PanelID] {
        parts.append(part)
        let taken = later.keys.filter { part.body(for: $0) != nil }.sorted()
        for panel in taken { later[panel] = nil }
        return taken
    }

    package func body(for panel: PanelID) -> NSView {
        for part in parts {
            if let body = part.body(for: panel) { return body }
        }
        if let host = later[panel] { return host }
        let host = waiting.contains(panel) ? WaitingPanel() : LaterPanel.host(look: look)
        later[panel] = host
        return host
    }

    package func title(for panel: PanelID) -> String {
        PanelTitle.of(panel, rows: rows())
    }

    package func titleSuffix(for panel: PanelID) -> String? {
        parts.lazy.compactMap { $0.titleSuffix(for: panel) }.first
    }

    package func releaseBody(for panel: PanelID) {
        for part in parts { part.releaseBody(for: panel) }
        later[panel] = nil
    }
}

// The empty body of a panel that waits for its part. It takes no focus.
package final class WaitingPanel: NSView {
    override package var acceptsFirstResponder: Bool { false }
}
