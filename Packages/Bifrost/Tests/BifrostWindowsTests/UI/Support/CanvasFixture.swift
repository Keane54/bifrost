import AppKit
import BifrostTestSupport
import Observation

@testable import BifrostLayout
@testable import BifrostWindows

// The helpers panel(_:) and rect(_:_:_:_:) are in BifrostTestSupport (LayoutValues.swift).

// A body that takes each press, as a terminal or a SwiftUI control does: the press does not go
// up the responder chain to the frame. It can be the first responder. It counts each time it
// leaves its window.
final class FakeBody: NSView {
    private(set) var leftWindow = 0

    override var acceptsFirstResponder: Bool { true }
    override func mouseDown(with event: NSEvent) {}
    override func rightMouseDown(with event: NSEvent) {}

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        if newWindow == nil && window != nil { leftWindow += 1 }
    }
}

// The bodies of the canvas tests: a FakeBody for each panel. The test reads how many bodies the
// canvas made and released. The titles are observable, as the titles of the app are.
@MainActor
@Observable
final class FakeBodies: PanelBodies {
    @ObservationIgnored private(set) var views: [PanelID: FakeBody] = [:]
    @ObservationIgnored private(set) var made: [PanelID: Int] = [:]
    @ObservationIgnored private(set) var released: [PanelID] = []
    var titles: [PanelID: String] = [:]

    func body(for panel: PanelID) -> NSView {
        if let view = views[panel] { return view }
        let view = FakeBody()
        views[panel] = view
        made[panel, default: 0] += 1
        return view
    }

    func title(for panel: PanelID) -> String { titles[panel] ?? panel.text }

    func releaseBody(for panel: PanelID) {
        released.append(panel)
        views[panel] = nil
    }

    // The next body of the panel is a new body, with no release of the old one, as when a part
    // came after the start (PanelBodiesHub.add).
    func replaceBody(of panel: PanelID) {
        views[panel] = nil
    }
}

// A canvas of 1200 by 800 points in a window that is never ordered front. At the scale 100, one
// layout unit is one point. The fixture gives each change of the model to the canvas, then to
// the UI store when a test sets one, as the shell does.
@MainActor
final class CanvasFixture {
    let window: NSWindow
    let model: WindowLayoutModel
    let bodies = FakeBodies()
    let canvas: CanvasView
    let mouse: MouseDriver
    // The UI store that keeps the layout, or nil.
    var store: UIStateStore?

    // bifrostWindow makes the window a BifrostWindow, which gives each key down to an open Bifrost
    // menu, as the main window does.
    init(
        size: CGSize = CGSize(width: 1200, height: 800),
        settings: CanvasSettings = CanvasSettings(), bifrostWindow: Bool = false
    ) {
        UITestApp.prepare()
        let rect = NSRect(origin: .zero, size: size)
        window =
            bifrostWindow
            ? BifrostWindow(
                contentRect: rect, styleMask: [.borderless], backing: .buffered, defer: false)
            : NSWindow(
                contentRect: rect, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        model = WindowLayoutModel(layout: WindowLayout(bounds: LayoutSize(w: 1, h: 1)))
        bodies.titles = [
            panel("settings"): "Settings", panel("watchlist"): "Watchlist",
            panel("event-log"): "Event log", panel("reviews"): "Reviews",
        ]
        canvas = CanvasView(model: model, bodies: bodies, settings: settings)
        // The Panel menu stays inside a screen of the size of the window.
        canvas.bifrostMenu.visibleFrame = { _ in MenuDriver.screen }
        mouse = MouseDriver(window: window)
        model.onChange = { [weak self] change in self?.changed(change) }
        canvas.frame = NSRect(origin: .zero, size: size)
        window.contentView = canvas
    }

    private func changed(_ change: WindowLayoutModel.Change) {
        canvas.modelChanged(change)
        if let store { model.save(change, to: store) }
    }

    // Open a panel in a new frame at a rect. The result is the frame.
    @discardableResult
    func open(_ raw: String, at r: LayoutRect) -> FrameID {
        model.apply(.open(panel(raw)))
        guard let frame = model.layout.frame(of: panel(raw)) else {
            preconditionFailure("no frame for \(raw)")
        }
        model.apply(.setRect(frame.id, r))
        return frame.id
    }

    func frame(_ id: FrameID) -> LayoutFrame? { model.layout.frames.first { $0.id == id } }

    func view(_ id: FrameID) -> FrameView {
        guard let view = canvas.frameView(id) else { preconditionFailure("no view for \(id)") }
        return view
    }

    // The centre of a view in the coordinates of the canvas.
    func centre(of view: NSView) -> CGPoint {
        let r = canvas.convert(view.bounds, from: view)
        return CGPoint(x: r.midX, y: r.midY)
    }

    func close() { window.close() }
}
