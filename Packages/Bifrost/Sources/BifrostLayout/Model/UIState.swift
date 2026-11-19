import BifrostFoundation

// The UI state file, ui-state.json: the current layout, the named layouts, the Overview configs,
// the history of the New session dialog and the values of later phases. The file keeps the names
// and the meaning of the files of the Electron app (the section "Files on disk" of the
// architecture design).

// The result of a save of a named layout.
package enum LayoutSaveResult: Sendable, Equatable {
    case saved
    // The name has no character after the trim, or it is longer than UIState.maxName.
    case badName
    // The list has UIState.maxLayouts layouts, and the name is new.
    case full
}

// A layout that the user saved with a name. The name is trimmed and has 1 to UIState.maxName
// Characters.
package struct NamedLayout: Sendable, Equatable, Codable {
    package let name: String
    package var snapshot: LayoutSnapshot

    package init(name: String, snapshot: LayoutSnapshot) {
        self.name = name
        self.snapshot = snapshot
    }
}

public struct UIState: Sendable, Equatable {
    package static let maxLayouts = 20, maxName = 40
    // The largest save, in bytes of compact JSON (see docs/behaviour/stores.md).
    package static let maxBytes = 1_000_000

    // The layout of the canvas. nil gives the default layout.
    public var current: LayoutSnapshot?
    package private(set) var layouts: [NamedLayout] = []
    // The saved config of each Overview panel, keyed by its overview:<n> panel ID. A config
    // stays raw here: BifrostWindows reads and writes it with the rules of the Overview. The
    // encode writes only the keys of Overview panels.
    package var overviews: [PanelID: JSONValue] = [:]
    // The history of the New session dialog: recent folders, the last model and mode, recent
    // slash commands. The value stays raw here: BifrostWindows reads and writes it with the
    // rules of the history. nil when the file has no value.
    package var history: JSONValue?
    // The UI state of the Performance panel. The value stays raw until phase 5.
    package var performance: JSONValue?
    // The top-level fields of the file that this app does not know. A save writes them again.
    package var unknown = UnknownFields()

    package init() {}

    // Save the snapshot with the trimmed name. A layout with that name gets the new snapshot in
    // its place in the list. A new name goes at the end of the list. Two names are the same when
    // they are equal Strings, so two forms of one accented letter are one name.
    package mutating func saveLayout(_ name: String, _ snapshot: LayoutSnapshot)
        -> LayoutSaveResult
    {
        let name = name.trimmed()
        guard Self.isGoodName(name) else { return .badName }
        if let index = layouts.firstIndex(where: { $0.name == name }) {
            layouts[index].snapshot = snapshot
            return .saved
        }
        guard layouts.count < Self.maxLayouts else { return .full }
        layouts.append(NamedLayout(name: name, snapshot: snapshot))
        return .saved
    }

    // Remove the layout with this name. The name is not trimmed.
    package mutating func deleteLayout(_ name: String) {
        layouts.removeAll { $0.name == name }
    }

    // A name of 1 to maxName Characters.
    private static func isGoodName(_ name: String) -> Bool {
        (1...maxName).contains(name.count)
    }
}

extension UIState: Codable {
    private enum Key: String, CodingKey {
        case version, current, layouts, overviews, history, performance
    }

    // The decode refuses a value that is not an object, and the store then uses the empty state.
    // The state keeps the unknown fields of each object. A version that is not the whole number
    // 1 gives the empty state with those unknown fields. In a version 1 file, a bad item goes and
    // the other items stay:
    // - A current value that is not a snapshot gives no current layout.
    // - At most maxLayouts layouts: the first good layouts, in the order of the file. A layout
    //   needs a name of 1 to maxName Characters after the trim, and a snapshot. A repeated name
    //   goes, also in the other form of an accented letter.
    // - An overviews value that is not an object gives no Overview configs. A key that is not
    //   the panel ID of an Overview goes alone. Each config stays as it is, also null.
    // The history and the performance value stay as they are, also null. A missing raw value
    // stays nil. A raw or an unknown value with no JSON form throws NoJSONForm, also in a file
    // of another version, so the store keeps a copy of the file.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: Key.self)
        unknown = try UnknownFields(from: decoder, known: Key.self)
        // The raw values are read before the version check, so a raw value with no JSON form
        // makes each file a file that does not parse, whatever its version.
        func raw(_ key: Key) throws(NoJSONForm) -> JSONValue? {
            guard container.contains(key) else { return nil }
            return try container.jsonValue(forKey: key)
        }
        let (savedOverviews, savedHistory, savedPerformance) = try (
            raw(.overviews), raw(.history), raw(.performance)
        )
        guard (try? container.decode(JSONValue.self, forKey: .version))?.wholeNumber == 1 else {
            return
        }
        history = savedHistory
        performance = savedPerformance
        for (key, config) in savedOverviews?.object ?? [:] {
            guard let id = PanelID(key), id.kind == .overview else { continue }
            overviews[id] = config
        }
        current = try? container.decode(LayoutSnapshot.self, forKey: .current)
        let stored = (try? container.decode([Lenient<NamedLayout>].self, forKey: .layouts)) ?? []
        for case let layout? in stored.map(\.decoded) {
            guard layouts.count < Self.maxLayouts else { break }
            let name = layout.name.trimmed()
            guard Self.isGoodName(name), !layouts.contains(where: { $0.name == name }) else {
                continue
            }
            layouts.append(NamedLayout(name: name, snapshot: layout.snapshot))
        }
    }

    // The version 1, the current layout (null for none), the layouts, then the unknown fields. A
    // raw value that is nil has no key. The Overview configs are an object keyed by the text of
    // the panel ID. JSONFile.encode writes the keys in sorted order, so the same configs always
    // give the same file. A map with no Overview key has no key, as a missing value gives an
    // empty map.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: Key.self)
        try container.encode(1, forKey: .version)
        try container.encode(current, forKey: .current)
        try container.encode(layouts, forKey: .layouts)
        let configs = overviews.filter { $0.key.kind == .overview }
        if !configs.isEmpty {
            let object = Dictionary(uniqueKeysWithValues: configs.map { ($0.key.text, $0.value) })
            try container.encode(object, forKey: .overviews)
        }
        try container.encodeIfPresent(history, forKey: .history)
        try container.encodeIfPresent(performance, forKey: .performance)
        try unknown.encode(to: encoder)
    }
}

extension LayoutSnapshot: Codable {
    private enum Key: String, CodingKey {
        case frames, memory
    }

    // The decode refuses a value that is not an object. A frames value that is not a list gives
    // no frames, and a memory value that is not an object gives no memory. A bad frame goes, and
    // the other frames stay in z-order. A memory entry needs a panel ID and a good rect.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: Key.self)
        let frames = (try? container.decode([Lenient<SavedFrame>].self, forKey: .frames)) ?? []
        let stored =
            (try? container.decode([String: Lenient<LayoutRect>].self, forKey: .memory)) ?? [:]
        var memory: [PanelID: LayoutRect] = [:]
        for (key, item) in stored {
            guard let id = PanelID(key), let rect = item.decoded, rect.isGoodSaved else { continue }
            memory[id] = rect
        }
        self.init(frames: frames.compactMap(\.decoded), memory: memory)
    }

    // The frames in z-order, and the memory as an object keyed by panel ID. A JSON object has no
    // key order, and JSONFile.encode writes the keys in sorted order (W4). So each save of the
    // same layout gives the same file.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: Key.self)
        try container.encode(frames, forKey: .frames)
        let entries = memory.map { ($0.key.text, $0.value) }
        // Two IDs that no parse gives can have one text. The save keeps one of them and goes on.
        let object = Dictionary(entries, uniquingKeysWith: { first, _ in first })
        try container.encode(object, forKey: .memory)
    }
}

extension SavedFrame: Codable {
    private enum Key: String, CodingKey {
        case active, locked, minimised, panels, rect
    }

    // The decode refuses a frame with no good panel or with a bad rect. A panel that is not a
    // panel ID or that repeats goes. An active panel that is not one of the panels gives the
    // first panel. minimised and locked are true only for true. Each other field goes, for
    // example the opacity of an older file.
    package init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: Key.self)
        let items = try container.decode([Lenient<PanelID>].self, forKey: .panels)
        var panels: [PanelID] = []
        for case let id? in items.map(\.decoded) where !panels.contains(id) { panels.append(id) }
        guard let first = panels.first else {
            throw DecodingError.dataCorruptedError(
                forKey: .panels, in: container, debugDescription: "The frame has no good panel.")
        }
        let rect = try container.decode(LayoutRect.self, forKey: .rect)
        guard rect.isGoodSaved else {
            throw DecodingError.dataCorruptedError(
                forKey: .rect, in: container, debugDescription: "The rect has no size.")
        }
        let active = try? container.decode(PanelID.self, forKey: .active)
        self.init(
            panels: panels, active: active.flatMap { panels.contains($0) ? $0 : nil } ?? first,
            rect: rect, minimised: (try? container.decode(Bool.self, forKey: .minimised)) == true,
            locked: (try? container.decode(Bool.self, forKey: .locked)) == true)
    }

    package func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: Key.self)
        try container.encode(active, forKey: .active)
        try container.encode(locked, forKey: .locked)
        try container.encode(minimised, forKey: .minimised)
        try container.encode(panels, forKey: .panels)
        try container.encode(rect, forKey: .rect)
    }
}

extension LayoutRect {
    // A saved rect is good with four finite numbers and a width and a height above 0.
    fileprivate var isGoodSaved: Bool { isFinite && w > 0 && h > 0 }
}
