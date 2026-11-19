import AppKit

// The app object of the UI tests. The tests make views and windows, but the test process never
// becomes an active app: it shows no Dock icon and takes no key focus. The tests never order a
// window front. The app is dark, as Bifrost is.
@MainActor
package enum UITestApp {
    package static func prepare() {
        let app = NSApplication.shared
        if app.activationPolicy() != .prohibited { app.setActivationPolicy(.prohibited) }
        if app.appearance?.name != .darkAqua { app.appearance = NSAppearance(named: .darkAqua) }
    }
}
