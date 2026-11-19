import AppKit
import BifrostFoundation
import BifrostKeyboard
import BifrostLook
import BifrostSessions
import BifrostTestSupport
import Testing

@testable import BifrostLayout
@testable import BifrostSettings
@testable import BifrostWindows

// The panel bodies of the canvas (PanelBodiesHub): each part gives its own panels
// (the chat terminals, the Overview panels), and each other panel shows the text of a later
// build. The titles come from the rows, and a part gives the suffix of the title of its panel.
@Suite("panel bodies hub", .serialized, .tags(.window))
@MainActor
struct PanelBodiesHubTests {
    // A part that gives a body and a title suffix only for the settings panel, and records each
    // release.
    @MainActor
    private final class SettingsPart: PanelBodiesPart {
        var bodies: [PanelID: NSView] = [:]
        var released: [PanelID] = []

        func titleSuffix(for panel: PanelID) -> String? {
            panel.kind == .settings ? "(mine)" : nil
        }

        func body(for panel: PanelID) -> NSView? {
            guard panel.kind == .settings else { return nil }
            if let view = bodies[panel] { return view }
            let view = NSView()
            bodies[panel] = view
            return view
        }

        func releaseBody(for panel: PanelID) {
            released.append(panel)
            bodies[panel] = nil
        }
    }

    @Test func aPanelOfALaterPhaseShowsTheLaterText() {
        UITestApp.prepare()
        let hub = PanelBodiesHub(parts: [], look: PanelLook(), rows: { [] })
        let body = hub.body(for: panel("event-log"))
        #expect(body is LaterPanelHost)
        #expect(LaterPanel.text == "This panel comes in a later build of Bifrost Dev.")
        // The same view until the release. Then a new view.
        #expect(hub.body(for: panel("event-log")) === body)
        hub.releaseBody(for: panel("event-log"))
        #expect(hub.body(for: panel("event-log")) !== body)
        // The later text is not focusable either.
        #expect(!body.acceptsFirstResponder)
    }

    // The first part that gives a body wins. Each part gets each release. A part gives the title
    // suffix of its panels, and a panel of no part has none.
    @Test func eachPartGivesItsOwnPanels() {
        UITestApp.prepare()
        let part = SettingsPart()
        let hub = PanelBodiesHub(parts: [part], look: PanelLook(), rows: { [] })
        #expect(hub.titleSuffix(for: panel("settings")) == "(mine)")
        #expect(hub.titleSuffix(for: panel("watchlist")) == nil)
        let settings = hub.body(for: panel("settings"))
        #expect(settings === part.bodies[panel("settings")])
        #expect(hub.body(for: panel("watchlist")) is LaterPanelHost)
        hub.releaseBody(for: panel("settings"))
        hub.releaseBody(for: panel("watchlist"))
        #expect(part.released == [panel("settings"), panel("watchlist")])
    }

    // A panel that waits for its part has an empty body, not the later text. The part that
    // comes after the start takes each of its panels that had a body of the hub, and the result
    // names them. The other panels keep their bodies.
    @Test func aPartThatComesLaterTakesItsPanels() {
        UITestApp.prepare()
        let hub = PanelBodiesHub(
            parts: [], look: PanelLook(), rows: { [] }, waiting: [panel("settings")])
        let watchlist = hub.body(for: panel("watchlist"))
        #expect(watchlist is LaterPanelHost)
        let waiting = hub.body(for: panel("settings"))
        #expect(waiting is WaitingPanel)
        #expect(waiting.subviews.isEmpty)
        #expect(!waiting.acceptsFirstResponder)
        let part = SettingsPart()
        #expect(hub.add(part) == [panel("settings")])
        #expect(hub.body(for: panel("settings")) === part.bodies[panel("settings")])
        #expect(hub.body(for: panel("watchlist")) === watchlist)
        #expect(hub.titleSuffix(for: panel("settings")) == "(mine)")
        // A part with no panel that shows takes none. A later panel of the part also goes to
        // the part.
        #expect(PanelBodiesHub(parts: [], look: PanelLook(), rows: { [] }).add(part).isEmpty)
        let later = PanelBodiesHub(parts: [], look: PanelLook(), rows: { [] })
        #expect(later.body(for: panel("settings")) is LaterPanelHost)
        #expect(later.add(SettingsPart()) == [panel("settings")])
    }

    // The Settings panel is a part of the hub. Before the settings store opens, its body is
    // empty. The model fills the same body, and the release of the body ends the view of the
    // panel: the search ends.
    @Test func theSettingsPanelHasItsPlaceInTheHub() async throws {
        UITestApp.prepare()
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let settings = SettingsPanels()
        let hub = PanelBodiesHub(parts: [settings], look: PanelLook(), rows: { [] })
        let body = try #require(hub.body(for: panel("settings")) as? SettingsBody)
        #expect(body.host == nil)
        #expect(hub.body(for: panel("watchlist")) is LaterPanelHost)
        let store = await SettingsStore.open(
            file: folder.url.appending(path: "settings.json"), log: Recorder<StoreEvent>())
        let layout = WindowLayoutModel(layout: WindowLayout(bounds: LayoutSize(w: 1200, h: 800)))
        let model = SettingsModel(store: store, layout: layout)
        settings.attach(model)
        #expect(hub.body(for: panel("settings")) === body)
        #expect(body.host != nil)
        #expect(body.host?.identifier == FocusMark.control)
        model.query = "flash"
        hub.releaseBody(for: panel("settings"))
        #expect(model.query.isEmpty)
        let next = try #require(hub.body(for: panel("settings")) as? SettingsBody)
        #expect(next !== body)
        #expect(next.host != nil)
    }

    // The titles of panelTitle, with the rows of now: a chat title follows the name of its row.
    @Test func theTitlesComeFromTheRows() {
        UITestApp.prepare()
        var rows: [SessionRow] = []
        let hub = PanelBodiesHub(parts: [], look: PanelLook(), rows: { rows })
        let chat = panel("chat:\(FakeSession.first)")
        #expect(hub.title(for: chat) == "Chat")
        var row = FakeSession.row(folder: "/tmp")
        row.name = "alpha"
        rows = [row]
        #expect(hub.title(for: chat) == "alpha")
        #expect(hub.title(for: panel("overview:1")) == "Overview")
    }
}
