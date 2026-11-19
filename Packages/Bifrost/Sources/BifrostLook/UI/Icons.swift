// The icons of the side bar, the frames, the layout menu, the row icons of the Overview, the
// buttons of Show Info, the Bifrost menu, the Selected Item panel and the Reviews panel. The raw
// value of a name is the name of its SVG file in Resources/Icons. The committed SVG files are the
// source. Each icon except lock-glyph.svg is a lucide icon of version 1.70.0 (ISC licence,
// Resources/Icons/LICENSE).
// lock-glyph.svg is the glyph of a locked frame, drawn for Bifrost.
//
// To add a lucide icon:
// 1. Copy icons/<name>.svg of the lucide-static package, version 1.70.0, to Resources/Icons as
//    it is (for example from https://unpkg.com/lucide-static@1.70.0/icons/<name>.svg).
// 2. Add a case with the raw value <name> to IconName.
// IconsTests checks that each lucide file keeps the attributes of lucide.
import AppKit

nonisolated package enum IconName: String, Sendable, CaseIterable {
    // The 18 icons of the panel kinds (PanelIcons).
    case activity, crosshair, eye
    case filePen = "file-pen"
    case gauge
    case gitPullRequest = "git-pull-request"
    case heartPulse = "heart-pulse"
    case info, list
    case messageCircleQuestionMark = "message-circle-question-mark"
    case messageSquare = "message-square"
    case messageSquareText = "message-square-text"
    case puzzle
    case scrollText = "scroll-text"
    case settings, shield
    case shieldCheck = "shield-check"
    case slidersHorizontal = "sliders-horizontal"
    // The Panel menu button and the layout menu button.
    case ellipsisVertical = "ellipsis-vertical"
    case layoutGrid = "layout-grid"
    // The lock glyph of a locked frame.
    case lockGlyph = "lock-glyph"
    // The dictation mic.
    case mic
    // The glyphs of the row icon of the Overview: the Bifrost mark of an owned or parked session
    // (a hexagon until the Bifrost logo exists), and the terminal of an external session.
    case hexagon
    case squareTerminal = "square-terminal"
    // The Add tab button of the Overview tab bar, and the drag handle of a column row and the
    // arrow of the Tab picker of the Overview Settings panel.
    case plus
    case gripVertical = "grip-vertical"
    case chevronDown = "chevron-down"
    // The New Overview button of the side bar.
    case listPlus = "list-plus"
    // The Copy session ID button and the close button of the error line of Show Info.
    case copy, x
    // The check mark of a checked row and the arrow of a submenu row of a Bifrost menu. The check
    // mark is also the mark of an approved row of the Reviews panel.
    case check
    case chevronRight = "chevron-right"
    // The New session and the Resume all buttons of the side bar.
    case squarePlus = "square-plus"
    case rotateCcw = "rotate-ccw"
    // The action buttons of the Selected Item panel (with message-square, info, square-terminal
    // and eye above), and the error icon of its name line. circle-alert.svg is the icon
    // circle-exclamation-point, which lucide also names circle-alert.
    case shrink
    case arrowRightLeft = "arrow-right-left"
    case hand
    case appWindow = "app-window"
    case slash, power
    case eyeOff = "eye-off"
    case circleAlert = "circle-alert"
    // The page button of Service status.
    case externalLink = "external-link"
    // The Refresh button of the Reviews panel.
    case refreshCw = "refresh-cw"
    // The loader of a Reviews row while its approval runs.
    case loader
}

@MainActor
package enum Icons {
    private static var cache: [IconName: NSImage] = [:]

    // The folder of the SVG files in the resource bundle.
    static var folder: URL? { Bundle.module.url(forResource: "Icons", withExtension: nil) }

    // The icon as a template image: AppKit draws it in the colour of the control. The size is
    // the size of the SVG (24 by 24 points, 12 by 12 for the lock glyph). The caller sets the
    // size that it draws. Each call gives a new copy, so a change of the size of one copy does
    // not change the others. A file that is missing gives an empty image of 16 by 16 points.
    package static func image(_ name: IconName) -> NSImage {
        let image = loaded(name)
        return image.copy() as? NSImage ?? image
    }

    private static func loaded(_ name: IconName) -> NSImage {
        if let image = cache[name] { return image }
        let file = folder?.appending(path: "\(name.rawValue).svg")
        let image =
            file.flatMap { NSImage(contentsOf: $0) } ?? NSImage(size: NSSize(width: 16, height: 16))
        image.isTemplate = true
        cache[name] = image
        return image
    }
}
