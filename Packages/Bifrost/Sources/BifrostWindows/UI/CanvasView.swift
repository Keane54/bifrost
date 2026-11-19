// The panel area of the window in AppKit (docs/behaviour/windows.md): the frames in z-order, the
// move, the resize, the snap marks, the drop outline, the blur rule (Overlap) and the minimise to
// the side bar. The layout of WindowLayoutModel holds the z-order and the drag state, and FrameDrag
// has the rules of the drag. The side bar is SwiftUI (SideBarView).
//
// The canvas gives the layout its bounds: the size of the view in layout units. It shows the shown
// rects of the layout at the points of the Interface scale. A drag moves only the view of the
// dragged frame, with no implicit animation. The layout gets the rect only at the end.
//
// The owner of the model gives each change of the model to modelChanged(_:), before the other parts
// get it (the shell in the app, the canvas fixture in the tests). So the bodies are in their frames
// before the chats get the layout.
//
// The chats give the voice level of each chat that listens (setDictation). A frame shows the green
// look while the chat of its active panel listens.
//
// The canvas follows the titles and the title suffixes of the panels in the frames with
// Observations: a new name of a session row or of the tab set of an Overview shows in its tab and
// its title bar at once.
//
// The frame that has the focus (WindowLayout.focusedFrame) shows the focus look. A press on the
// background of the canvas takes the focus from all panels (pressed(_:)).
//
// From the start of a drag or a resize to its end, the window does not update its cursor rects (row
// W15 of the windows port). Each step of a drag moves the frame view, and a move marks the cursor
// rects as not valid. AppKit then makes all cursor rects of the window again at each display cycle,
// on the main thread. Without this work, a drag of the bench missed no frames
// (phase-3-performance.md, Step 4). The cursor of the press stays during the drag. The end of the
// drag, a cancel and the loss of the key state of the window turn the cursor rects on again. The
// owner of the window tells the canvas of the loss of the key state (windowResignedKey).
import AppKit
import BifrostLayout
import BifrostLook
import BifrostSettings
import Observation
import QuartzCore

// The settings that the canvas uses.
nonisolated public struct CanvasSettings: Sendable, Equatable {
    // The snap distance of a drag, in layout units.
    package var snapDistance: Int
    // The panel transparency in percent.
    package var panelTransparency: Int
    // The Interface scale in percent.
    package var interfaceScale: Int
    // The kind of the blur behind a frame that covers a lower frame.
    package var blur: BlurKind

    public init(
        snapDistance: Int = 8, panelTransparency: Int = 15, interfaceScale: Int = 100,
        blur: BlurKind = .backdrop
    ) {
        self.snapDistance = snapDistance
        self.panelTransparency = panelTransparency
        self.interfaceScale = interfaceScale
        self.blur = blur
    }

    // The values of the settings. No setting holds the blur kind (user decision).
    public init(_ settings: Settings, blur: BlurKind) {
        self.init(
            snapDistance: settings.snapDistance, panelTransparency: settings.panelTransparency,
            interfaceScale: settings.interfaceScale, blur: blur)
    }
}

public final class CanvasView: NSView {
    let model: WindowLayoutModel
    private let bodies: any PanelBodies
    package private(set) var settings: CanvasSettings
    package private(set) var metrics: CanvasMetrics

    private var frameViews: [FrameID: FrameView] = [:]
    // The body views that the canvas asked for, by panel. A panel in no frame gives its body back.
    private var bodyViews: [PanelID: NSView] = [:]
    // The marks and the outline are above all frames.
    let marks = SnapMarksView()
    let outline = DropOutlineView()
    #if DEBUG
    // The number of full updates of the frames, for the tests. A drag step makes none.
    private(set) var syncCount = 0
    #endif
    // The Bifrost menu of the window: the Panel menu of each frame shows on it. Another part of
    // the window can use it too, so one menu shows at a time.
    package let bifrostMenu: BifrostMenu
    // The look of the menu: the Interface scale of the canvas.
    private let menuLook: PanelLook
    // The model of the Overviews, for the Overview items of the Panel menu and the names of the
    // tab sets in the titles. With no model, the Panel menu of an Overview has only Lock. The app
    // sets it. The tab menu of each Overview shows on the Bifrost menu of the canvas.
    package var overviews: OverviewModel? {
        didSet { overviews?.menu = bifrostMenu }
    }
    // The overlay of the dialogs (DialogHost.view): above the frames and the marks, over the
    // whole canvas. nil until the app sets it.
    package var dialogLayer: NSView? {
        didSet {
            oldValue?.removeFromSuperview()
            guard let dialogLayer else { return }
            dialogLayer.frame = bounds
            dialogLayer.autoresizingMask = [.width, .height]
            addSubview(dialogLayer)
        }
    }
    // The task that follows the titles and the title suffixes of the panels in the frames.
    private var labelsFollow: Task<Void, Never>?
    // The title and the title suffix of each panel of the frames that show, as the frames show
    // them.
    private var shownLabels: [PanelID: PanelLabel] = [:]
    // The voice level of each chat panel that listens.
    private var dictation: [PanelID: Double] = [:]
    // The window whose cursor rects a drag turned off.
    private weak var heldCursorRects: NSWindow?

    public init(model: WindowLayoutModel, bodies: any PanelBodies, settings: CanvasSettings) {
        self.model = model
        self.bodies = bodies
        self.settings = settings
        metrics = CanvasMetrics(interfaceScale: settings.interfaceScale)
        let look = PanelLook()
        look.interfaceScale = settings.interfaceScale
        menuLook = look
        bifrostMenu = BifrostMenu(look: look, tooltips: .shared, clock: ContinuousClock())
        super.init(frame: .zero)
        wantsLayer = true
        // The area clips its content: a glow above a frame at the top edge does not draw outside
        // the canvas.
        clipsToBounds = true
        model.snapDistance = Double(settings.snapDistance)
        addSubview(marks)
        addSubview(outline)
        sync(animated: false)
        followLabels()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    isolated deinit {
        releaseCursorRects()
        labelsFollow?.cancel()
    }

    // Show a change of the model: a new layout, or the start or the end of a drag.
    public func modelChanged(_ change: WindowLayoutModel.Change) {
        switch change {
        case .layout: sync(animated: true)
        case .dragStarted: holdCursorRects()
        case .dragEnded: dragEnded()
        }
    }

    override public var isFlipped: Bool { true }

    // Apply new settings: the snap of the next drag, the transparency, the scale and the blur.
    public func apply(_ settings: CanvasSettings) {
        self.settings = settings
        metrics = CanvasMetrics(interfaceScale: settings.interfaceScale)
        menuLook.interfaceScale = settings.interfaceScale
        model.snapDistance = Double(settings.snapDistance)
        for view in frameViews.values {
            view.apply(
                metrics: metrics, transparency: settings.panelTransparency, blur: settings.blur)
        }
        updateBounds()
        sync(animated: false)
    }

    // The view of a frame, or nil when the layout has no such frame.
    func frameView(_ id: FrameID) -> FrameView? { frameViews[id] }

    // The voice level of a chat panel that listens, or nil when it does not listen. The frame
    // whose active panel it is shows the green look.
    public func setDictation(_ panel: PanelID, level: Double?) {
        dictation[panel] = level
        applyDictation()
    }

    private func applyDictation() {
        for frame in model.layout.shownFrames {
            frameViews[frame.id]?.setDictation(dictation[frame.active])
        }
    }

    // Ask the bodies again for the titles and the title suffixes of the panels, and show them in
    // the tabs and the title bars. The canvas does this itself at each change of an observed
    // value that a title reads (followLabels()). A test with bodies that are not observable
    // calls it.
    public func reloadTitles() {
        let layout = model.layout
        let shown = layout.shownFrames
        shownLabels = currentLabels(shown)
        let titles = shownLabels.mapValues(\.title)
        let suffixes = shownLabels.compactMapValues(\.suffix)
        let focused = layout.focusedFrame?.id
        for frame in shown {
            frameViews[frame.id]?.update(
                frame, titles: titles, suffixes: suffixes, top: frame.id == focused,
                animated: false)
        }
    }

    // Follow the titles and the title suffixes of the panels of the frames that show: the name
    // of a session row, the name of the tab set of an Overview. A change shows at once. A change
    // of the layout already shows the labels of now, so only a label that differs from the shown
    // label reloads the titles.
    private func followLabels() {
        let changes = Observations { [weak self] in
            self.map { $0.currentLabels($0.model.layout.shownFrames) }
        }
        labelsFollow = Task { [weak self] in
            for await labels in changes {
                guard let self, let labels else { return }
                if labels != shownLabels { reloadTitles() }
            }
        }
    }

    // The title and the title suffix of each panel of the frames.
    private func currentLabels(_ frames: [LayoutFrame]) -> [PanelID: PanelLabel] {
        var labels: [PanelID: PanelLabel] = [:]
        for panel in frames.flatMap(\.panels) {
            labels[panel] = PanelLabel(
                title: bodies.title(for: panel), suffix: bodies.titleSuffix(for: panel))
        }
        return labels
    }

    // MARK: - The bounds

    override public func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        marks.frame = bounds
        dialogLayer?.frame = bounds
        updateBounds()
    }

    // The layout gets the size of the area in whole layout units. In an area with no size, each
    // frame would show with a size of 0, so the canvas ignores such a size.
    private func updateBounds() {
        let size = metrics.units(bounds.size)
        guard size.w > 0, size.h > 0 else { return }
        model.apply(.bounds(size))
    }

    // MARK: - The frames

    // Show the layout: a view for each frame, in z-order, with its shown rect (or the live rect
    // of a drag), its look, its blur and the body of its active panel. A panel that left the
    // last frame gives its body back.
    //
    // A body that moves to another frame never leaves the window, so a terminal keeps its state
    // and the keyboard focus. So the views of new frames go into the canvas before the bodies
    // move (a tear-out), a frame removes the body that it does not show only after each body
    // moved, and the views of frames that are gone go last (a stack).
    private func sync(animated: Bool) {
        #if DEBUG
        syncCount += 1
        #endif
        let layout = model.layout
        let shown = layout.shownFrames
        let focus = focusInBody()
        for frame in shown where frameViews[frame.id] == nil {
            addSubview(makeView(frame.id), positioned: .below, relativeTo: marks)
        }
        let focused = layout.focusedFrame?.id
        var ordered: [NSView] = []
        shownLabels = currentLabels(shown)
        let titles = shownLabels.mapValues(\.title)
        let suffixes = shownLabels.compactMapValues(\.suffix)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for frame in shown {
            guard let view = frameViews[frame.id] else { continue }
            view.update(
                frame, titles: titles, suffixes: suffixes, top: frame.id == focused,
                animated: animated)
            let rect = model.drag.flatMap { $0.frame == frame.id ? $0.live : nil } ?? frame.rect
            let target = aligned(rect)
            if view.frame != target { view.frame = target }
            view.show(body: body(for: frame.active))
            ordered.append(view)
        }
        CATransaction.commit()
        // Each body moved to its frame. Now the frames remove the bodies that they do not show.
        for view in frameViews.values { view.removeOtherBodies() }
        let ids = Set(shown.map(\.id))
        let gone = frameViews.filter { !ids.contains($0.key) }
        for view in gone.values {
            // The display link of the look keeps a view: the look stops first.
            view.setDictation(nil)
            view.removeFromSuperview()
            frameViews[view.id] = nil
        }
        // Reorder the subviews without a remove: the setter keeps the views that stay.
        let wanted = ordered + [marks, outline] + (dialogLayer.map { [$0] } ?? [])
        if subviews != wanted { subviews = wanted }
        updateBlur()
        applyDictation()
        // The frames that changed lay out now, in one pass. So each body has the size of its
        // frame before the chats get the layout.
        layoutSubtreeIfNeeded()
        releaseBodies(of: layout)
        // A body that moved keeps the keyboard focus. A body that left the window (a tab that is
        // not active now, a closed panel) or that is hidden (a minimised frame) loses it.
        if let focus, let window, focus.window === window, !focus.isHiddenOrHasHiddenAncestor,
            window.firstResponder !== focus
        {
            window.makeFirstResponder(focus)
        }
    }

    // The first responder when it is a body or a view in a body, else nil.
    private func focusInBody() -> NSView? {
        guard let responder = window?.firstResponder as? NSView else { return nil }
        let inBody = bodyViews.values.contains { responder.isDescendant(of: $0) }
        return inBody ? responder : nil
    }

    // A rect in layout units as a rect in points on the device pixels. At a scale such as 90 %,
    // one unit is not a whole number of pixels, and an edge between two pixels looks soft.
    func aligned(_ rect: LayoutRect) -> CGRect {
        backingAlignedRect(metrics.points(rect), options: .alignAllEdgesNearest)
    }

    private func makeView(_ id: FrameID) -> FrameView {
        let view = FrameView(
            id: id, blur: settings.blur, metrics: metrics,
            transparency: settings.panelTransparency)
        view.canvas = self
        frameViews[id] = view
        return view
    }

    // The bodies of the panels gave new bodies for these panels, for example for the panels of
    // a part that came after the start (PanelBodiesHub.add). The canvas drops its old view of
    // each panel and shows the new body. The old views are not bodies of the panels now, so the
    // bodies get no release.
    package func reloadBodies(_ panels: [PanelID]) {
        var dropped = false
        for panel in panels {
            guard let view = bodyViews.removeValue(forKey: panel) else { continue }
            view.removeFromSuperview()
            dropped = true
        }
        if dropped { sync(animated: false) }
    }

    private func body(for panel: PanelID) -> NSView {
        if let view = bodyViews[panel] { return view }
        let view = bodies.body(for: panel)
        bodyViews[panel] = view
        return view
    }

    private func releaseBodies(of layout: WindowLayout) {
        let panels = Set(layout.frames.flatMap(\.panels))
        let gone = bodyViews.filter { !panels.contains($0.key) }
        for (panel, view) in gone.sorted(by: { $0.key < $1.key }) {
            view.removeFromSuperview()
            bodyViews[panel] = nil
            bodies.releaseBody(for: panel)
        }
    }

    // Only a frame over a lower frame that shows gets the blur (Overlap). During a drag, the live
    // rect of the dragged frame counts.
    private func updateBlur() {
        let live = model.drag.flatMap { drag in
            drag.live.map { LiveRect(frame: drag.frame, rect: $0) }
        }
        let blurred = blurredFrames(model.layout.shownFrames, live: live)
        for view in frameViews.values {
            view.setBlur(blurred.contains(view.id))
        }
    }

    // MARK: - The drag

    // The point of an event in layout units, in the coordinates of the canvas.
    private func point(_ event: NSEvent) -> LayoutPoint {
        let p = convert(event.locationInWindow, from: nil)
        let percent = Double(metrics.interfaceScale)
        return LayoutPoint(x: Double(p.x) * 100 / percent, y: Double(p.y) * 100 / percent)
    }

    // A press on a frame brings it to the front.
    func focus(_ id: FrameID) {
        model.apply(.focus(id))
    }

    func beginDrag(_ id: FrameID, mode: DragMode, event: NSEvent) -> Bool {
        model.beginDrag(frame: id, mode: mode, at: point(event))
    }

    func dragged(_ event: NSEvent) {
        moveDrag(to: point(event))
    }

    // One step of a drag at a point in layout units, in the coordinates of the canvas. A pointer
    // step and a step of the debug bench use it.
    package func moveDrag(to point: LayoutPoint) {
        guard model.drag != nil else { return }
        model.moveDrag(to: point)
        drawDrag()
    }

    func released(_ event: NSEvent) {
        guard model.drag != nil else { return }
        model.endDrag(at: point(event))
    }

    // One step of the drag: only the dragged frame moves. The marks and the outline show the
    // result of a release here.
    private func drawDrag() {
        guard let drag = model.drag else { return }
        let layout = model.layout
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if let view = frameViews[drag.frame],
            let frame = layout.shownFrames.first(where: { $0.id == drag.frame })
        {
            let target = aligned(drag.live ?? frame.rect)
            if view.frame != target { view.frame = target }
        }
        marks.show(drag.marks, bounds: layout.bounds, metrics: metrics)
        let bar = drag.dropTarget.flatMap { id in
            layout.shownFrames.first { $0.id == id }.map { Geometry.titleBar($0.rect) }
        }
        outline.show(bar.map(aligned), metrics: metrics)
        CATransaction.commit()
        updateBlur()
    }

    // At the end of a drag, the cursor rects of the window go on again, the marks and the
    // outline go, and each frame shows its layout rect.
    private func dragEnded() {
        releaseCursorRects()
        marks.show([], bounds: model.layout.bounds, metrics: metrics)
        outline.show(nil, metrics: metrics)
        sync(animated: true)
    }

    // Turn off the cursor rects of the window until the end of the drag, or until the window
    // stops being the key window.
    private func holdCursorRects() {
        guard heldCursorRects == nil, let window else { return }
        window.disableCursorRects()
        heldCursorRects = window
    }

    // The window stopped being the key window: its cursor rects go on again. The drag goes on.
    public func windowResignedKey() {
        releaseCursorRects()
    }

    // Turn on the cursor rects again, and make them again for the new frames.
    private func releaseCursorRects() {
        guard let window = heldCursorRects else { return }
        heldCursorRects = nil
        window.enableCursorRects()
        window.resetCursorRects()
    }

    // MARK: - A press on the background

    // A press of each mouse button on the canvas. The canvas gets a press on its background, and
    // also a press on a frame that a view gives to the next responder (for example a right press
    // on a frame). The press then goes on up the responder chain.
    override public func mouseDown(with event: NSEvent) {
        pressed(event)
        super.mouseDown(with: event)
    }

    override public func rightMouseDown(with event: NSEvent) {
        pressed(event)
        super.rightMouseDown(with: event)
    }

    override public func otherMouseDown(with event: NSEvent) {
        pressed(event)
        super.otherMouseDown(with: event)
    }

    // A click on the background also acts when the window is not the key window, for example the
    // click that brings Bifrost to the front from another app. AppKit asks only the hit view, so
    // a click on a frame keeps the rule of macOS: that click only makes the window key.
    override public func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        event.map(isOnBackground) ?? false
    }

    // A press on the background takes the key focus from all panels (docs/behaviour/windows.md,
    // "Frames and panels"). The window becomes the first responder, so no chat terminal and no
    // field of a panel gets a later key, and the keys of the window act (for example Esc opens
    // Settings). Then no frame has the focus, so the top frame loses the focus look and no chat is
    // focused.
    private func pressed(_ event: NSEvent) {
        guard let window, isOnBackground(event) else { return }
        // A dialog that opens shows its overlay, but SwiftUI draws the backdrop only at its next
        // update. A press that comes before that update can have the canvas as its hit view. Such
        // a press must not take the focus from the frames: at the close, the dialog gives the old
        // first responder (for example a chat terminal) the focus again.
        if (window as? BifrostWindow)?.dialogIsOpen == true { return }
        // A field that does not end its edit keeps the focus, and then its frame keeps it too.
        guard window.makeFirstResponder(nil) else { return }
        model.apply(.dropFocus)
    }

    // True when the hit view of the event is the canvas itself. A press on a frame is not on the
    // background. While a dialog shows, its overlay covers the canvas, so no press is on the
    // background. A press outside a Bifrost menu closes the menu first (BifrostMenu): the press
    // outside the Panel menu then goes on and can be on the background, and the press outside a
    // context menu stops at the close.
    private func isOnBackground(_ event: NSEvent) -> Bool {
        guard let superview else { return false }
        return hitTest(superview.convert(event.locationInWindow, from: nil)) === self
    }

    // MARK: - The title bar buttons

    // The Panel menu of the frame, below its menu button. The menu of an Overview also has the
    // Overview items.
    func showMenu(for id: FrameID, from button: NSView) {
        guard let frame = model.layout.frames.first(where: { $0.id == id }) else { return }
        let layout = model
        FrameMenu.show(
            on: bifrostMenu, below: button,
            locked: { layout.layout.frames.first { $0.id == id }?.locked ?? false },
            setLocked: { layout.apply(.lock(id, $0)) }, overview: overviewItems(frame.active))
    }

    // The Overview items of the Panel menu of a frame whose active panel is an Overview, else nil.
    private func overviewItems(_ panel: PanelID) -> OverviewMenuItems? {
        guard case .overview(let number) = panel, let overviews else { return nil }
        let layout = model
        return OverviewMenuItems(
            openSettings: { layout.apply(.open(.overviewSettings(number))) },
            setName: { overviews.config(panel).name },
            rename: { overviews.update(panel, .rename($0)) })
    }

    // Close closes the active panel of the frame.
    func closeActive(of id: FrameID) {
        guard let frame = model.layout.frames.first(where: { $0.id == id }) else { return }
        model.apply(.close(frame.active))
    }

    // MARK: - Accessibility: a group of the frames that show

    override public func isAccessibilityElement() -> Bool { true }
    override public func accessibilityRole() -> NSAccessibility.Role? { .group }
    override public func accessibilityLabel() -> String? { "Panels" }

    override public func accessibilityChildren() -> [Any]? {
        subviews.compactMap { $0 as? FrameView }.filter { !$0.isHidden }
    }
}

// The title and the dim title suffix of a panel, as its tab and its frame show them.
private struct PanelLabel: Equatable {
    var title: String
    var suffix: String?
}
