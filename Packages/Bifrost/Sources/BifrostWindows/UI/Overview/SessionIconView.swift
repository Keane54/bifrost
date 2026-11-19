// The row icon of the Overview (docs/behaviour/overview.md, Cells and the icon). The glyph shows
// the kind of the session, and its colour shows the project. A box is four corner brackets
// around the glyph, in the box colour. The brackets flash while the row has a box and the Row
// flash setting is on: a Core Animation opacity animation on their layer, so a flash costs no
// work of the app.
import AppKit
import BifrostFoundation
import BifrostLook
import BifrostSessions
import Observation
import QuartzCore

// The icon of the app that shows a session (SessionHolder), and the name of the app for the
// tooltip.
package struct AppIcon: Equatable, Sendable {
    package var image: NSImage
    package var name: String

    package init(image: NSImage, name: String) {
        self.image = image
        self.name = name
    }
}

// What a row icon shows: the glyph, its colour, the box and the flash. A row and the Row flash
// setting give it.
package struct SessionIconLook: Equatable {
    package enum Glyph: Equatable {
        // The Bifrost mark: a parked session of either kind, or an owned session while no icon
        // of an app is known.
        case mark
        // The terminal glyph: an external session with no icon of its terminal app.
        case terminal
        // The icon of the app that shows the session, in its own colours: Bifrost, or the
        // terminal app.
        case app(NSImage)
    }

    package var glyph: Glyph
    // The colour of the mark and of the terminal glyph: the project colour, or the parked
    // colour for a parked row.
    package var colour: TokenColour
    // The colour of the brackets, or nil for a row with no box.
    package var box: TokenColour?
    package var flashes: Bool
    // The tooltip: the kind of the session, or the name of the app of its icon.
    package var title: String

    // appIcon is the icon of the app that shows the row (SessionIconRules.holder), when the row
    // has such an app and its icon is known. A parked row always shows the mark.
    package init(row: SessionRow, appIcon: AppIcon?, rowFlash: Bool) {
        let kind = SessionIconRules.iconKind(row)
        let app = appIcon.map { Glyph.app($0.image) }
        switch kind {
        case .parked: glyph = .mark
        case .owned: glyph = app ?? .mark
        case .external: glyph = app ?? .terminal
        }
        colour =
            kind == .parked
            ? ThemeTokens.parked
            : ThemeTokens.project(
                SessionIconRules.projectColourIndex(SessionIconRules.projectKey(row.cwd)))
        switch row.alert {
        case .none: box = nil
        case .yellow: box = ThemeTokens.boxYellow
        case .red: box = ThemeTokens.boxRed
        }
        flashes = box != nil && rowFlash
        if case .app = glyph, let appIcon {
            title = appIcon.name
        } else {
            title = Self.titles[kind] ?? ""
        }
    }

    private static let titles: [IconKind: String] = [
        .owned: "Owned session", .external: "External session", .parked: "Parked session",
    ]
}

// The icon of one row: a square of side size. The glyph is 2/3 of the side, and the icon of a
// terminal app 7/8. Each arm of a bracket is 30 % of the side, and its border is 2 layout units.
@MainActor
package final class SessionIconView: NSView {
    // The key of the flash animation on the layer of the brackets.
    package static let flashKey = "box-flash"

    // The glyph. A template image takes the colour of the look.
    package let glyphView = NSImageView()
    package let brackets = BracketsView()
    package private(set) var look: SessionIconLook?
    // The points of one layout unit, for the border of the brackets.
    private var unit: CGFloat = 1

    override package init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        glyphView.imageScaling = .scaleProportionallyUpOrDown
        glyphView.imageAlignment = .alignCenter
        glyphView.isEditable = false
        glyphView.refusesFirstResponder = true
        glyphView.setAccessibilityElement(false)
        addSubview(glyphView)
        brackets.isHidden = true
        addSubview(brackets)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    // A click goes through the icon to the row.
    override package func hitTest(_ point: NSPoint) -> NSView? { nil }

    // Show the look. unit is the points of one layout unit. The flash restarts only when it
    // starts: a row whose flash goes on keeps its phase.
    package func show(_ look: SessionIconLook, unit: CGFloat) {
        let oldUnit = self.unit
        self.unit = unit
        guard look != self.look || unit != oldUnit else { return }
        self.look = look
        switch look.glyph {
        case .mark:
            glyphView.image = Icons.image(.hexagon)
            glyphView.contentTintColor = look.colour.nsColor
        case .terminal:
            glyphView.image = Icons.image(.squareTerminal)
            glyphView.contentTintColor = look.colour.nsColor
        case .app(let image):
            glyphView.image = image
            glyphView.contentTintColor = nil
        }
        brackets.isHidden = look.box == nil
        brackets.colour = look.box
        brackets.border = 2 * unit
        TooltipController.shared.attach(look.title, to: self, side: .top)
        // VoiceOver reads the icon as an image with the text of its tooltip.
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        setAccessibilityLabel(look.title)
        needsLayout = true
        updateFlash()
    }

    override package func layout() {
        super.layout()
        let side = min(bounds.width, bounds.height)
        let isApp: Bool
        if case .app = look?.glyph { isApp = true } else { isApp = false }
        // The icon of an app fills 7/8 of the side, and a glyph 2/3 (rounded to whole points).
        let glyph = (isApp ? side * 7 / 8 : side * 2 / 3).rounded()
        glyphView.frame = NSRect(
            x: (bounds.width - glyph) / 2, y: (bounds.height - glyph) / 2, width: glyph,
            height: glyph)
        brackets.frame = NSRect(
            x: (bounds.width - side) / 2, y: (bounds.height - side) / 2, width: side, height: side)
    }

    override package func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateFlash()
    }

    // The flash: the opacity of the brackets goes from 1 to 0.25 and back to 1 in 1 s, ease in
    // and out, with no end. It runs only while the look flashes.
    private func updateFlash() {
        brackets.wantsLayer = true
        guard let layer = brackets.layer else { return }
        let running = layer.animation(forKey: Self.flashKey) != nil
        let flashes = look?.flashes ?? false
        if flashes && !running {
            let flash = CAKeyframeAnimation(keyPath: "opacity")
            flash.values = [1.0, 0.25, 1.0]
            flash.keyTimes = [0, 0.5, 1]
            flash.timingFunctions = [
                CAMediaTimingFunction(name: .easeInEaseOut),
                CAMediaTimingFunction(name: .easeInEaseOut),
            ]
            flash.duration = 1
            flash.repeatCount = .infinity
            flash.isRemovedOnCompletion = false
            layer.add(flash, forKey: Self.flashKey)
        } else if !flashes && running {
            layer.removeAnimation(forKey: Self.flashKey)
        }
    }
}

// The four corner brackets of a box. Each bracket is an L of two bars at a corner: the arms are
// 30 % of the side, and the bars are border points thick.
@MainActor
package final class BracketsView: NSView {
    package var colour: TokenColour? {
        didSet { if colour != oldValue { needsDisplay = true } }
    }
    var border: CGFloat = 2 {
        didSet { if border != oldValue { needsDisplay = true } }
    }

    override package func hitTest(_ point: NSPoint) -> NSView? { nil }

    override package func draw(_ dirtyRect: NSRect) {
        guard let colour else { return }
        colour.nsColor.setFill()
        let side = min(bounds.width, bounds.height)
        let arm = side * 0.3
        let thickness = min(border, arm)
        let (minX, maxX) = (bounds.minX, bounds.maxX)
        let (minY, maxY) = (bounds.minY, bounds.maxY)
        let bars = [
            // The two bars of each corner: the side bar, then the top or bottom bar.
            NSRect(x: minX, y: minY, width: thickness, height: arm),
            NSRect(x: minX, y: minY, width: arm, height: thickness),
            NSRect(x: maxX - thickness, y: minY, width: thickness, height: arm),
            NSRect(x: maxX - arm, y: minY, width: arm, height: thickness),
            NSRect(x: minX, y: maxY - arm, width: thickness, height: arm),
            NSRect(x: minX, y: maxY - thickness, width: arm, height: thickness),
            NSRect(x: maxX - thickness, y: maxY - arm, width: thickness, height: arm),
            NSRect(x: maxX - arm, y: maxY - thickness, width: arm, height: thickness),
        ]
        bars.forEach { $0.fill() }
    }
}

// The icons of the apps that show the sessions (SessionHolder). Bifrost has the icon of the
// running app, so the development app shows its own icon. A terminal app has the icon of its
// bundle, with one lookup for each bundle: the first ask for an app starts one lookup on the
// blocking executor. Until the lookup ends, and for an app that has no icon, the ask gives nil and
// the row shows its glyph. The icons are observable: a table that asked during its observation
// shows the icon when the lookup ends.
@MainActor
@Observable
package final class SessionAppIcons {
    // The name of the app in the tooltip of the Bifrost icon.
    package static let bifrostName = "Bifrost"

    private var icons: [String: NSImage] = [:]
    // The bundles with a lookup that ran or runs.
    @ObservationIgnored private var asked: Set<String> = []
    @ObservationIgnored private let lookup: @Sendable (String) -> NSImage?
    @ObservationIgnored private let bifrost: @MainActor () -> NSImage?

    // lookup gives the icon of the app bundle at a path (TerminalApp.bundle), and bifrost gives
    // the icon of the running app. A test gives fakes, so no test asks Launch Services.
    package init(
        lookup: @escaping @Sendable (String) -> NSImage? = SessionAppIcons.bundleIcon,
        bifrost: @escaping @MainActor () -> NSImage? = {
            NSApplication.shared.applicationIconImage
        }
    ) {
        self.lookup = lookup
        self.bifrost = bifrost
    }

    // The icon of the app that shows a session, or nil: no app, or an icon that is not known.
    package func icon(_ holder: SessionHolder?) -> AppIcon? {
        switch holder {
        case nil: nil
        case .bifrost: bifrost().map { AppIcon(image: $0, name: Self.bifrostName) }
        case .terminal(let app): icon(app).map { AppIcon(image: $0, name: app.name) }
        }
    }

    // The icon of the terminal app, or nil while its lookup runs and for an app with no icon.
    package func icon(_ app: TerminalApp) -> NSImage? {
        if let icon = icons[app.bundle] { return icon }
        guard !asked.contains(app.bundle) else { return nil }
        asked.insert(app.bundle)
        let bundle = app.bundle
        let lookup = lookup
        Task { [weak self] in
            let icon = await BlockingExecutor.run { lookup(bundle) }
            if let icon { self?.icons[bundle] = icon }
        }
        return nil
    }

    // The icon of the app bundle at the path, for example /Applications/Warp.app. nil when the
    // path is not a folder that ends in ".app": the icon of a missing file is a generic icon.
    nonisolated package static func bundleIcon(_ path: String) -> NSImage? {
        var isFolder: ObjCBool = false
        guard path.hasSuffix(".app"),
            FileManager.default.fileExists(atPath: path, isDirectory: &isFolder),
            isFolder.boolValue
        else { return nil }
        return NSWorkspace.shared.icon(forFile: path)
    }
}
