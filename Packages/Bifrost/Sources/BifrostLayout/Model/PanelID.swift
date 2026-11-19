import BifrostFoundation

// The IDs of the panels and the frames, and the kinds of panels. docs/behaviour/windows.md has
// the forms of the IDs and the default sizes.

// The 18 kinds of panels. The raw value is the name of the kind in a panel ID.
public enum PanelKind: String, Sendable, CaseIterable {
    case overview, overviewSettings = "overview-settings", selectedItem = "selected-item"
    case settings, watchlist, chat, showInfo = "show-info", eventLog = "event-log"
    case usageHud = "usage-hud", serviceStatus = "service-status", reviews, performance, trust
    case answer, reviewDraft = "review-draft", dailyUpdate = "daily-update", module, heimdall

    // The size of a new frame of this kind when the memory has no rect for its panel.
    package var defaultSize: LayoutSize {
        switch self {
        case .answer: LayoutSize(w: 560, h: 420)
        case .chat: LayoutSize(w: 720, h: 480)
        case .dailyUpdate: LayoutSize(w: 560, h: 520)
        case .eventLog: LayoutSize(w: 640, h: 360)
        case .heimdall: LayoutSize(w: 520, h: 520)
        case .module: LayoutSize(w: 560, h: 420)
        case .overview: LayoutSize(w: 760, h: 360)
        case .overviewSettings: LayoutSize(w: 360, h: 420)
        case .performance: LayoutSize(w: 520, h: 460)
        case .reviewDraft: LayoutSize(w: 620, h: 560)
        case .reviews: LayoutSize(w: 480, h: 420)
        case .selectedItem: LayoutSize(w: 360, h: 300)
        case .serviceStatus: LayoutSize(w: 420, h: 240)
        // Wide enough for the nine section tabs with no cut label.
        case .settings: LayoutSize(w: 720, h: 540)
        case .showInfo: LayoutSize(w: 460, h: 560)
        case .trust: LayoutSize(w: 640, h: 380)
        case .usageHud: LayoutSize(w: 360, h: 180)
        case .watchlist: LayoutSize(w: 320, h: 280)
        }
    }
}

// The ID of a panel: one case for each kind. A text from a file or from the test port becomes a
// panel ID only through the parse init?(_:), and text gives the stored form back (row W1). An
// Overview number is 1 to 99. A session ID is a SessionID: a UUID in lower case, so the two forms
// of one ID are one panel.
public enum PanelID: Hashable, Sendable {
    // overview:<n>
    case overview(Int)
    // overview-settings:<n>: the settings of the Overview with the same number.
    case overviewSettings(Int)
    // chat:<session ID>
    case chat(SessionID)
    // show-info:<session ID>
    case showInfo(SessionID)
    // module:<module ID>:<panel ID of the manifest>
    case module(id: String, panel: String)
    // The kinds whose panel ID is the name of the kind only.
    case selectedItem, settings, watchlist, eventLog, usageHud, serviceStatus, reviews
    case performance, trust, answer, reviewDraft, dailyUpdate, heimdall

    public var kind: PanelKind {
        switch self {
        case .overview: .overview
        case .overviewSettings: .overviewSettings
        case .chat: .chat
        case .showInfo: .showInfo
        case .module: .module
        case .selectedItem: .selectedItem
        case .settings: .settings
        case .watchlist: .watchlist
        case .eventLog: .eventLog
        case .usageHud: .usageHud
        case .serviceStatus: .serviceStatus
        case .reviews: .reviews
        case .performance: .performance
        case .trust: .trust
        case .answer: .answer
        case .reviewDraft: .reviewDraft
        case .dailyUpdate: .dailyUpdate
        case .heimdall: .heimdall
        }
    }

    // The panel ID of the text, or nil when the text is not a panel ID. The words "chat" and
    // "show-info" and the session ID can have ASCII letters of either case. Each other part is
    // in lower case.
    package init?(_ text: String) {
        if let kind = PanelKind(rawValue: text) {
            guard let id = Self(onlyName: kind) else { return nil }
            self = id
            return
        }
        guard let colon = text.utf8.firstIndex(of: UInt8(ascii: ":")),
            let name = NameWithPart(text[..<colon])
        else { return nil }
        let part = text[text.utf8.index(after: colon)...]
        switch name {
        case .overview:
            guard let number = Self.overviewNumber(part) else { return nil }
            self = .overview(number)
        case .overviewSettings:
            guard let number = Self.overviewNumber(part) else { return nil }
            self = .overviewSettings(number)
        case .chat:
            guard let session = SessionID(part) else { return nil }
            self = .chat(session)
        case .showInfo:
            guard let session = SessionID(part) else { return nil }
            self = .showInfo(session)
        case .module:
            guard let colon = part.utf8.firstIndex(of: UInt8(ascii: ":")) else { return nil }
            let module = part[..<colon]
            let panel = part[part.utf8.index(after: colon)...]
            guard Self.isManifestName(module, length: 2...40),
                Self.isManifestName(panel, length: 1...30)
            else { return nil }
            self = .module(id: String(module), panel: String(panel))
        }
    }

    // The names of the kinds whose panel ID has a colon and a part after the name.
    private enum NameWithPart {
        case overview, overviewSettings, chat, showInfo, module

        // Only the words "chat" and "show-info" can have ASCII letters of either case.
        init?(_ name: Substring) {
            if name.isWord("overview") {
                self = .overview
            } else if name.isWord("overview-settings") {
                self = .overviewSettings
            } else if name.isWord("chat", anyCase: true) {
                self = .chat
            } else if name.isWord("show-info", anyCase: true) {
                self = .showInfo
            } else if name.isWord("module") {
                self = .module
            } else {
                return nil
            }
        }
    }

    // The panel ID of a kind whose ID is the name of the kind only, or nil for another kind.
    private init?(onlyName kind: PanelKind) {
        switch kind {
        case .selectedItem: self = .selectedItem
        case .settings: self = .settings
        case .watchlist: self = .watchlist
        case .eventLog: self = .eventLog
        case .usageHud: self = .usageHud
        case .serviceStatus: self = .serviceStatus
        case .reviews: self = .reviews
        case .performance: self = .performance
        case .trust: self = .trust
        case .answer: self = .answer
        case .reviewDraft: self = .reviewDraft
        case .dailyUpdate: self = .dailyUpdate
        case .heimdall: self = .heimdall
        case .overview, .overviewSettings, .chat, .showInfo, .module: return nil
        }
    }

    // The numbers of the Overviews: at most 99 Overviews have a frame.
    package static let overviewNumbers = 1...99

    // An Overview number: 1 to 99, with no 0 at the start.
    private static func overviewNumber(_ text: Substring) -> Int? {
        let digits = text.utf8
        guard (1...2).contains(digits.count), digits.first != UInt8(ascii: "0"),
            digits.allSatisfy(\.isASCIIDigit), let number = Int(text),
            overviewNumbers.contains(number)
        else { return nil }
        return number
    }

    // A module ID or a panel ID of a manifest: a lower-case letter, then lower-case letters,
    // digits and hyphens, with a length in the range.
    private static func isManifestName(_ text: Substring, length: ClosedRange<Int>) -> Bool {
        let bytes = text.utf8
        guard length.contains(bytes.count), bytes.first?.isASCIILower == true else {
            return false
        }
        return bytes.allSatisfy { $0.isASCIILower || $0.isASCIIDigit || $0 == UInt8(ascii: "-") }
    }
}

extension PanelID: CustomStringConvertible {
    // The text of the panel ID: its stored form in the files and in the test port.
    public var text: String {
        switch self {
        case .overview(let number): "overview:\(number)"
        case .overviewSettings(let number): "overview-settings:\(number)"
        case .chat(let session): "chat:\(session.text)"
        case .showInfo(let session): "show-info:\(session.text)"
        case .module(let id, let panel): "module:\(id):\(panel)"
        case .selectedItem, .settings, .watchlist, .eventLog, .usageHud, .serviceStatus,
            .reviews, .performance, .trust, .answer, .reviewDraft, .dailyUpdate, .heimdall:
            kind.rawValue
        }
    }

    public var description: String { text }
}

// The order of the texts.
extension PanelID: Comparable {
    public static func < (a: PanelID, b: PanelID) -> Bool { a.text < b.text }
}

// In a file, a panel ID is a JSON text. The decode refuses a text that is not a panel ID.
extension PanelID: Codable {
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        guard let id = PanelID(try container.decode(String.self)) else {
            throw DecodingError.dataCorruptedError(
                in: container, debugDescription: "The text is not a panel ID.")
        }
        self = id
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(text)
    }
}

// The ID of a frame: f<number>. The layout gives each new frame the next number.
public struct FrameID: Hashable, Sendable {
    package let number: Int

    package init(number: Int) {
        self.number = number
    }

    // nil when the text is not f and a number with no extra 0 at the start, as the layout makes
    // it.
    package init?(text: String) {
        let digits = text.utf8.dropFirst()
        guard text.utf8.first == UInt8(ascii: "f"), let first = digits.first,
            first != UInt8(ascii: "0") || digits.count == 1, digits.allSatisfy(\.isASCIIDigit),
            let number = Int(text.dropFirst())
        else { return nil }
        self.number = number
    }

    public var text: String { "f\(number)" }
}

extension UInt8 {
    fileprivate var isASCIIDigit: Bool { (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(self) }
    fileprivate var isASCIILower: Bool { (UInt8(ascii: "a")...UInt8(ascii: "z")).contains(self) }
}

extension Substring {
    // True when the bytes of the text are the bytes of the word. With anyCase, an ASCII letter
    // of the text can also be in upper case. The word is ASCII in lower case.
    fileprivate func isWord(_ word: String, anyCase: Bool = false) -> Bool {
        utf8.elementsEqual(word.utf8) { byte, wordByte in
            let upper = UInt8(ascii: "A")...UInt8(ascii: "Z")
            return (anyCase && upper.contains(byte) ? byte + 32 : byte) == wordByte
        }
    }
}
