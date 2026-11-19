import BifrostFoundation
import BifrostLayout
import BifrostLook
import BifrostSessions
import Observation

// The state of the side bar and of the Layouts popover (docs/behaviour/windows.md, "The side bar
// and layouts"): the Overview button, the New Overview button, the panel buttons (Selected Item,
// Watchlist, Event log, Usage HUD, Service status, Reviews with its dot, Daily update with its
// marker and Performance with the dot of its level), the global buttons (New session and Resume
// all), the minimised frames, the named layouts and the Settings button with its warning dot. The
// other panel buttons come with their panels in later phases. The named layouts are in the UI
// state store, and this model is their only writer.

// A dot of a side bar button in a colour: its text for the tooltip and its colour. The default
// colour is the strong text colour.
package struct SideBarDot: Sendable, Equatable {
    package var text: String
    package var colour: TokenColour

    package init(text: String, colour: TokenColour = ThemeTokens.textStrong) {
        self.text = text
        self.colour = colour
    }
}

@MainActor
@Observable
public final class SideBarModel {
    private let layout: WindowLayoutModel
    private let store: UIStateStore
    // The runner of the session actions. The global buttons run through it. With no runner, they
    // are off.
    package var runner: ActionRunner?

    // The names of the saved layouts, in the order of the file. The store is observable, so a
    // view that reads the names follows each change.
    package var layoutNames: [String] { store.state.layouts.map(\.name) }
    // True while the Layouts popover shows.
    package var popoverOpen = false
    // Each request for the focus of the name field adds one (Cmd+Option+S).
    package var popoverFocusRequest = 0
    // The Interface scale in percent and the panel transparency in percent. The side bar scales
    // as the canvas does, and a hover shows the panel colour.
    public var interfaceScale = 100
    public var panelTransparency = 15
    // The dot of the button of a panel, or nil for no dot. The shell gives the dots at the init:
    // Settings while Live details or Claude Code has a warning, Reviews while a pull request
    // waits for the user, Daily update while its marker shows, and Performance while the level
    // of Bifrost's health is Warning or Problem. It reads observed values, so a view that calls
    // it in its body follows each change. The default shows no dot.
    @ObservationIgnored package let dot: @MainActor (PanelID) -> SideBarDot?

    // The init is package: a dot is a package type.
    package init(
        layout: WindowLayoutModel, store: UIStateStore,
        dot: @escaping @MainActor (PanelID) -> SideBarDot? = { _ in nil }
    ) {
        self.layout = layout
        self.store = store
        self.dot = dot
    }

    // The minimised frames, in z-order: the first is at the bottom.
    package var minimised: [LayoutFrame] { layout.layout.frames.filter(\.minimised) }

    var metrics: CanvasMetrics { CanvasMetrics(interfaceScale: interfaceScale) }

    // The Overview button: the top Overview, else a new overview:1.
    package func openOverview() {
        layout.apply(.open(Self.topOverview(layout.layout.frames) ?? .overview(1)))
    }

    // The lowest overview:<n> that is in no frame, from 1 to 99 (PanelID.overviewNumbers). A
    // minimised frame and a back tab count as a frame. nil when each number has a frame.
    package var freeOverview: PanelID? {
        let layout = layout.layout
        return PanelID.overviewNumbers.lazy.map(PanelID.overview)
            .first { layout.frame(of: $0) == nil }
    }

    // The New Overview button opens the free Overview. With no free number, it does nothing.
    package func openNewOverview() {
        guard let panel = freeOverview else { return }
        layout.apply(.open(panel))
    }

    // A panel button opens its panel, or brings it to the front. A minimised frame of the panel
    // comes back.
    package func open(_ panel: PanelID) {
        layout.apply(.open(panel))
    }

    // The Settings button opens Settings, or brings it to the front.
    package func openSettings() {
        layout.apply(.open(.settings))
    }

    // The state of a global button, from the action model. With no runner, or while a dialog
    // shows, the button is off with no reason. The dialog layer covers only the canvas, so the
    // side bar must not start an action under a dialog.
    package func globalState(_ id: GlobalActionID) -> ActionState {
        guard let runner, !runner.dialogs.isOpen else {
            return ActionState(enabled: false, reason: nil)
        }
        return ActionModel.globalState(id, runner.globalContext)
    }

    // The label set of the action labels and tooltips.
    package var labels: LabelSet { runner?.labels ?? .plain }

    // A click on a global button. It does nothing while a dialog shows, and the runner does
    // nothing for an action that is off.
    package func runGlobal(_ id: GlobalActionID) {
        guard let runner, !runner.dialogs.isOpen else { return }
        runner.runGlobal(id)
    }

    package func restore(_ frame: FrameID) {
        layout.apply(.restore(frame))
    }

    // Save the current layout with the name. A name of 1 to 40 characters after the trim gets
    // the layout. A new name needs a free place in the list of 20.
    package func saveLayout(_ name: String) -> LayoutSaveResult {
        let snapshot = layout.layout.snapshot
        var result = LayoutSaveResult.saved
        store.change { result = $0.saveLayout(name, snapshot) }
        return result
    }

    // Load the layout with the name. A name that is not in the list changes nothing.
    package func loadLayout(_ name: String) {
        guard let item = store.state.layouts.first(where: { $0.name == name }) else { return }
        layout.apply(.load(item.snapshot))
    }

    package func deleteLayout(_ name: String) {
        store.change { $0.deleteLayout(name) }
    }

    // Cmd+Option+S: open the popover, and give the focus to the name field again.
    package func openLayoutSave() {
        popoverOpen = true
        popoverFocusRequest += 1
    }

    // The Overview to focus: the top frame that shows with an Overview first, then a minimised one,
    // each from the top of the z-order. In a frame, the active panel wins over the other tabs.
    static func topOverview(_ frames: [LayoutFrame]) -> PanelID? {
        let order = Array(frames.reversed())
        for frame in order.filter({ !$0.minimised }) + order.filter(\.minimised) {
            if frame.active.kind == .overview { return frame.active }
            if let panel = frame.panels.first(where: { $0.kind == .overview }) { return panel }
        }
        return nil
    }
}
