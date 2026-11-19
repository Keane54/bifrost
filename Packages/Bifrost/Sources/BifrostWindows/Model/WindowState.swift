import BifrostFoundation
import BifrostLayout

// The window state file, window-state.json: the display mode and the bounds of the normal window,
// and the place of the window at the start. The file keeps the names and the meaning of the files
// of the Electron app (the section "Files on disk" of the architecture design).

// A rect on the screens, in points. In the file, the origin is the top-left corner of the
// primary screen (the screen at the origin of AppKit, NSScreen.screens.first), and y goes down,
// as in the screen coordinates of the Electron app. WindowPlacement converts the frames of
// AppKit to this form and back.
public struct WindowBounds: Sendable, Equatable, Codable {
    package var x: Double
    package var y: Double
    package var width: Double
    package var height: Double

    package init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

// The place of a window at the start.
public enum RestoredPlace: Sendable, Equatable {
    // The saved bounds, in the coordinates of the file.
    case at(WindowBounds)
    // No saved bounds, or saved bounds off all screens: the window opens in the centre with
    // this size.
    case centred(width: Double, height: Double)
}

public struct WindowState: Sendable, Equatable {
    // The smallest saved bounds that the decode keeps.
    static let minSavedWidth = 400.0, minSavedHeight = 300.0

    public var mode: DisplayMode
    // The bounds of the normal window: not the bounds of a full screen. nil for no bounds.
    public var bounds: WindowBounds?
    // The top-level fields of the file that this app does not know. A save writes them again.
    package var unknown = UnknownFields()

    package init(mode: DisplayMode = .window, bounds: WindowBounds? = nil) {
        self.mode = mode
        self.bounds = bounds
    }
}

extension WindowState: Codable {
    private enum Key: String, CodingKey {
        case mode, bounds
    }

    // The decode refuses a value that is not an object, and the store then uses the default
    // state. The state keeps the unknown fields of the object. A bad field gets its default and
    // the other field stays: a mode that is not one of the three gives window. Bounds need four
    // finite numbers, a width of minSavedWidth or more and a height of minSavedHeight or more,
    // else they are nil.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: Key.self)
        unknown = try UnknownFields(from: decoder, known: Key.self)
        mode = (try? container.decode(DisplayMode.self, forKey: .mode)) ?? .window
        bounds = (try? container.decode(WindowBounds.self, forKey: .bounds)).flatMap { saved in
            let finite = [saved.x, saved.y, saved.width, saved.height].allSatisfy(\.isFinite)
            let large = saved.width >= Self.minSavedWidth && saved.height >= Self.minSavedHeight
            return finite && large ? saved : nil
        }
    }

    // No bounds give null. The unknown fields come after the two keys.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: Key.self)
        try container.encode(mode, forKey: .mode)
        try container.encode(bounds, forKey: .bounds)
        try unknown.encode(to: encoder)
    }
}

public enum WindowPlacement {
    // The size of a window with no saved bounds.
    package static let defaultWidth = 1440.0, defaultHeight = 900.0
    // The smallest size of the window.
    package static let minWidth = 800.0, minHeight = 500.0
    // The time from the last move or resize of the window to the save of its bounds.
    package static let saveDelay = Duration.milliseconds(500)
    // The part of the top edge area that must be on a screen, so the user can grab the window.
    static let grabWidth = 100.0, grabHeight = 40.0

    // The place of the window at the start (restoreBounds). The saved bounds stay when at least
    // grabWidth by grabHeight of the top grabHeight rows of the window, over its full width, is
    // in one work area. Else the window opens in the centre at the default size. The saved
    // bounds and the work areas are in the coordinates of the file, so each value is finite.
    public static func restore(_ saved: WindowBounds?, workAreas: [WindowBounds])
        -> RestoredPlace
    {
        let centred = RestoredPlace.centred(width: defaultWidth, height: defaultHeight)
        guard let saved else { return centred }
        let visible = workAreas.contains { area in
            let width = min(saved.x + saved.width, area.x + area.width) - max(saved.x, area.x)
            let top = max(saved.y, area.y)
            let height = min(saved.y + grabHeight, area.y + area.height) - top
            return width >= grabWidth && height >= grabHeight
        }
        return visible ? .at(saved) : centred
    }

    // The bounds in the coordinates of the file for a frame of AppKit. AppKit puts the origin at
    // the bottom-left corner of the primary screen, and y goes up. primaryScreenHeight is the
    // height of the frame of the primary screen (NSScreen.screens.first), not of NSScreen.main: the
    // main screen of AppKit is the screen of the key window. fileY = primaryScreenHeight - (appKitY
    // + height). x and the size do not change.
    package static func fileBounds(appKit frame: WindowBounds, primaryScreenHeight: Double)
        -> WindowBounds
    {
        flipped(frame, primaryScreenHeight)
    }

    // The frame of AppKit for bounds in the coordinates of the file: the same flip back.
    package static func appKitFrame(_ bounds: WindowBounds, primaryScreenHeight: Double)
        -> WindowBounds
    {
        flipped(bounds, primaryScreenHeight)
    }

    // The flip is its own inverse: y becomes the distance from the other edge of the primary
    // screen to the other edge of the rect.
    private static func flipped(_ rect: WindowBounds, _ height: Double) -> WindowBounds {
        WindowBounds(
            x: rect.x, y: height - (rect.y + rect.height), width: rect.width, height: rect.height)
    }
}
