// The bodies of the Show Info panels (docs/behaviour/panels.md, "Show Info"): one host for each
// show-info:<session ID> panel in a frame. Each body has its own model, and all bodies read the
// rows from the session list, their one place. The title of a panel follows the name of the row
// (PanelTitle).
import AppKit
import BifrostFoundation
import BifrostLayout
import BifrostLook
import BifrostSessions
import SwiftUI

@MainActor
package final class ShowInfoPanels: PanelBodiesPart {
    private let list: SessionListModel
    private let lookup: () -> PRLookup?
    private let actions: AppActions
    private let look: PanelLook
    private let clock: any Clock<Duration>
    private let now: () -> Date
    private let zone: TimeZone
    private var hosts: [SessionID: ShowInfoHost] = [:]

    // lookup gives the PR lookup, or nil before the start of the services made it. It can read
    // observed values, so a panel asks for its PR when the lookup comes. actions gives Copy
    // session ID and the open of the PR. The clock moves the time of each panel each second, and
    // now gives the wall time.
    package init(
        list: SessionListModel, lookup: @escaping () -> PRLookup?, actions: AppActions,
        look: PanelLook, clock: any Clock<Duration>, now: @escaping () -> Date,
        zone: TimeZone = .current
    ) {
        self.list = list
        self.lookup = lookup
        self.actions = actions
        self.look = look
        self.clock = clock
        self.now = now
        self.zone = zone
    }

    package func body(for panel: PanelID) -> NSView? {
        guard case .showInfo(let session) = panel else { return nil }
        if let host = hosts[session] { return host }
        let model = ShowInfoPanelModel(
            session: session, list: list, lookup: lookup, actions: actions, look: look,
            clock: clock, now: now, zone: zone)
        model.start()
        let host = ShowInfoHost(rootView: ShowInfoPanel(model: model))
        host.sizingOptions = []
        hosts[session] = host
        return host
    }

    // The panel is in no frame now: its body stops its work and goes.
    package func releaseBody(for panel: PanelID) {
        guard case .showInfo(let session) = panel, let host = hosts.removeValue(forKey: session)
        else { return }
        host.rootView.model.stop()
    }

    #if DEBUG
    // The model of the body of each panel in a frame, in the order of the session IDs. The debug
    // test port reads their PR lines.
    package var models: [ShowInfoPanelModel] {
        hosts.sorted { $0.key.text < $1.key.text }.map(\.value.rootView.model)
    }
    #endif
}

// The host of a Show Info panel. It never takes the first responder, and it is not in the Tab
// loop of the window.
package typealias ShowInfoHost = PassiveHostingView<ShowInfoPanel>
