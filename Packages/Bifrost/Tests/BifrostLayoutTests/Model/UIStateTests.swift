import BifrostFoundation
import BifrostLayout
import BifrostTestSupport
import Foundation
import Testing

// The UI state file: the decode of ui-state.json, its encode and the named layouts. The
// layout module keeps the Overview configs and the history as raw JSON, and BifrostWindows reads
// them with their own rules (UIStateValuesTests). The performance value stays raw until phase 5
// (row U1). So the tests of these values check the keys of the Overview configs and that the
// decode keeps each raw value as it is.

private let rectJSON: JSONValue = ["h": 200, "w": 300, "x": 10, "y": 20]
private let theRect = rect(h: 200, w: 300, x: 10, y: 20)
private let theFrame = SavedFrame(
    panels: [panel("settings")], active: panel("settings"), rect: theRect, minimised: false,
    locked: false)

// The object with the fields changed: nil removes a field.
private func with(_ value: JSONValue, _ changes: [String: JSONValue?]) -> JSONValue {
    guard case .object(var fields) = value else { return value }
    for (key, change) in changes.sorted(by: { $0.key < $1.key }) { fields[key] = change }
    return .object(fields)
}

// A stored frame of the Settings panel at theRect.
private let frameJSON: JSONValue = [
    "active": "settings", "locked": false, "minimised": false, "panels": ["settings"],
    "rect": rectJSON,
]

// A stored snapshot with n copies of frameJSON, and the snapshot that it gives.
private func snapJSON(_ n: Int = 1) -> JSONValue {
    ["frames": .array(Array(repeating: frameJSON, count: n)), "memory": [:]]
}

private func snap(_ n: Int = 1) -> LayoutSnapshot {
    LayoutSnapshot(frames: Array(repeating: theFrame, count: n), memory: [:])
}

// The state of a file with this JSON value, as the store reads it.
private func state(_ value: JSONValue) -> UIState { loaded(value, else: UIState()) }

// The state of a version 1 file with these fields.
private func state(_ fields: [String: JSONValue]) -> UIState {
    state(.object(fields.merging(["version": 1]) { _, version in version }))
}

// The names of the layouts of a version 1 file with these layout items.
private func names(_ items: [JSONValue]) -> [String] {
    state(["layouts": .array(items)]).layouts.map(\.name)
}

private func names(_ state: UIState) -> [String] { state.layouts.map(\.name) }

// A stored layout item with this name and snapshot. nil leaves out the field.
private func layout(_ name: JSONValue?, _ snapshot: JSONValue? = snapJSON()) -> JSONValue {
    var fields: [String: JSONValue] = [:]
    fields["name"] = name
    fields["snapshot"] = snapshot
    return .object(fields)
}

// A state with these layouts. Each name must be good, and the list must not be full.
private func store(_ layouts: [(String, LayoutSnapshot)] = []) -> UIState {
    var state = UIState()
    for (name, snapshot) in layouts {
        precondition(state.saveLayout(name, snapshot) == .saved, "not saved: \(name)")
    }
    return state
}

// A frame of these panels at theRect.
private func saved(
    _ panels: [String], active: String? = nil, minimised: Bool = false, locked: Bool = false
) -> SavedFrame {
    let ids = panels.map(panel)
    return SavedFrame(
        panels: ids, active: active.map(panel) ?? ids[0], rect: theRect, minimised: minimised,
        locked: locked)
}

// One row of a table: a stored frame and the frames that the decode keeps from it.
private struct FrameCase: Sendable, CustomTestStringConvertible {
    let name: String
    let frame: JSONValue
    let kept: [SavedFrame]
    var testDescription: String { name }
}

private let frameCases: [FrameCase] = [
    FrameCase(name: "a good frame stays", frame: frameJSON, kept: [theFrame]),
    FrameCase(
        name: "minimised and locked true stay",
        frame: with(frameJSON, ["locked": true, "minimised": true]),
        kept: [saved(["settings"], minimised: true, locked: true)]),
    FrameCase(
        name: "no active, locked or minimised gives the first panel and false",
        frame: ["panels": ["settings"], "rect": rectJSON], kept: [theFrame]),
    FrameCase(
        name: "locked and minimised are true only for true",
        frame: with(frameJSON, ["locked": 1, "minimised": "yes"]), kept: [theFrame]),
    FrameCase(
        name: "an active value that is not a panel ID gives the first panel",
        frame: with(frameJSON, ["active": "zzz", "panels": ["overview:1", "settings"]]),
        kept: [saved(["overview:1", "settings"])]),
    FrameCase(
        name: "an active panel that is a good ID but not in the frame gives the first panel",
        frame: with(frameJSON, ["active": "event-log", "panels": ["settings", "watchlist"]]),
        kept: [saved(["settings", "watchlist"])]),
    FrameCase(
        name: "an active value that is not a text gives the first panel",
        frame: with(frameJSON, ["active": 7, "panels": ["watchlist", "settings"]]),
        kept: [saved(["watchlist", "settings"])]),
    FrameCase(
        name: "a good active panel stays",
        frame: with(frameJSON, ["active": "watchlist", "panels": ["settings", "watchlist"]]),
        kept: [saved(["settings", "watchlist"], active: "watchlist")]),
    FrameCase(
        name: "a panel that is not a panel ID goes and the good panels stay",
        frame: with(frameJSON, ["panels": ["settings", "nope", 7, .null]]), kept: [theFrame]),
    FrameCase(
        name: "a panel that repeats stays once, in its first place",
        frame: with(
            frameJSON, ["active": "watchlist", "panels": ["settings", "watchlist", "settings"]]),
        kept: [saved(["settings", "watchlist"], active: "watchlist")]),
    FrameCase(
        name: "the old integration panel goes and the other panels stay",
        frame: with(frameJSON, ["active": "integration", "panels": ["integration", "watchlist"]]),
        kept: [saved(["watchlist"])]),
    FrameCase(
        name: "a frame of only the integration panel goes",
        frame: with(frameJSON, ["active": "integration", "panels": ["integration"]]), kept: []),
    FrameCase(
        name: "a frame with no good panel goes",
        frame: with(frameJSON, ["panels": ["nope"]]), kept: []),
    FrameCase(
        name: "a frame with an empty panel list goes", frame: with(frameJSON, ["panels": []]),
        kept: []),
    FrameCase(
        name: "panels that is not a list makes the frame go",
        frame: with(frameJSON, ["panels": "settings"]), kept: []),
    FrameCase(
        name: "a frame with no panels value goes", frame: with(frameJSON, ["panels": nil]),
        kept: []),
    FrameCase(
        name: "a rect with a width of 0 makes the frame go",
        frame: with(frameJSON, ["rect": with(rectJSON, ["w": 0])]), kept: []),
    FrameCase(
        name: "a rect with a height below 0 makes the frame go",
        frame: with(frameJSON, ["rect": with(rectJSON, ["h": -1])]), kept: []),
    FrameCase(
        name: "a rect with a text value makes the frame go",
        frame: with(frameJSON, ["rect": with(rectJSON, ["x": "1"])]), kept: []),
    FrameCase(
        name: "a rect with no y makes the frame go",
        frame: with(frameJSON, ["rect": with(rectJSON, ["y": nil])]), kept: []),
    FrameCase(
        name: "a rect that is not an object makes the frame go",
        frame: with(frameJSON, ["rect": [10, 20, 300, 200]]), kept: []),
    FrameCase(
        name: "a frame with no rect goes", frame: with(frameJSON, ["rect": nil]), kept: []),
    FrameCase(
        name: "a rect with parts of a unit stays",
        frame: with(frameJSON, ["rect": ["h": 200.5, "w": 300, "x": -10.25, "y": 0]]),
        kept: [
            SavedFrame(
                panels: [panel("settings")], active: panel("settings"),
                rect: rect(h: 200.5, w: 300, x: -10.25, y: 0), minimised: false, locked: false)
        ]),
    FrameCase(
        name: "the opacity of an older file goes and the frame stays",
        frame: with(frameJSON, ["opacity": 0.5]), kept: [theFrame]),
    FrameCase(name: "a frame that is null goes", frame: .null, kept: []),
    FrameCase(name: "a frame that is a number goes", frame: 7, kept: []),
    FrameCase(name: "a frame that is a text goes", frame: "x", kept: []),
]

// One row of a table: a stored layout item and the name that the decode keeps, or nil.
private struct LayoutCase: Sendable, CustomTestStringConvertible {
    let name: String
    let item: JSONValue
    let kept: String?
    var testDescription: String { name }
}

private let layoutCases: [LayoutCase] = [
    LayoutCase(name: "a good layout stays", item: layout("Work"), kept: "Work"),
    LayoutCase(name: "the name is trimmed", item: layout("  Work  "), kept: "Work"),
    LayoutCase(
        name: "a name of 40 Characters stays",
        item: layout(.string(String(repeating: "x", count: 40))),
        kept: String(repeating: "x", count: 40)),
    LayoutCase(
        name: "a name of 41 Characters goes",
        item: layout(.string(String(repeating: "x", count: 41))), kept: nil),
    LayoutCase(
        name: "a name of 40 emoji stays",
        item: layout(.string(String(repeating: "😀", count: 40))),
        kept: String(repeating: "😀", count: 40)),
    LayoutCase(
        name: "a name of 41 emoji goes",
        item: layout(.string(String(repeating: "😀", count: 41))), kept: nil),
    LayoutCase(name: "an empty name goes", item: layout(""), kept: nil),
    LayoutCase(name: "a name of only spaces goes", item: layout("   "), kept: nil),
    LayoutCase(name: "a name that is not a text goes", item: layout(7), kept: nil),
    LayoutCase(name: "a layout with no name goes", item: layout(nil), kept: nil),
    LayoutCase(name: "a layout with no snapshot goes", item: layout("A", nil), kept: nil),
    LayoutCase(name: "a snapshot that is a text goes", item: layout("A", "bad"), kept: nil),
    LayoutCase(name: "a snapshot that is null goes", item: layout("A", .null), kept: nil),
    LayoutCase(
        name: "a snapshot with no frames and no memory stays empty", item: layout("A", [:]),
        kept: "A"),
    LayoutCase(name: "an item that is null goes", item: .null, kept: nil),
    LayoutCase(name: "an item that is a number goes", item: 7, kept: nil),
    LayoutCase(name: "an item that is a text goes", item: "Work", kept: nil),
    LayoutCase(name: "an item that is an empty object goes", item: [:], kept: nil),
]

private let refusedFiles: [JSONValue] = [
    .null, [], "x", 7, true, [:], ["version": 2], ["version": 1.5], ["version": "1"],
    ["version": .null], ["version": true], ["version": [1]], ["layouts": [layout("A")]],
]

private let rawValues: [JSONValue] = [
    .null, "x", 7, [], [:], ["detailsOpen": "yes"], ["detailsOpen": true],
    ["model": "opus", "recentDirs": ["/a", 7], "x": 1.5],
]

// A saved Overview config with one tab.
private let configJSON: JSONValue = ["tabs": [["id": "t1", "name": "All"]]]

@Suite("the UI state file")
struct UIStateTests {
    @Test(
        "a value that is not an object with the version 1 gives the empty state",
        arguments: refusedFiles)
    func notVersionOne(value: JSONValue) {
        #expect(state(value) == UIState())
    }

    @Test("the version 1.0 is the whole number 1")
    func versionOnePointZero() throws {
        let text = #"{"version":1.0,"layouts":[{"name":"A","snapshot":{}}]}"#
        let decoded = try JSONDecoder().decode(UIState.self, from: Data(text.utf8))
        #expect(names(decoded) == ["A"])
    }

    @Test("a stored frame keeps its good panels, active panel, rect and flags",
        arguments: frameCases)
    private func frame(_ item: FrameCase) {
        let decoded = state(["current": ["frames": [item.frame], "memory": [:]]])
        #expect(decoded.current?.frames == item.kept)
    }

    @Test("a bad frame goes alone and the other frames stay in z-order")
    func badFrameGoesAlone() {
        let watchlist = with(frameJSON, ["active": "watchlist", "panels": ["watchlist"]])
        let decoded = state([
            "current": ["frames": [frameJSON, with(frameJSON, ["panels": []]), watchlist]]
        ])
        #expect(decoded.current?.frames == [theFrame, saved(["watchlist"])])
    }

    @Test(
        "a current value that is not an object gives no current layout",
        arguments: [JSONValue.null, "x", 7, [], [snapJSON()]])
    func currentNotObject(value: JSONValue) {
        #expect(state(["current": value]).current == nil)
    }

    @Test("a file with no current value has no current layout")
    func noCurrent() {
        #expect(state(["layouts": [layout("A")]]).current == nil)
    }

    @Test(
        "a frames value that is not a list gives no frames, and the memory stays",
        arguments: [JSONValue.null, "x", 7, ["settings": 1]])
    func framesNotList(value: JSONValue) {
        let decoded = state(["current": ["frames": value, "memory": ["settings": rectJSON]]])
        #expect(
            decoded.current == LayoutSnapshot(frames: [], memory: [panel("settings"): theRect]))
    }

    @Test(
        "a memory value that is not an object gives no memory, and the frames stay",
        arguments: [JSONValue.null, "x", 7, [rectJSON]])
    func memoryNotObject(value: JSONValue) {
        let decoded = state(["current": ["frames": [frameJSON], "memory": value]])
        #expect(decoded.current == snap(1))
    }

    @Test("a memory entry needs a panel ID and a good rect, and the good entries stay")
    func memoryEntries() {
        let decoded = state([
            "current": [
                "memory": [
                    "nope": rectJSON, "f1": rectJSON, "7": rectJSON, "integration": rectJSON,
                    "overview:1": with(rectJSON, ["h": -1]), "watchlist": "x",
                    "event-log": with(rectJSON, ["w": nil]), "settings": rectJSON,
                ]
            ]
        ])
        #expect(
            decoded.current == LayoutSnapshot(frames: [], memory: [panel("settings"): theRect]))
    }

    @Test("a stored layout needs an object with a good name and a snapshot",
        arguments: layoutCases)
    private func storedLayout(_ item: LayoutCase) {
        #expect(names([item.item]) == (item.kept.map { [$0] } ?? []))
    }

    @Test("a bad layout goes alone and the other layouts stay in file order")
    func badLayoutGoesAlone() {
        #expect(names([layout("A"), layout(""), .null, layout("B")]) == ["A", "B"])
    }

    @Test("a repeated name goes and the first layout stays")
    func repeatedName() {
        let decoded = state([
            "layouts": [layout(" a ", snapJSON(1)), layout("a", snapJSON(2)), layout("b")]
        ])
        let a = NamedLayout(name: "a", snapshot: snap(1))
        #expect(decoded.layouts == [a, NamedLayout(name: "b", snapshot: snap())])
    }

    @Test("a file keeps at most 20 layouts: the first good ones, in file order")
    func limit() {
        let items = [layout(""), .null] + (0..<25).map { layout(.string("l\($0)")) }
        #expect(names(items) == (0..<UIState.maxLayouts).map { "l\($0)" })
    }

    @Test(
        "a layouts value that is not a list gives no layouts",
        arguments: [JSONValue.null, "x", 7, ["A": snapJSON()]])
    func layoutsNotList(value: JSONValue) {
        #expect(state(["layouts": value]).layouts.isEmpty)
    }

    // U5: the names compare with String equality. So two forms of one accented letter are one
    // name: a load keeps the first layout, and a save or a delete in the other form finds it.
    @Test func twoFormsOfOneNameAreOneLayout() {
        let composed = "Caf\u{e9}"
        let decomposed = "Cafe\u{301}"
        let scalars = { (names: [String]) in names.map { Array($0.unicodeScalars) } }
        let decoded = state(["layouts": [layout(.string(composed)), layout(.string(decomposed))]])
        #expect(scalars(names(decoded)) == scalars([composed]))
        var s = decoded
        #expect(s.saveLayout(decomposed, snap(2)) == .saved)
        #expect(s.layouts.count == 1)
        #expect(s.layouts.map(\.snapshot.frames.count) == [2])
        s.deleteLayout(decomposed)
        #expect(s.layouts.isEmpty)
    }

    // Each raw value stays as the file has it, also null and a value that the rules of
    // BifrostWindows would change. The other raw value stays nil.
    @Test(
        "the history and the performance value stay raw",
        arguments: ["history", "performance"], rawValues)
    func rawValue(key: String, value: JSONValue) {
        let decoded = state([key: value])
        let raw: [String: JSONValue?] = [
            "history": decoded.history, "performance": decoded.performance,
        ]
        var expected: [String: JSONValue?] = ["history": nil, "performance": nil]
        expected[key] = .some(value)
        #expect(raw == expected)
        #expect(decoded.overviews.isEmpty)
    }

    @Test("a file with no raw values keeps them nil and has no Overview configs")
    func noRawValues() {
        let decoded = state(["current": .null, "layouts": [layout("A")]])
        #expect(decoded.overviews.isEmpty)
        #expect(decoded.history == nil)
        #expect(decoded.performance == nil)
        #expect(names(decoded) == ["A"])
    }

    // Only an overview:<n> key stays. A key that is not a panel ID, or that is the ID of another
    // kind of panel, goes alone. Each value stays as the file has it: the rules of the configs
    // are in BifrostWindows.
    @Test func onlyTheKeysOfOverviewPanelsStay() {
        let session = "73b5ca76-a4a8-4f97-9764-e41657296414"
        let decoded = state([
            "overviews": .object([
                "overview:1": configJSON, "overview:99": 7, "overview:7": .null,
                "overview:0": configJSON, "overview:100": configJSON, "overview:01": configJSON,
                "OVERVIEW:2": configJSON, "overview-settings:3": configJSON,
                "settings": configJSON, "chat:\(session)": configJSON, "nope": configJSON,
                "": configJSON,
            ])
        ])
        #expect(
            decoded.overviews == [
                panel("overview:1"): configJSON, panel("overview:99"): 7,
                panel("overview:7"): .null,
            ])
    }

    @Test(
        "an overviews value that is not an object gives no Overview configs",
        arguments: [JSONValue.null, "x", 7, true, [], [configJSON]])
    func overviewsNotObject(value: JSONValue) {
        let decoded = state(["overviews": value, "layouts": [layout("A")]])
        #expect(decoded.overviews.isEmpty)
        #expect(names(decoded) == ["A"])
    }

    // The keys are the texts of the panel IDs. JSONFile writes them in sorted text order, so
    // overview:10 comes before overview:2, and the same configs always give the same file.
    @Test func theOverviewsEncodeWithSortedPanelKeys() throws {
        var s = UIState()
        s.overviews = [
            panel("overview:2"): ["name": "two"], panel("overview:10"): ["name": "ten"],
            panel("overview:1"): ["name": "one"],
        ]
        let data = try JSONFile.encode(s)
        let text = String(decoding: data, as: UTF8.self)
        let one = try #require(text.range(of: "\"overview:1\" :"))
        let ten = try #require(text.range(of: "\"overview:10\" :"))
        let two = try #require(text.range(of: "\"overview:2\" :"))
        #expect(one.lowerBound < ten.lowerBound)
        #expect(ten.lowerBound < two.lowerBound)
        #expect(
            try encoded(s) == [
                "current": .null, "layouts": [], "version": 1,
                "overviews": [
                    "overview:1": ["name": "one"], "overview:10": ["name": "ten"],
                    "overview:2": ["name": "two"],
                ],
            ])
        #expect(try JSONDecoder().decode(UIState.self, from: data) == s)
    }

    // An empty map and no key give the same state, so the encode leaves out an empty map. Code
    // can put the ID of another kind of panel in the map. The encode leaves out that key, so the
    // file holds only overview:<n> keys.
    @Test func theEncodeWritesOnlyTheConfigsOfOverviewPanels() throws {
        var s = UIState()
        s.overviews = [panel("settings"): configJSON, panel("overview-settings:1"): configJSON]
        #expect(try encoded(s) == ["current": .null, "layouts": [], "version": 1])
        s.overviews[panel("overview:3")] = configJSON
        #expect(
            try encoded(s) == [
                "current": .null, "layouts": [], "version": 1,
                "overviews": ["overview:3": configJSON],
            ])
    }

    // The state keeps each key that the file form does not name, also with a version that is
    // not 1, and the encode writes it again.
    @Test func theStateKeepsTheUnknownKeys() throws {
        let decoded = state(["theme": "light", "panels": [1, 2]])
        #expect(decoded.unknown.values == ["theme": "light", "panels": [1, 2]])
        let later = state(.object(["version": 2, "theme": "light", "layouts": [layout("A")]]))
        #expect(later.unknown.values == ["theme": "light"])
        #expect(later.layouts.isEmpty)
        let data = try JSONEncoder().encode(decoded)
        #expect(try JSONDecoder().decode(UIState.self, from: data) == decoded)
    }

    @Test("the empty state encodes the version 1, a null current layout and no layouts")
    func encodeEmpty() throws {
        #expect(try encoded(UIState()) == ["current": .null, "layouts": [], "version": 1])
    }

    @Test("a raw value that is null encodes as null, and a nil raw value has no key")
    func encodeRaw() throws {
        var s = UIState()
        s.history = .null
        s.performance = ["detailsOpen": true]
        #expect(
            try encoded(s) == [
                "current": .null, "history": .null, "layouts": [],
                "performance": ["detailsOpen": true], "version": 1,
            ])
    }

    // Row W1: the file keeps the text of each panel ID. An upper-case session ID loads as the
    // panel of the lower-case ID, and the next save writes the lower-case text.
    @Test func eachPanelIDKeepsItsTextAndASessionIDBecomesLowerCase() throws {
        let session: SessionID = "73b5ca76-a4a8-4f97-9764-e41657296414"
        let chat = "chat:\(session.text)"
        let upper = "CHAT:\(session.text.uppercased())"
        func snapshot(_ chat: String) -> JSONValue {
            let frame: JSONValue = [
                "active": .string(chat), "locked": false, "minimised": false,
                "panels": [.string(chat), "overview:2", "module:ab:p"], "rect": rectJSON,
            ]
            return [
                "frames": [frame],
                "memory": .object([chat: rectJSON, "overview-settings:2": rectJSON]),
            ]
        }
        let decoded = state(["current": snapshot(upper)])
        let frame = try #require(decoded.current?.frames.first)
        #expect(frame.panels == [.chat(session), .overview(2), .module(id: "ab", panel: "p")])
        #expect(frame.active == .chat(session))
        #expect(decoded.current?.memory.keys.sorted() == [.chat(session), .overviewSettings(2)])
        let expected: JSONValue = ["current": snapshot(chat), "layouts": [], "version": 1]
        #expect(try encoded(decoded) == expected)
        #expect(try encoded(state(["current": snapshot(chat)])) == expected)
    }

    // A case made in code can hold a value that no parse gives. Two such module IDs can have one
    // text: the save keeps one memory key for them and does not stop.
    @Test func aSaveOfTwoModuleIDsWithOneTextKeepsOneKey() throws {
        let a = PanelID.module(id: "ab:c", panel: "d")
        let b = PanelID.module(id: "ab", panel: "c:d")
        #expect(a != b)
        #expect(a.text == b.text)
        let snapshot = LayoutSnapshot(frames: [], memory: [a: theRect, b: theRect])
        #expect(try encoded(snapshot) == ["frames": [], "memory": ["module:ab:c:d": rectJSON]])
    }

    @Test("a snapshot keeps the frames in z-order with no IDs, and keeps the memory")
    func snapshotForm() throws {
        var layout = WindowLayout(bounds: size(h: 800, w: 1200))
        layout.apply(.open(panel("settings")))
        layout.apply(.open(panel("selected-item")))
        layout.apply(.close(panel("settings")))
        layout.apply(.open(panel("overview:1")))
        let snapshot = layout.snapshot
        #expect(snapshot.frames.map(\.panels) == [[panel("selected-item")], [panel("overview:1")]])
        #expect(snapshot.memory.keys.sorted() == [panel("settings")])
        guard case .object(let fields) = try encoded(snapshot),
            case .array(let frames)? = fields["frames"],
            case .object(let memory)? = fields["memory"]
        else {
            Issue.record("the snapshot does not encode as an object with frames and memory")
            return
        }
        let keys = frames.map { frame -> [String] in
            guard case .object(let fields) = frame else { return [] }
            return fields.keys.sorted()
        }
        let frameKeys = ["active", "locked", "minimised", "panels", "rect"]
        #expect(keys == [frameKeys, frameKeys])
        #expect(memory.keys.sorted() == ["settings"])
    }

    @Test("an encode and a decode give the same state")
    func roundTrip() throws {
        var layout = WindowLayout(bounds: size(h: 800, w: 1200))
        layout.apply(.open(panel("settings")))
        layout.apply(.open(panel("overview:2")))
        layout.apply(.lock(frameID(2), true))
        layout.apply(.open(panel("watchlist")))
        layout.apply(.minimise(frameID(3)))
        layout.apply(.close(panel("settings")))
        let empty = LayoutSnapshot(frames: [], memory: [:])
        var s = store([("Work", layout.snapshot), ("Empty", empty)])
        s.current = layout.snapshot
        s.overviews = [panel("overview:2"): [:]]
        s.history = .null
        let data = try JSONEncoder().encode(s)
        #expect(try JSONDecoder().decode(UIState.self, from: data) == s)
    }

    // A refused save gives badName or full and leaves the state as it was.
    @Test("saving a layout appends or replaces in place and refuses bad names and a full store")
    func saveLayout() {
        var s = store()
        #expect(s.saveLayout(" one ", snap(1)) == .saved)
        #expect(s.saveLayout("two", snap(1)) == .saved)
        #expect(names(s) == ["one", "two"])
        var replaced = s
        #expect(replaced.saveLayout("one", snap(2)) == .saved)
        #expect(names(replaced) == ["one", "two"])
        #expect(replaced.layouts.first?.snapshot.frames.count == 2)
        var blank = s
        #expect(blank.saveLayout("   ", snap()) == .badName)
        #expect(blank == s)
        var long = s
        let tooLong = String(repeating: "x", count: UIState.maxName + 1)
        #expect(long.saveLayout(tooLong, snap()) == .badName)
        #expect(long == s)
        var limit = s
        let longest = String(repeating: "x", count: UIState.maxName)
        #expect(limit.saveLayout(longest, snap()) == .saved)
        #expect(limit.layouts.count == 3)
        let full = store((0..<UIState.maxLayouts).map { ("n\($0)", snap()) })
        var refused = full
        #expect(refused.saveLayout("new", snap()) == .full)
        #expect(refused == full)
        var kept = full
        #expect(kept.saveLayout("n3", snap(2)) == .saved)
        #expect(kept.layouts.dropFirst(3).first?.snapshot.frames.count == 2)
    }

    @Test("deleting a layout removes only that name")
    func deleteLayout() {
        let s = store([("a", snap()), ("b", snap())])
        var a = s
        a.deleteLayout("a")
        #expect(names(a) == ["b"])
        var other = s
        other.deleteLayout("zzz")
        #expect(other.layouts.count == 2)
    }
}
