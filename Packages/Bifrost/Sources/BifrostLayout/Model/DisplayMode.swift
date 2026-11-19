// The display mode of the main window: a titled window, a borderless window that fills its
// screen, or the native full screen. The window keeps it in window-state.json, and Settings >
// General shows it and changes it.
public enum DisplayMode: String, Sendable, CaseIterable, Codable {
    case window, borderless, fullscreen
}
