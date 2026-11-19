// The body of the Settings panel in the canvas: one part of the panel bodies. The shell makes the
// part with the window, before the settings store opens, so the body of a Settings panel of the
// start layout is first an empty view. The model fills it when the store opens (attach(_:)).
// When the panel leaves the last frame, its rows go away (SettingsModel.panelClosed()), and a
// later open makes a new body. Each open runs the open hook of the model one time
// (SettingsLinks.onPanelOpen): a new body with the model, or the attach of the model to the body
// of a panel that was open before.
import AppKit
import BifrostLayout

@MainActor
package final class SettingsPanels: PanelBodiesPart {
    package private(set) var model: SettingsModel?
    // The body of the Settings panel while it is in a frame.
    private var body: SettingsBody?

    package init() {}

    // The settings store opened: the body shows the panel. Only the first model counts.
    package func attach(_ model: SettingsModel) {
        guard self.model == nil else { return }
        self.model = model
        guard let body else { return }
        body.fill(with: model)
        model.links.onPanelOpen()
    }

    package func body(for panel: PanelID) -> NSView? {
        guard panel == .settings else { return nil }
        if let body { return body }
        let made = SettingsBody()
        body = made
        if let model {
            made.fill(with: model)
            model.links.onPanelOpen()
        }
        return made
    }

    package func releaseBody(for panel: PanelID) {
        guard panel == .settings, body != nil else { return }
        body = nil
        model?.panelClosed()
    }
}

// The view of the Settings panel in its frame: the host of the panel after the settings store
// opened, else nothing. The canvas sets its size, and the host takes the full size.
package final class SettingsBody: NSView {
    package private(set) var host: SettingsHost?

    override package var acceptsFirstResponder: Bool { false }

    func fill(with model: SettingsModel) {
        guard host == nil else { return }
        let host = SettingsHost(model: model)
        host.frame = bounds
        host.autoresizingMask = [.width, .height]
        addSubview(host)
        self.host = host
        model.endEditing = { [weak host] in host?.endEditing() }
    }
}
