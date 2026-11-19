// The model of the Overview panels (docs/behaviour/overview.md): the config of each Overview, the
// rows of its active tab and the actions of a row. All Overview panels share one model, so they
// share the selection (SelectionModel) and the rows of the session list. The Watchlist panel uses
// the same model for the rows, the selection, the Row flash setting, the icons of the terminal
// apps and the actions of a row (WatchlistPanels).
//
// The configs live in ui-state.json. config(_:) reads the UI state store at each call, and
// update(_:_:) and edit(_:_:) change one config inside store.change, so no copy of a config waits
// to be written back. Only this model writes the Overview configs. The store is observable, so a
// view that reads a config sees each change.
import AppKit
import BifrostFoundation
import BifrostLayout
import BifrostSessions
import Foundation
import Observation

@MainActor
@Observable
package final class OverviewModel {
    @ObservationIgnored private let store: UIStateStore
    // The rows of the session list: the one place of the rows.
    @ObservationIgnored package let sessions: SessionListModel
    @ObservationIgnored package let selection: SelectionModel
    // The layout of the window: a row with an open chat has the hover colour.
    @ObservationIgnored package let layout: WindowLayoutModel
    // The clock of the age timers of the tables.
    @ObservationIgnored package let clock: any Clock<Duration>
    // The wall time of the age texts.
    @ObservationIgnored package let now: () -> Date

    // The Row flash setting: the box of a row flashes while the setting is on. The app sets it
    // at each change of the setting.
    package var rowFlash = true
    // The open action of a double-click on a row, with the row ID. The action runner gives its
    // Open (ActionRunner.attach). The default opens the chat of an owned session that is not
    // parked, and opens nothing for another row.
    @ObservationIgnored package var open: (String) -> Void
    // A right-click on a row: the row, the click point in the rows view, and the rows view. The
    // action runner shows the row menu there (ActionRunner.attach and RowMenu.show).
    @ObservationIgnored
    package var showRowMenu: (SessionRow, NSPoint, NSView) -> Void = { _, _, _ in }
    // The Bifrost menu of the window: the tab menu of each Overview shows on it. The canvas sets
    // it when it gets the model. With no menu, a right-click on a tab does nothing.
    @ObservationIgnored package weak var menu: BifrostMenu?
    // The icon of the app that shows a row (SessionIconRules.holder), or nil. The shell gives
    // it at the init. The tables read it during their observation, so a new closure, a new icon
    // or a new app of a row shows at once.
    package var appIcon: (SessionRow) -> AppIcon?
    // The New session starts that run, in their order (ActionRunner.starting). The action runner
    // gives it when it links to the Overviews. The tables read it during their observation.
    package var starting: () -> [StartingSession] = { [] }

    package init(
        store: UIStateStore, sessions: SessionListModel, selection: SelectionModel,
        layout: WindowLayoutModel, clock: any Clock<Duration>, now: @escaping () -> Date,
        appIcon: @escaping (SessionRow) -> AppIcon? = { _ in nil }
    ) {
        self.appIcon = appIcon
        self.store = store
        self.sessions = sessions
        self.selection = selection
        self.layout = layout
        self.clock = clock
        self.now = now
        open = { [sessions, layout] id in
            guard let row = sessions.rows.first(where: { $0.sessionId == id }),
                row.isOwnedAndNotParked
            else { return }
            layout.openChat(id)
        }
    }

    // The config of the Overview panel. A panel with no saved config, or with a config that the
    // parse refuses, has the standard config.
    package func config(_ panel: PanelID) -> OverviewConfig {
        store.state.overviewConfig(panel)
    }

    // Apply the action to the config of the Overview panel and save the result. An action that
    // changes nothing writes nothing.
    package func update(_ panel: PanelID, _ action: OverviewAction) {
        edit(panel) { $0.apply(action) }
    }

    // Change the config of the Overview panel with a rule that gives a whole config, for example
    // a filter rule of OverviewSettingsRules, and save the result. The change gets the config of
    // now inside the change of the store, so no copy of a config that a view read earlier is
    // written back. A change with no effect writes nothing. Only an Overview panel has a config.
    package func edit(_ panel: PanelID, _ change: (inout OverviewConfig) -> Void) {
        store.change { $0.updateOverview(panel, change) }
    }

    // True while the Overview panel is in a frame, also in a minimised frame or a back tab.
    package func isOpen(_ panel: PanelID) -> Bool {
        layout.layout.frame(of: panel) != nil
    }

    // The rows of the active tab of the Overview panel: the filter, then the sort.
    package func viewRows(_ panel: PanelID) -> [SessionRow] {
        OverviewRows.view(sessions.rows, tab: config(panel).activeTab)
    }

    // The starts that each Overview tab shows as Starting rows after its rows: each start whose
    // row is not in the session list yet. The filters of a tab do not apply to them.
    package var startingRows: [StartingSession] {
        StartingSession.shown(starting(), rows: sessions.rows)
    }

    // The sessions whose chat is in a frame, also in a tab that is not active.
    package var openChats: Set<SessionID> {
        var sessions = Set<SessionID>()
        for frame in layout.layout.frames {
            for case .chat(let session) in frame.panels { sessions.insert(session) }
        }
        return sessions
    }

    // The wall time of now in milliseconds since 1970, the time form of a row (row D1 of the
    // registry).
    package var nowMilliseconds: Int { now().millisecondsSince1970 }
}
