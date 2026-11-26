import BifrostFoundation
import BifrostTestSupport
import Foundation
import Testing

@testable import BifrostLayout

// The edge cases of the window rules: the forms of the IDs and the default sizes. The place of a
// saved window is in WindowPlaceEdgeTests.swift of BifrostWindowsTests.

private let sessionID: SessionID = "73b5ca76-a4a8-4f97-9764-e41657296414"
private let session = sessionID.text

@Suite("the IDs of panels and frames")
struct IdEdgeTests {
    @Test(
        "a panel ID text gives its case, and the case gives the same text back",
        arguments: [
            ("overview:1", PanelID.overview(1)), ("overview:12", .overview(12)),
            ("overview:99", .overview(99)), ("overview-settings:3", .overviewSettings(3)),
            ("overview-settings:99", .overviewSettings(99)), ("settings", .settings),
            ("watchlist", .watchlist), ("selected-item", .selectedItem), ("event-log", .eventLog),
            ("usage-hud", .usageHud), ("service-status", .serviceStatus), ("reviews", .reviews),
            ("performance", .performance), ("trust", .trust), ("answer", .answer),
            ("review-draft", .reviewDraft), ("daily-update", .dailyUpdate),
            ("heimdall", .heimdall), ("chat:\(session)", .chat(sessionID)),
            ("show-info:\(session)", .showInfo(sessionID)),
            ("module:acme-tool:main-panel", .module(id: "acme-tool", panel: "main-panel")),
            ("module:ab:p", .module(id: "ab", panel: "p")),
        ])
    func roundTrip(text: String, id: PanelID) {
        #expect(PanelID(text) == id)
        #expect(id.text == text)
        #expect(id.description == text)
    }

    @Test(
        "each panel ID has the kind of its name",
        arguments: [
            ("overview:1", PanelKind.overview), ("overview-settings:3", .overviewSettings),
            ("settings", .settings), ("watchlist", .watchlist), ("selected-item", .selectedItem),
            ("event-log", .eventLog), ("usage-hud", .usageHud),
            ("service-status", .serviceStatus), ("reviews", .reviews),
            ("performance", .performance), ("trust", .trust), ("answer", .answer),
            ("review-draft", .reviewDraft), ("daily-update", .dailyUpdate),
            ("heimdall", .heimdall), ("chat:\(session)", .chat),
            ("show-info:\(session)", .showInfo), ("module:ab:p", .module),
        ])
    func kindOfEachID(text: String, kind: PanelKind) {
        #expect(PanelID(text)?.kind == kind)
        #expect(PanelID(text)?.text.hasPrefix(kind.rawValue) == true)
    }

    // The words "chat" and "show-info" and the session ID can have upper-case letters. The panel
    // holds the session ID in lower case, so the two forms of one ID are one panel.
    @Test func anUpperCaseSessionIDGivesTheLowerCasePanel() {
        let upper = session.uppercased()
        #expect(PanelID("CHAT:\(upper)") == .chat(sessionID))
        #expect(PanelID("Chat:\(upper)")?.text == "chat:\(session)")
        #expect(PanelID("SHOW-INFO:\(upper)") == .showInfo(sessionID))
        #expect(Set([PanelID("chat:\(upper)"), PanelID("chat:\(session)")]).count == 1)
    }

    @Test(
        "a text that is not a panel ID is refused",
        arguments: [
            "", "nope", "overview", "overview:", "overview:x y", "overview:é", "chat:", "chat",
            "Settings", "settings ", " settings", "settings:1", "heimdall:1", "reviews:2",
            "overview-settings", "show-info", "module", "chat:é", "overview:1\n", "overview:0",
            "overview:100", "overview:+1", "overview-settings:0", "OVERVIEW:1", "Module:ab:p",
            "overview:01", "chat:abc", "show-info:abc", "module:acme.tool", "module:a:p",
            "module:acme-tool:", "module:Acme:p", "module:acme:1p", "module:ab:p:q",
            "chat:\(session)\u{0}", "chat:{\(session)}", "chat:\(session) ", "chat :\(session)",
            "chat:\(session.replacing("-", with: ""))", "show-info:\(session)0",
        ])
    func bad(raw: String) {
        #expect(PanelID(raw) == nil)
    }

    @Test("a panel ID decodes from a JSON text and encodes as that text")
    func panelCodable() throws {
        let id = try JSONDecoder().decode(PanelID.self, from: Data(#""overview:3""#.utf8))
        #expect(id == .overview(3))
        #expect(String(decoding: try JSONEncoder().encode(id), as: UTF8.self) == #""overview:3""#)
    }

    @Test(
        "a JSON value that is not a good panel ID does not decode",
        arguments: [
            #""nope""#, #""""#, "7", "null", "true", #"["settings"]"#, #"{"raw":"settings"}"#,
        ])
    func panelDecodeRefused(json: String) {
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(PanelID.self, from: Data(json.utf8))
        }
    }

    // The order of panel IDs is the order of their texts.
    @Test func panelIDsSortByTheirText() {
        let ids: [PanelID] = [.settings, .overview(12), .chat(sessionID), .overview(2), .answer]
        #expect(ids.sorted().map(\.text) == ids.map(\.text).sorted())
    }

    @Test(
        "a frame ID is f and a number with no leading 0",
        arguments: [("f0", 0), ("f1", 1), ("f10", 10), ("f123456", 123_456)])
    func frameGood(text: String, number: Int) {
        #expect(FrameID(text: text)?.number == number)
        #expect(FrameID(number: number).text == text)
    }

    @Test(
        "a text that is not a frame ID is refused",
        arguments: [
            "", "f", "F1", "1", "f01", "f-1", "f1 ", " f1", "f1.5", "ff1", "f99999999999999999999",
            "f١",
        ])
    func frameBad(text: String) {
        #expect(FrameID(text: text) == nil)
    }

    @Test(
        "each kind has its default frame size",
        arguments: [
            (PanelKind.answer, 560.0, 420.0), (.chat, 720, 480), (.dailyUpdate, 560, 520),
            (.eventLog, 640, 360), (.heimdall, 520, 520), (.module, 560, 420),
            (.overview, 760, 360), (.overviewSettings, 360, 420), (.performance, 520, 460),
            (.reviewDraft, 700, 560), (.reviews, 480, 420), (.selectedItem, 360, 300),
            (.serviceStatus, 420, 240), (.settings, 720, 540), (.showInfo, 460, 560),
            (.trust, 640, 380), (.usageHud, 360, 180), (.watchlist, 320, 280),
        ])
    func defaultSize(kind: PanelKind, w: Double, h: Double) {
        #expect(kind.defaultSize == LayoutSize(w: w, h: h))
        #expect(PanelKind.allCases.count == 18)
    }
}

@Suite("a tab that leaves its stack")
struct TearOutEdgeTests {
    private let stack = LayoutRect(x: 100, y: 100, w: 400, h: 300)
    private let area = LayoutSize(w: 1000, h: 800)

    @Test
    func savedNotFinite() {
        for saved in [
            LayoutRect(x: 0, y: 0, w: .nan, h: 200), LayoutRect(x: 0, y: 0, w: 200, h: .infinity),
        ] {
            let rect = Hit.tearOutRect(
                at: LayoutPoint(x: 300, y: 300), saved: saved, stack: stack, bounds: area)
            #expect(rect.w == 400)
            #expect(rect.h == 300)
        }
    }

    @Test("a saved rect gives its size and a size over the area is cut to it")
    func savedSize() {
        let saved = LayoutRect(x: 0, y: 0, w: 2000, h: 250)
        let rect = Hit.tearOutRect(
            at: LayoutPoint(x: 300, y: 300), saved: saved, stack: stack, bounds: area)
        #expect(rect.w == 1000)
        #expect(rect.h == 250)
    }
}
