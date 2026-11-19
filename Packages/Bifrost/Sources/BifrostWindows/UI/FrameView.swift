// One frame of the canvas in AppKit (docs/behaviour/windows.md, "Frames and panels"). The title bar
// is in TitleBarView.swift. The frame state (the z-order, the rect, the tabs, the lock) comes from
// the layout of WindowLayoutModel, not from the view.
//
// The look: the fill of the panel colour (only the background is translucent), a border of 1 unit,
// a top line of the accent colour, and the backdrop blur only while the frame covers a lower frame.
// The frame that has the focus (the top frame, until a press on the background of the canvas) has
// the darker focus fill, a stronger border, the full accent top line and a soft cyan glow above
// its top edge (EdgeGlow). The fill, the border and the glow change in 250 ms, ease-out. The body
// is a view that PanelBodies gives: an AppKit view, or an NSHostingView with a SwiftUI body. The
// body view moves between frames, but it is the same view.
//
// While the chat of the active panel listens (DictationGlow.swift), the top line is green with the
// border alpha of the look, a green shadow above the top edge takes the place of the cyan glow, the
// glow falls down from the top line, and the title bar shows the mic and the level bar. A display
// link smooths the level at each display frame, and the look follows the smoothed level at once,
// with no animation. The link stops when the level reaches its target, and a new target starts it
// again. A frame with no change of the look sets no layer.
import AppKit
import BifrostDictation
import BifrostLayout
import BifrostLook
import QuartzCore

// The target of the display link of the green look. The display link keeps its target, so the
// target keeps the frame view only weakly: the frame view can go, and its deinit stops the link.
@MainActor
private final class DisplayLinkTarget: NSObject {
    weak var view: FrameView?

    init(_ view: FrameView) {
        self.view = view
    }

    @objc func displayFrame(_ link: CADisplayLink) {
        view?.displayFrame(link)
    }
}

// A view that takes no pointer input: the fill, the border, the top line and the glow.
private class PassView: NSView {
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func isAccessibilityElement() -> Bool { false }
    override func accessibilityChildren() -> [Any]? { [] }
}

// The area of the body. It clips the body to the frame.
private final class BodyHostView: NSView {
    override var isFlipped: Bool { true }
    override func isAccessibilityElement() -> Bool { false }
}

// The pointer down on any part of a frame brings the frame to the front. The recognizer sees each
// press in the frame, also in a body that takes the press, and lets the press go on to the view.
@MainActor
private final class FocusPress: NSGestureRecognizer {
    private let pressed: () -> Void

    init(_ pressed: @escaping () -> Void) {
        self.pressed = pressed
        super.init(target: nil, action: nil)
        delaysPrimaryMouseButtonEvents = false
        delaysSecondaryMouseButtonEvents = false
        delaysOtherMouseButtonEvents = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    private func press() {
        pressed()
        state = .failed
    }

    override func mouseDown(with event: NSEvent) { press() }
    override func rightMouseDown(with event: NSEvent) { press() }
    override func otherMouseDown(with event: NSEvent) { press() }
}

// One value of the look of a frame: a colour of a layer, or the opacity of the glow.
@MainActor
private struct LookChange {
    @MainActor
    enum Value {
        case background(CGColor), border(CGColor), opacity(Float)
    }

    let layer: CALayer?
    let value: Value

    init(_ layer: CALayer?, _ value: Value) {
        self.layer = layer
        self.value = value
    }

    private var key: String {
        switch value {
        case .background: "backgroundColor"
        case .border: "borderColor"
        case .opacity: "opacity"
        }
    }

    // Set the value. When animated is true, the change takes the duration, ease-out, from the
    // value that shows now.
    func apply(animated: Bool, duration: Double) {
        guard let layer else { return }
        let shown = layer.presentation()?.value(forKey: key) ?? layer.value(forKey: key)
        let target: Any
        switch value {
        case .background(let colour):
            layer.backgroundColor = colour
            target = colour
        case .border(let colour):
            layer.borderColor = colour
            target = colour
        case .opacity(let opacity):
            layer.opacity = opacity
            target = opacity
        }
        guard animated else {
            layer.removeAnimation(forKey: key)
            return
        }
        let animation = CABasicAnimation(keyPath: key)
        animation.fromValue = shown
        animation.toValue = target
        animation.duration = duration
        animation.timingFunction = CAMediaTimingFunction(name: .easeOut)
        layer.add(animation, forKey: key)
    }
}

final class FrameView: NSView {
    // The sizes in layout units: the width of the border.
    static let border = 1.0
    // The resize handles: 6 thick at the edges, 12 by 12 at the corners.
    static let edgeSize = 6.0, cornerSize = 12.0
    // The glow above the top edge: the light starts glowInset in from each end of the edge, and
    // its softness (the standard deviation of its blur) is glowSoftness.
    static let glowInset = 6.0, glowSoftness = 6.0
    // The time of the change of the focus look.
    static let lookChange = 0.25

    let id: FrameID
    weak var canvas: CanvasView?
    let titleBar = TitleBarView()

    private let glow = PassView()
    private let focusGlow = EdgeGlow(colour: ThemeTokens.accentGlow)
    private(set) var blur: (any FrameBlur)?
    private var blurKind: BlurKind?
    private let fill = PassView()
    private let bodyHost = BodyHostView()
    private let edgeView = PassView()
    private let topLine = PassView()
    // The green look of dictation: the shadow above the top edge, the glow and the edge inside
    // the top border.
    private let dictationShadow = PassView()
    let dictationShadowGlow = DictationGlow.makeShadow()
    private let dictationGlow = PassView()
    // The glow and the edge lie in the frame inside its border, so the blur of the glow does not
    // show above the frame. The clip has the coordinates of the frame.
    private let dictationClip = CALayer()
    let dictationGlowLayer = DictationGlow.makeGlowLayer()
    let dictationEdgeLayer = CALayer()
    // The level that the chat of the active panel gives while it listens, or nil, and the level
    // that the look shows: the smoothed level.
    private(set) var dictationTarget: Double?
    private(set) var dictationLevel = 0.0
    private var displayLink: CADisplayLink?
    private var lastFrame: CFTimeInterval?
    // The look that the layers show, or nil when the layers must get the look again.
    private var shownLook: DictationLook?

    // The body view that the frame shows: the body of the active panel.
    private(set) var shownBody: NSView?
    private(set) var isTop = false
    private(set) var blurShows = false
    private(set) var locked = false
    // The title of the active panel, with its suffix after a space.
    private(set) var title = ""
    private var metrics = CanvasMetrics(interfaceScale: 100)
    private var transparency = 15

    init(id: FrameID, blur kind: BlurKind, metrics: CanvasMetrics, transparency: Int) {
        self.id = id
        self.metrics = metrics
        self.transparency = transparency
        super.init(frame: .zero)
        wantsLayer = true

        glow.layer = focusGlow.layer
        glow.wantsLayer = true
        focusGlow.layer.opacity = 0
        addSubview(glow)

        fill.wantsLayer = true
        addSubview(fill)
        bodyHost.clipsToBounds = true
        addSubview(bodyHost)
        titleBar.frameView = self
        addSubview(titleBar)
        edgeView.wantsLayer = true
        addSubview(edgeView)
        topLine.wantsLayer = true
        addSubview(topLine)
        dictationShadow.layer = dictationShadowGlow.layer
        dictationShadow.wantsLayer = true
        dictationShadow.isHidden = true
        addSubview(dictationShadow, positioned: .above, relativeTo: glow)
        let glowLayerRoot = CALayer()
        glowLayerRoot.isGeometryFlipped = true
        dictationClip.masksToBounds = true
        dictationClip.addSublayer(dictationGlowLayer)
        dictationClip.addSublayer(dictationEdgeLayer)
        glowLayerRoot.addSublayer(dictationClip)
        dictationGlow.layer = glowLayerRoot
        dictationGlow.wantsLayer = true
        dictationGlow.layerUsesCoreImageFilters = true
        dictationGlow.isHidden = true
        addSubview(dictationGlow)
        setBlurKind(kind)

        for button in titleBar.buttons { button.target = self }
        titleBar.menuButton.action = #selector(menuClicked)
        titleBar.minimiseButton.action = #selector(minimiseClicked)
        titleBar.closeButton.action = #selector(closeClicked)
        addGestureRecognizer(FocusPress { [weak self] in self?.focus() })

        titleBar.apply(metrics: metrics, transparency: transparency)
        paint(animated: false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    isolated deinit {
        displayLink?.invalidate()
    }

    override var isFlipped: Bool { true }

    // MARK: - State

    // Show the frame of the layout. The canvas sets the rect. suffixes gives the dim text after
    // the title of a panel.
    func update(
        _ frame: LayoutFrame, titles: [PanelID: String], suffixes: [PanelID: String] = [:],
        top: Bool, animated: Bool
    ) {
        if isHidden != frame.minimised { isHidden = frame.minimised }
        title = TitleText.joined(titles[frame.active] ?? frame.active.text, suffixes[frame.active])
        if locked != frame.locked {
            locked = frame.locked
            window?.invalidateCursorRects(for: self)
        }
        titleBar.update(
            panels: frame.panels, active: frame.active, titles: titles, suffixes: suffixes,
            locked: frame.locked)
        setTop(top, animated: animated)
    }

    // The scale, the panel transparency and the kind of the blur.
    func apply(metrics: CanvasMetrics, transparency: Int, blur kind: BlurKind) {
        let changed = metrics != self.metrics || transparency != self.transparency
        self.metrics = metrics
        self.transparency = transparency
        setBlurKind(kind)
        blur?.setScale(metrics.scale)
        guard changed else { return }
        titleBar.apply(metrics: metrics, transparency: transparency)
        paint(animated: false)
        needsLayout = true
    }

    // Show the body of the active panel. A body that another frame showed moves here, and it
    // stays in the window. The body that this frame showed before stays until
    // removeOtherBodies(), so that another frame can take it first.
    func show(body: NSView) {
        if body.superview !== bodyHost {
            body.frame = bodyHost.bounds
            body.autoresizingMask = [.width, .height]
            bodyHost.addSubview(body)
        }
        shownBody = body
    }

    // Remove each body that the frame does not show now: the body of a tab that is not active.
    // The body is not released.
    func removeOtherBodies() {
        for view in bodyHost.subviews where view !== shownBody { view.removeFromSuperview() }
    }

    // The focus state: the frame that has the focus is less transparent, has a stronger border, the
    // full accent top line and the glow. The change takes 250 ms, ease-out.
    private func setTop(_ top: Bool, animated: Bool) {
        guard top != isTop else { return }
        isTop = top
        // The level moves the look at once, so no change animates while the chat listens.
        paint(animated: animated && !isDictating)
    }

    private func paint(animated: Bool) {
        var accent = ThemeTokens.accent
        accent.a = isTop ? 1 : 0.35
        var strong = ThemeTokens.textStrong
        strong.a = 0.3
        let fillColour =
            isTop
            ? ThemeTokens.panelFocus(transparency: transparency)
            : ThemeTokens.panel(transparency: transparency)
        let changes = [
            LookChange(fill.layer, .background(fillColour.cgColor)),
            LookChange(
                edgeView.layer, .border(isTop ? strong.cgColor : ThemeTokens.panelEdge.cgColor)),
            LookChange(topLine.layer, .background(accent.cgColor)),
            LookChange(focusGlow.layer, .opacity(isTop ? 1 : 0)),
        ]
        // The new values have no implicit animation. A change of the focus adds one explicit
        // animation for each value, from the value that shows now.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for change in changes { change.apply(animated: animated, duration: Self.lookChange) }
        CATransaction.commit()
        if isDictating {
            // The paint changed the top line and the glow, so the look goes on them again.
            shownLook = nil
            applyDictationLook()
        }
    }

    // MARK: - Dictation

    // The smoothed level takes the target when it is nearer than this. The difference does not
    // show.
    static let dictationSettled = 0.001

    // True while the chat of the active panel listens.
    var isDictating: Bool { dictationTarget != nil }

    // The level of the chat of the active panel while it listens, or nil. The canvas gives it.
    func setDictation(_ level: Double?) {
        guard let level else {
            stopDictation()
            return
        }
        if isDictating {
            guard level != dictationTarget else { return }
            dictationTarget = level
            // The first frame after the pause only reads the time.
            if displayLink?.isPaused == true {
                lastFrame = nil
                displayLink?.isPaused = false
            }
            return
        }
        dictationTarget = level
        dictationLevel = 0
        lastFrame = nil
        shownLook = nil
        dictationShadow.isHidden = false
        dictationGlow.isHidden = false
        paint(animated: false)
        let target = DisplayLinkTarget(self)
        let link = displayLink(
            target: target, selector: #selector(DisplayLinkTarget.displayFrame(_:)))
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    // One step of the smoothing over the time of one display frame. The display link calls it.
    // Near the target, the level takes the target, and the link stops until the next target.
    func smoothDictation(seconds: Double) {
        guard let target = dictationTarget else { return }
        let level = DictationLook.smooth(dictationLevel, toward: target, seconds: seconds)
        if abs(target - level) < Self.dictationSettled {
            dictationLevel = target
            displayLink?.isPaused = true
        } else {
            dictationLevel = level
        }
        applyDictationLook()
    }

    fileprivate func displayFrame(_ link: CADisplayLink) {
        let now = link.timestamp
        defer { lastFrame = now }
        guard let last = lastFrame else { return }
        smoothDictation(seconds: now - last)
    }

    private func stopDictation() {
        guard isDictating else { return }
        dictationTarget = nil
        displayLink?.invalidate()
        displayLink = nil
        dictationShadow.isHidden = true
        dictationGlow.isHidden = true
        titleBar.showMeter(nil)
        paint(animated: false)
    }

    // The look of the smoothed level: the green top line and edge, the shadow, the glow and the
    // meter.
    private func applyDictationLook() {
        let look = DictationLook.of(level: dictationLevel)
        guard look != shownLook else { return }
        shownLook = look
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        topLine.layer?.backgroundColor = DictationGlow.green(look.borderAlpha)
        topLine.layer?.removeAnimation(forKey: "backgroundColor")
        focusGlow.layer.removeAnimation(forKey: "opacity")
        focusGlow.layer.opacity = 0
        dictationEdgeLayer.backgroundColor = DictationGlow.green(look.borderAlpha)
        DictationGlow.apply(
            look, glow: dictationGlowLayer, shadow: dictationShadowGlow, metrics: metrics)
        layoutDictation(look)
        CATransaction.commit()
        titleBar.showMeter(dictationLevel)
    }

    private func layoutDictation(_ look: DictationLook) {
        let width = bounds.width
        let border = metrics.points(Self.border)
        dictationShadow.frame = DictationGlow.layoutShadow(
            dictationShadowGlow, width: width, look: look, metrics: metrics)
        dictationGlow.frame = bounds
        let inside = bounds.insetBy(dx: border, dy: border)
        dictationClip.bounds = inside
        dictationClip.position = CGPoint(x: inside.midX, y: inside.midY)
        dictationGlowLayer.frame = DictationGlow.glowRect(
            width: width, border: border, look: look, metrics: metrics)
        dictationEdgeLayer.frame = DictationGlow.edgeRect(
            width: width, border: border, metrics: metrics)
    }

    // The blur shows only while this frame covers a lower frame that shows (Overlap).
    func setBlur(_ on: Bool) {
        guard on != blurShows else { return }
        blurShows = on
        blur?.view.isHidden = !on
    }

    // The run-time switch: a blur of the new kind replaces the blur view. The kind is the kind
    // that the settings ask for. The blur can be of another kind (the material in place of a
    // backdrop that is not there).
    private func setBlurKind(_ kind: BlurKind) {
        guard kind != blurKind else { return }
        blurKind = kind
        blur?.view.removeFromSuperview()
        blur = Blur.make(kind)
        guard let view = blur?.view else { return }
        blur?.setScale(metrics.scale)
        view.frame = bounds
        view.isHidden = !blurShows
        addSubview(view, positioned: .below, relativeTo: fill)
    }

    // MARK: - Layout

    // The parts in the layout pass: AppKit marks the frame for layout at a change of its size,
    // and a change of the scale marks it too.
    override func layout() {
        super.layout()
        let w = bounds.width
        let h = bounds.height
        let border = metrics.points(Self.border)
        let title = metrics.points(TitleBarView.height)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        glow.frame = focusGlow.layout(
            edgeWidth: w, inset: metrics.points(Self.glowInset),
            softness: metrics.points(Self.glowSoftness))
        blur?.view.frame = bounds
        fill.frame = bounds
        titleBar.frame = CGRect(
            x: border, y: border, width: max(0, w - border * 2), height: title)
        bodyHost.frame = CGRect(
            x: border, y: border + title, width: max(0, w - border * 2),
            height: max(0, h - title - border * 2))
        edgeView.frame = bounds
        edgeView.layer?.borderWidth = border
        topLine.frame = CGRect(x: 0, y: 0, width: w, height: border)
        if isDictating { layoutDictation(DictationLook.of(level: dictationLevel)) }
        CATransaction.commit()
    }

    // MARK: - Input

    // The resize handle at a point in the coordinates of the frame, or nil. A locked frame has no
    // handles.
    func edge(at p: CGPoint) -> FrameEdge? {
        guard !locked, bounds.contains(p) else { return nil }
        let w = bounds.width
        let h = bounds.height
        let corner = metrics.points(Self.cornerSize)
        let edge = metrics.points(Self.edgeSize)
        let left = p.x < corner
        let right = p.x >= w - corner
        let top = p.y < corner
        let bottom = p.y >= h - corner
        if top && left { return .nw }
        if top && right { return .ne }
        if bottom && left { return .sw }
        if bottom && right { return .se }
        if p.y < edge { return .n }
        if p.y >= h - edge { return .s }
        if p.x < edge { return .w }
        if p.x >= w - edge { return .e }
        return nil
    }

    // The buttons are above the resize handles, so a press near a corner hits the button. The
    // handles are above the title bar and the body.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden, let superview else { return nil }
        let p = convert(point, from: superview)
        guard bounds.contains(p) else { return nil }
        if let button = titleBar.button(at: titleBar.convert(p, from: self)) { return button }
        if edge(at: p) != nil { return self }
        let hit = super.hitTest(point)
        if let view = blur?.view, let hit, hit === view || hit.isDescendant(of: view) {
            return self
        }
        return hit ?? self
    }

    private func focus() {
        canvas?.focus(id)
    }

    override func mouseDown(with event: NSEvent) {
        focus()
        guard let canvas, let edge = edge(at: convert(event.locationInWindow, from: nil)) else {
            return
        }
        _ = canvas.beginDrag(id, mode: .resize(edge), event: event)
    }

    override func mouseDragged(with event: NSEvent) { canvas?.dragged(event) }
    override func mouseUp(with event: NSEvent) { canvas?.released(event) }

    override func rightMouseDown(with event: NSEvent) {
        focus()
        super.rightMouseDown(with: event)
    }

    override func resetCursorRects() {
        guard !locked else { return }
        let w = bounds.width
        let h = bounds.height
        let c = metrics.points(Self.cornerSize)
        let e = metrics.points(Self.edgeSize)
        let side = max(0, w - c * 2)
        let tall = max(0, h - c * 2)
        let rects: [(CGRect, NSCursor.FrameResizePosition)] = [
            (CGRect(x: c, y: 0, width: side, height: e), .top),
            (CGRect(x: c, y: h - e, width: side, height: e), .bottom),
            (CGRect(x: 0, y: c, width: e, height: tall), .left),
            (CGRect(x: w - e, y: c, width: e, height: tall), .right),
            (CGRect(x: 0, y: 0, width: c, height: c), .topLeft),
            (CGRect(x: w - c, y: 0, width: c, height: c), .topRight),
            (CGRect(x: 0, y: h - c, width: c, height: c), .bottomLeft),
            (CGRect(x: w - c, y: h - c, width: c, height: c), .bottomRight),
        ]
        for (rect, position) in rects {
            addCursorRect(rect, cursor: .frameResize(position: position, directions: .all))
        }
    }

    @objc private func menuClicked() {
        canvas?.showMenu(for: id, from: titleBar.menuButton)
    }

    @objc private func minimiseClicked() { canvas?.model.apply(.minimise(id)) }

    @objc private func closeClicked() { canvas?.closeActive(of: id) }

    // MARK: - Accessibility: a group with the title of the active panel

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .group }
    override func accessibilityLabel() -> String? { title }

    override func accessibilityChildren() -> [Any]? {
        titleBar.accessibilityParts + (shownBody.map { [$0] } ?? [])
    }

    override func accessibilityPerformRaise() -> Bool {
        focus()
        return true
    }

    override func accessibilityCustomActions() -> [NSAccessibilityCustomAction]? {
        let id = id
        return [
            NSAccessibilityCustomAction(name: "Minimise") { [weak self] in
                guard let self else { return false }
                self.canvas?.model.apply(.minimise(id))
                return true
            },
            NSAccessibilityCustomAction(name: "Close") { [weak self] in
                guard let self else { return false }
                self.canvas?.closeActive(of: id)
                return true
            },
            NSAccessibilityCustomAction(name: locked ? "Unlock" : "Lock") { [weak self] in
                guard let self else { return false }
                self.canvas?.model.apply(.lock(id, !self.locked))
                return true
            },
        ]
    }
}

#if DEBUG
// The parts of the look, for the tests.
extension FrameView {

    // The colours of the look: the fill, the border, the top line, and the opacity of the glow.
    var look: (fill: CGColor?, border: CGColor?, topLine: CGColor?, glow: Float) {
        (
            fill.layer?.backgroundColor, edgeView.layer?.borderColor,
            topLine.layer?.backgroundColor, glowLayer.opacity
        )
    }

    var fillLayer: CALayer { fill.layer ?? CALayer() }
    var glowLayer: CALayer { focusGlow.layer }
    var focusGlowStrip: CGRect { focusGlow.stripFrame }
    var blurView: NSView? { blur?.view }
    var glowFrame: CGRect { glow.frame }
    var dictationShadowFrame: CGRect { dictationShadow.frame }
    var dictationParts: [NSView] { [dictationShadow, dictationGlow] }
    // True while the display link calls the smoothing at each display frame.
    var displayLinkRuns: Bool { displayLink.map { !$0.isPaused } ?? false }
}
#endif
