import BifrostFoundation
import BifrostLayout
import BifrostSessions

// The typed views of the raw values of the UI state. BifrostLayout keeps the Overview configs and
// the history of the New session dialog as JSON values, because it cannot see OverviewConfig
// (this module) and History (BifrostSessions). These views read them with the rules of those
// types, and write their JSON forms.
extension UIState {
    // The config of the Overview panel: the parse of its saved config. A panel with no saved
    // config, or with a config that OverviewConfig.parse refuses, gets the standard config.
    package func overviewConfig(_ id: PanelID) -> OverviewConfig {
        OverviewConfig.parse(overviews[id]) ?? .standard
    }

    // Change the config of the Overview panel. The change starts from overviewConfig(id), so the
    // first change of a panel with no saved config starts from the standard config. Only a
    // config that changed is written, and only under its own key. So a change with no effect
    // writes nothing, and the saved configs of the other panels stay as they are, also a config
    // that the parse refuses. An ID that is not the ID of an Overview panel changes nothing.
    package mutating func updateOverview(_ id: PanelID, _ change: (inout OverviewConfig) -> Void) {
        guard id.kind == .overview else { return }
        let old = overviewConfig(id)
        var config = old
        change(&config)
        guard config != old else { return }
        overviews[id] = config.json
    }

    // The history of the New session dialog. A missing or bad value gives the empty history. The
    // set writes the JSON form.
    package var dialogHistory: History {
        get { History.parse(history) }
        set { history = newValue.json }
    }
}
