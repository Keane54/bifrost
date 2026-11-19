import AppKit
import BifrostFoundation
import BifrostSessions
import BifrostTestSupport
import Foundation
import SwiftUI
import Testing

@testable import BifrostKeyboard
@testable import BifrostLayout
@testable import BifrostWindows

extension OverviewPanels {
    // The Overview bodies of a test, and their model. The model reads the store, the session list
    // and the selection of the test. The age timers use a manual clock.
    static func test(
        store: UIStateStore, sessions: SessionListModel, selection: SelectionModel,
        layout: WindowLayoutModel, filter: @escaping () -> WindowKeyFilter? = { nil }
    ) -> OverviewPanels {
        let model = OverviewModel(
            store: store, sessions: sessions, selection: selection, layout: layout,
            clock: ManualClock(), now: { Date(timeIntervalSince1970: 1_800_000_000) })
        return OverviewPanels(model: model, look: PanelLook(), filter: filter)
    }
}

// The canvas of the app with the Overview bodies, in a window of 1200 by 800 points that is never
// ordered front: a session list with the rows of the test, the Overview model with a UI store in
// a test folder, the side bar, the key commands and the key filter of the app. The layout model
// gives each change to the canvas, as the shell does. The Interface scale is 100, so one layout
// unit is one point.
@MainActor
final class OverviewCanvas {
    let folder: TemporaryFolder
    let source = FakeRowSource()
    let sessions: SessionListModel
    let selection: SelectionModel
    let layout = WindowLayoutModel(layout: WindowLayout(bounds: LayoutSize(w: 1, h: 1)))
    let store: UIStateStore
    let panels: OverviewPanels
    let canvas: CanvasView
    let window: BifrostWindow
    let sideBar: SideBarModel
    let commands: KeyCommands
    let filter: WindowKeyFilter

    init(rows: [SessionRow]) async throws {
        UITestApp.prepare()
        folder = try TemporaryFolder()
        store = await UIStateStore.open(
            file: folder.url.appending(path: "ui-state.json"), clock: ManualClock(),
            log: Recorder<StoreEvent>())
        sessions = SessionListModel.reading(source)
        selection = SelectionModel(list: sessions)
        weak var keyFilter: WindowKeyFilter?
        panels = OverviewPanels.test(
            store: store, sessions: sessions, selection: selection, layout: layout,
            filter: { keyFilter })
        let sessions = sessions
        let bodies = PanelBodiesHub(
            parts: [panels], look: PanelLook(), rows: { sessions.rows })
        canvas = CanvasView(model: layout, bodies: bodies, settings: CanvasSettings())
        canvas.overviews = panels.model
        window = SnapshotBifrostWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800), styleMask: [.titled],
            backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.actsAsKey = true
        sideBar = SideBarModel(layout: layout, store: store)
        commands = KeyCommands(
            layout: layout, sideBar: sideBar, selection: selection, overviews: panels,
            openChat: { [layout] in layout.openChat($0) }, menu: { _ in })
        filter = WindowKeyFilter(
            window: window, commands: commands, selection: selection,
            keys: KeyMap([.dictation: .off]))
        keyFilter = filter
        layout.onChange = { [canvas] change in canvas.modelChanged(change) }
        canvas.frame = NSRect(x: 0, y: 0, width: 1200, height: 800)
        window.contentView = canvas
        source.apply(rows: rows, error: nil)
    }

    deinit { folder.remove() }

    var model: OverviewModel { panels.model }

    // Open a panel. The result is its frame.
    @discardableResult
    func open(_ raw: String) -> FrameID {
        layout.apply(.open(panel(raw)))
        guard let frame = layout.layout.frame(of: panel(raw)) else {
            preconditionFailure("no frame for \(raw)")
        }
        return frame.id
    }

    func run(_ id: String) {
        commands.run(keySlot(id))
    }

    // A key down and its key up through the window and its key filter.
    func send(_ id: String, _ mods: Set<USKeyboard.Mod> = []) {
        for down in [true, false] {
            guard
                let event = USKeyboard.keyEvent(
                    down: down, id: id, mods: mods, isRepeat: false, window: window)
            else { continue }
            window.sendEvent(event)
        }
    }

    // The rows view of the Overview with the number.
    func rows(_ number: Int) -> OverviewRowsView? {
        (panels.body(for: .overview(number)) as? OverviewPanel)?.rows
    }

    // The tab bar of the Overview with the number.
    func tabBar(_ number: Int) -> OverviewTabsView? {
        (panels.body(for: .overview(number)) as? OverviewPanel)?.tabBar.rootView
    }

    func frameView(_ id: FrameID) -> FrameView? { canvas.frameView(id) }

    func close() { window.close() }
}
