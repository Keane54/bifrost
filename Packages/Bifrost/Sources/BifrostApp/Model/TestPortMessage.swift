// The lines of the debug test port (docs/behaviour/shell.md, "The test port"): one JSON object in,
// one JSON line out. The smoke test drives the app with it. It can type into a session, so only a
// Debug build has this code, and the parse is strict: a field that the form does not have, a bad
// value or a line that is not one JSON object is no request. A request decodes as one Decodable
// value: the "op" field picks the form, and each form decodes its own fields.
//
// The forms:
// - {"op":"state"}: the frames, the chats and the Overviews of the window, the report of the
//   import of this start, the saved settings, the key of each menu item, the Event log, the Usage
//   HUD, the rows of the Watchlist, the PR of each Show Info panel, the Reviews panel, the status
//   of Live details and of the skills, the rows of the session list, the state of the session
//   actions, and the parity features: the release notes dialog, the Daily update and the level of
//   the Performance monitor with its number of reasons.
// - {"op":"open","panel":"<panel ID>"}: open the panel, or bring its frame to the front.
// - {"op":"overview","panel":"<panel ID>","sort":"<column>"}: sort the active tab of the Overview
//   by the column, as a click on its header does. The panel is the ID of an Overview, and the
//   column is the ID of a column in the saved config (OverviewColumn).
// - {"op":"type","text":"<text>"}: type the text (printable ASCII) with the keys of a US keyboard,
//   through the key filter of the window.
// - {"op":"key","key":"enter" | "shift-enter" | "escape" | "interrupt"}: one key through the key
//   filter. "interrupt" is Cmd+.: it acts on the selected row, also with no focused chat.
// - {"op":"hold","key":"space","ms":<n>}: the key down of Space, a wait of n ms, then its key up,
//   through the key filter. n is a whole number from 1 to 10,000. A hold of the dictation key
//   dictates, and a short one types a space.
// - {"op":"bench","plan":"gate" | "short","chats":<n>,"name":"<name>"} and the variant fields:
//   start a run of the debug bench. n is a whole number from 1 to 8. The name has 1 to 40
//   characters from a to z, 0 to 9 and "-". The app writes the results to
//   <test home>/bench/<name>.jsonl, so a request never names a path. The answer comes at once,
//   and the state shows the run. The variant fields are optional (BenchVariant).
// - {"op":"setting","patch":{...}}: change the settings with one edit. The patch is one JSON
//   object, the one raw value of a request. Each field is a field of settings.json with its new
//   value. The change checks the fields (SettingsPatch), so the parse keeps each field and value.
// - {"op":"live","action":"install" | "enable" | "disable" | "uninstall"} and the same with
//   "op":"skills": run the action of Settings > Live details or of Settings > Skills, as its
//   button does (LiveAction).
// - {"op":"resume","session":"<session ID>"}: run the session command Resume on the row of the
//   session, as the Resume action does.
// - {"op":"action","id":"<action ID>","session":"<session ID>"}: run the session action on the
//   session, as a click on its button does. The ID is the ID of a session action (ActionID). These
//   actions are no request: set-priority, open-project and watch-colour need the choice of a
//   menu; copy-id, open-in-terminal and take-control act outside the test home (the clipboard, a
//   terminal app, a signal to a process); run-slash and send-message only move the focus, and the
//   send request types a text. The answer comes at the end of the run. Each confirmation of the
//   run answers yes only with the optional "confirm":true, else no. Rename needs "name":"<name>",
//   the new local name, and saves it in the Rename dialog.
// - {"op":"action","id":"new-session" | "resume-all"}: run the global action. It has no session.
//   New session needs "folder":"<path>" and can have "name":"<name>" (else the suggested name),
//   and it starts the session in the New session dialog. Resume all can have "confirm".
// - {"op":"send","session":"<session ID>","text":"<text>"}: type the text into the session
//   through the session input, as the send box does. The text has at least one character. The
//   answer comes at the end of the send.
// - {"op":"releaseNotes"}: open the release notes dialog, as the Release notes button of
//   Settings > Updates does.
// - {"op":"daily","action":"refresh"}: run the drafts of the Daily update, as Refresh does. The
//   answer comes at once, and the state shows the run and its result.
// - {"op":"daily","action":"mark-sent","area":"<area ID>"}: mark the area as sent, as Mark as
//   sent does. The area is the ID of a tab of the panel.
// - {"op":"reviews","action":"review" | "pause","pr":"<PR key>"}: click Review or Pause on the
//   row of the PR in the Reviews panel, as the button or the menu item of the row does. The PR
//   key is "Owner/Repo#n" (PRKey.text). The answer comes at once, and the state shows the result.
// - {"op":"quit"}: quit the app after the answer.
#if DEBUG
import BifrostFoundation
import BifrostHealth
import BifrostLayout
import BifrostLive
import BifrostReviews
import BifrostSessions
import BifrostWindows
import Foundation

public enum TestPortRequest: Sendable, Equatable {
    case state, open(PanelID), type(String), key(TestKey), hold(ms: Int), bench(TestBench), quit
    case overview(PanelID, sort: OverviewColumn)
    case setting([String: JSONValue])
    // An action of Live details, or of the skills.
    case live(LiveAction), skills(LiveAction)
    // A resume of the session with this session ID.
    case resume(String)
    case action(TestAction)
    case send(SessionID, text: String)
    // Open the release notes dialog, as the Release notes button of Settings > Updates does.
    case releaseNotes
    // An action of the Daily update panel.
    case daily(TestDailyAction)
    // A click on the row of a PR in the Reviews panel. The PR is the text of a PR key.
    case reviews(TestReviewsAction, pr: String)
}

// An action of the Daily update panel for the test port.
public enum TestDailyAction: Sendable, Equatable {
    case refresh
    // Mark the area with this ID as sent.
    case markSent(String)
}

// A click of the test port on the row of a PR in the Reviews panel: Review, or Pause on a new
// request. The raw value is the action in the request.
public enum TestReviewsAction: String, Sendable, Equatable {
    case review, pause
}

// The fields of the requests. A field that no form has is no request.
private enum Field: String, CodingKey {
    case op, panel, text, key, ms, plan, chats, name, sort, patch, action, session
    case blur, background, list, minimised, streaming, metal, scrollback
    case id, confirm, folder, area, pr
}

// The run of an action of the test port: a session action on a session, or a global action, with
// the answers to its dialogs.
public struct TestAction: Sendable, Equatable {
    package enum Target: Sendable, Equatable {
        case session(ActionID, SessionID)
        case global(GlobalActionID)
    }

    package var target: Target
    // True: each confirmation of the run answers yes. Else each one answers no.
    package var confirm: Bool
    // Rename: the new local name. New session: the name of the session, or nil for the suggested
    // name.
    package var name: String?
    // New session: the folder of the session.
    package var folder: String?

    package init(
        _ target: Target, confirm: Bool = false, name: String? = nil, folder: String? = nil
    ) {
        self.target = target
        self.confirm = confirm
        self.name = name
        self.folder = folder
    }

    // The actions that the test port does not run: an action that needs the choice of a menu
    // (the port gives no choice), an action with an effect outside the test home, and an action
    // that only moves the focus to the send box.
    static let refused: Set<ActionID> = [
        .setPriority, .openProject, .watchColour, .copyId, .openInTerminal, .takeControl,
        .runSlash, .sendMessage,
    ]
}

extension TestPortRequest: Decodable {
    // The forms, by the value of "op".
    private enum Op: String, Decodable {
        case state, open, overview, type, key, hold, bench, quit, setting, live, skills, resume
        case action, send, releaseNotes, daily, reviews

        // The fields that the form must have, and the fields that it can have.
        var fields: (required: Set<Field>, optional: Set<Field>) {
            switch self {
            case .state, .quit, .releaseNotes: ([.op], [])
            case .open: ([.op, .panel], [])
            case .overview: ([.op, .panel, .sort], [])
            case .setting: ([.op, .patch], [])
            case .live, .skills: ([.op, .action], [])
            case .resume: ([.op, .session], [])
            case .action: ([.op, .id], [.session, .confirm, .name, .folder])
            case .send: ([.op, .session, .text], [])
            case .daily: ([.op, .action], [.area])
            case .reviews: ([.op, .action, .pr], [])
            case .type: ([.op, .text], [])
            case .key: ([.op, .key], [])
            case .hold: ([.op, .key, .ms], [])
            case .bench:
                (
                    [.op, .plan, .chats, .name],
                    [.blur, .background, .list, .minimised, .streaming, .metal, .scrollback]
                )
            }
        }
    }

    // Any field name, so the decode sees the names that Field does not have.
    private struct AnyField: CodingKey {
        let stringValue: String
        var intValue: Int? { nil }
        init(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }

    public init(from decoder: any Decoder) throws {
        let names = Set(try decoder.container(keyedBy: AnyField.self).allKeys.map(\.stringValue))
        let fields = try decoder.container(keyedBy: Field.self)
        let op = try fields.decode(Op.self, forKey: .op)
        // Each form has its fields and no other field.
        let given = Set(names.compactMap(Field.init(rawValue:)))
        let (required, optional) = op.fields
        guard given.count == names.count, required.isSubset(of: given),
            given.isSubset(of: required.union(optional))
        else { throw Self.bad(fields, "the fields of the form") }
        switch op {
        case .state: self = .state
        case .quit: self = .quit
        case .releaseNotes: self = .releaseNotes
        case .open:
            guard let panel = PanelID(try fields.decode(String.self, forKey: .panel)) else {
                throw Self.bad(fields, "a panel ID")
            }
            self = .open(panel)
        case .overview:
            guard let panel = PanelID(try fields.decode(String.self, forKey: .panel)),
                panel.kind == .overview,
                let column = OverviewColumn(rawValue: try fields.decode(String.self, forKey: .sort))
            else { throw Self.bad(fields, "the panel ID of an Overview and a column") }
            self = .overview(panel, sort: column)
        case .type:
            let text = try fields.decode(String.self, forKey: .text)
            guard TestPortMessage.isPrintableASCII(text) else {
                throw Self.bad(fields, "printable ASCII text")
            }
            self = .type(text)
        case .key: self = .key(try fields.decode(TestKey.self, forKey: .key))
        case .hold:
            let ms = try fields.decode(Int.self, forKey: .ms)
            guard try fields.decode(String.self, forKey: .key) == "space",
                TestPortMessage.holdTimes.contains(ms)
            else { throw Self.bad(fields, "the space key and a hold time") }
            self = .hold(ms: ms)
        case .bench: self = .bench(try TestBench(from: fields))
        case .setting:
            guard let patch = try fields.decode(JSONValue.self, forKey: .patch).object else {
                throw Self.bad(fields, "a patch object")
            }
            self = .setting(patch)
        case .live, .skills:
            guard let action = LiveAction(rawValue: try fields.decode(String.self, forKey: .action))
            else { throw Self.bad(fields, "an action of a plugin") }
            self = op == .live ? .live(action) : .skills(action)
        case .resume:
            guard let id = SessionID(try fields.decode(String.self, forKey: .session)) else {
                throw Self.bad(fields, "a session ID")
            }
            self = .resume(id.text)
        case .action: self = .action(try TestAction(from: fields))
        case .send:
            let text = try fields.decode(String.self, forKey: .text)
            guard let session = SessionID(try fields.decode(String.self, forKey: .session)),
                !text.isEmpty
            else { throw Self.bad(fields, "a session ID and a text") }
            self = .send(session, text: text)
        case .daily:
            // Refresh has no area. Mark as sent needs the ID of an area.
            let area = try fields.decodeIfPresent(String.self, forKey: .area)
            switch (try fields.decode(String.self, forKey: .action), area) {
            case ("refresh", nil): self = .daily(.refresh)
            case ("mark-sent", let area?) where !area.isEmpty: self = .daily(.markSent(area))
            default: throw Self.bad(fields, "refresh, or mark-sent with an area")
            }
        case .reviews:
            guard
                let action = TestReviewsAction(
                    rawValue: try fields.decode(String.self, forKey: .action)),
                let pr = PRKey(text: try fields.decode(String.self, forKey: .pr))
            else { throw Self.bad(fields, "review or pause, and the key of a pull request") }
            self = .reviews(action, pr: pr.text)
        }
    }

    private static func bad(_ fields: KeyedDecodingContainer<Field>, _ wanted: String)
        -> DecodingError
    {
        DecodingError.dataCorrupted(
            DecodingError.Context(
                codingPath: fields.codingPath, debugDescription: "The request needs \(wanted)."))
    }
}

// A run of the debug bench: the plan, the number of chats, the name of the results file and the
// variant.
public struct TestBench: Sendable, Equatable {
    // The timelines of the bench (BenchPlan). short is the plan of one short run.
    public enum Plan: String, Sendable, Decodable {
        case gate, short
    }

    public var plan: Plan
    public var chats: Int
    public var name: String
    public var variant: BenchVariant

    package init(plan: Plan, chats: Int, name: String, variant: BenchVariant) {
        self.plan = plan
        self.chats = chats
        self.name = name
        self.variant = variant
    }
}

// The variant of a bench run, for runs that compare the costs of the parts of the app. The defaults
// are the normal app: the blur and the moving background on, the session list open, no minimised
// chat, each chat streams and draws with Metal, and the scrollback of the app.
public struct BenchVariant: Sendable, Equatable {
    // The private blur behind the frames, or no blur.
    package var blur: Bool
    // The moving background, or the still background.
    package var background: Bool
    // The frame of the session list (overview:1) under the chats, or no such frame.
    package var list: Bool
    // The number of chats that go to the side bar. The drag chat never goes.
    package var minimised: Int
    // The number of chats that stream, or nil for each chat. The other chats stay quiet.
    package var streaming: Int?
    // The number of chats that draw with Metal, or nil for each chat. The other chats draw with
    // Core Graphics.
    package var metal: Int?
    // The scrollback lines of each chat, or nil for the value of the app.
    package var scrollback: Int?

    public init(
        blur: Bool = true, background: Bool = true, list: Bool = true, minimised: Int = 0,
        streaming: Int? = nil, metal: Int? = nil, scrollback: Int? = nil
    ) {
        self.blur = blur
        self.background = background
        self.list = list
        self.minimised = minimised
        self.streaming = streaming
        self.metal = metal
        self.scrollback = scrollback
    }
}

// A named key of the key request. The raw value is the name in the request. interrupt is
// Cmd+. (interrupt:mod).
public enum TestKey: String, Sendable, Decodable {
    case enter, shiftEnter = "shift-enter", escape, interrupt
}

extension TestAction {
    // The fields of an action request. A global action has no session, and a session action
    // needs one. Only Rename and New session take a name: Rename needs it. Only New session takes
    // a folder, and it needs it. A name and a folder have at least one character.
    fileprivate init(from fields: KeyedDecodingContainer<Field>) throws {
        func text(_ key: Field) throws -> String? {
            guard fields.contains(key) else { return nil }
            let value = try fields.decode(String.self, forKey: key)
            guard !value.isEmpty else { throw Self.bad(fields, key) }
            return value
        }
        guard let id = ActionID(rawValue: try fields.decode(String.self, forKey: .id)),
            !Self.refused.contains(id)
        else { throw Self.bad(fields, .id) }
        let confirm =
            fields.contains(.confirm) ? try fields.decode(Bool.self, forKey: .confirm) : false
        let name = try text(.name)
        let folder = try text(.folder)
        let target: Target
        if let global = GlobalActionID(rawValue: id.rawValue) {
            guard !fields.contains(.session) else { throw Self.bad(fields, .session) }
            switch global {
            case .newSession:
                guard folder != nil else { throw Self.bad(fields, .folder) }
            case .resumeAll:
                guard name == nil, folder == nil else { throw Self.bad(fields, .name) }
            }
            target = .global(global)
        } else {
            guard let session = SessionID(try fields.decode(String.self, forKey: .session)) else {
                throw Self.bad(fields, .session)
            }
            guard folder == nil, (name != nil) == (id == .rename) else {
                throw Self.bad(fields, .name)
            }
            target = .session(id, session)
        }
        self.init(target, confirm: confirm, name: name, folder: folder)
    }

    private static func bad(_ fields: KeyedDecodingContainer<Field>, _ key: Field)
        -> DecodingError
    {
        DecodingError.dataCorruptedError(
            forKey: key, in: fields, debugDescription: "The action has a bad field.")
    }
}

extension TestBench {
    // The fields of a bench request. The variant fields are optional: a field that is there has
    // a value of its type in its range. A null is a bad value.
    fileprivate init(from fields: KeyedDecodingContainer<Field>) throws {
        func flag(_ key: Field) throws -> Bool? {
            fields.contains(key) ? try fields.decode(Bool.self, forKey: key) : nil
        }
        func count(_ key: Field, _ range: ClosedRange<Int>) throws -> Int? {
            guard fields.contains(key) else { return nil }
            let value = try fields.decode(Int.self, forKey: key)
            guard range.contains(value) else {
                throw DecodingError.dataCorruptedError(
                    forKey: key, in: fields, debugDescription: "The count is out of range.")
            }
            return value
        }
        let plan = try fields.decode(Plan.self, forKey: .plan)
        let chats = try fields.decode(Int.self, forKey: .chats)
        let name = try fields.decode(String.self, forKey: .name)
        guard TestPortMessage.benchChats.contains(chats), TestPortMessage.isBenchName(name) else {
            throw DecodingError.dataCorruptedError(
                forKey: .name, in: fields, debugDescription: "The chats or the name are bad.")
        }
        let defaults = BenchVariant()
        let variant = BenchVariant(
            blur: try flag(.blur) ?? defaults.blur,
            background: try flag(.background) ?? defaults.background,
            list: try flag(.list) ?? defaults.list,
            minimised: try count(.minimised, 0...(chats - 1)) ?? defaults.minimised,
            streaming: try count(.streaming, 0...chats), metal: try count(.metal, 0...chats),
            scrollback: try count(.scrollback, TestPortMessage.benchScrollback))
        self.init(plan: plan, chats: chats, name: name, variant: variant)
    }
}

package enum TestPortMessage {
    // The times of a hold, in milliseconds.
    package static let holdTimes = 1...10_000
    // The chats of a bench run, the longest name of its results file and the scrollback lines.
    package static let benchChats = 1...8
    static let benchNameLength = 40
    static let benchScrollback = 0...10_000

    // The answer to a line that is not a request.
    package static let badRequest = #"{"error":"bad request"}"# + "\n"
    // The answer when the answer of the app has no JSON form (a number that is not finite).
    static let badAnswer = #"{"error":"bad answer"}"# + "\n"

    // The request of one line with no line break, or nil.
    package static func request(_ line: String) -> TestPortRequest? {
        try? JSONDecoder().decode(TestPortRequest.self, from: Data(line.utf8))
    }

    // 1 to 40 characters, each from a to z, 0 to 9 or "-". So the name is one file name with no
    // folder and no extension. The bench runner checks its results file with the same rule.
    package static func isBenchName(_ name: String) -> Bool {
        let allowed = Set("abcdefghijklmnopqrstuvwxyz0123456789-".unicodeScalars)
        return (1...benchNameLength).contains(name.unicodeScalars.count)
            && name.unicodeScalars.allSatisfy(allowed.contains)
    }

    // One line: the compact JSON of the value with the keys in order, then a line break.
    package static func answer(_ value: JSONValue) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(value) else { return badAnswer }
        return String(decoding: data, as: UTF8.self) + "\n"
    }

    // At least one character, and each character from the space to the tilde: the characters
    // that the keys of a US keyboard type with no modifier other than Shift.
    static func isPrintableASCII(_ text: String) -> Bool {
        let printable: ClosedRange<UInt32> = 0x20...0x7e
        return !text.isEmpty
            && text.unicodeScalars.allSatisfy { scalar in printable.contains(scalar.value) }
    }

    // MARK: - The forms of the state

    // The number of texts of the Event log in the state.
    static let eventsShown = 5

    // The Event log: the number of entries, and the row texts of the newest 5 entries in the
    // order of the log (LogView.text). The log keeps only the safe texts, with each token masked.
    package static func events(_ entries: [LogEntry]) -> JSONValue {
        [
            "count": .int(entries.count),
            "last": .array(entries.suffix(eventsShown).map { .string(LogView.text($0)) }),
        ]
    }

    // The Usage HUD: each bar (label, percent or null, level and detail) and the source line of
    // UsageView.of. The values come from the usage lines and the answer of the account, so they
    // hold no token.
    package static func usage(bars: [UsageBar], source: String) -> JSONValue {
        let bars = bars.map { bar -> JSONValue in
            [
                "label": .string(bar.label), "percent": bar.percent.map(JSONValue.int) ?? .null,
                "level": .string(bar.level.rawValue), "detail": .string(bar.detail),
            ]
        }
        return ["bars": .array(bars), "source": .string(source)]
    }

    // The Reviews panel: each row of To review, then of My PRs, with its PR key, its tab, its
    // flash, whether it is paused, the text at the right of line 2 ("" for a new request, which
    // shows its buttons) and, while a round of the PR runs, the step of the round; the consent of
    // the automatic rounds (null while no store is open); and the problem line (the message of a
    // refused store or of the last failed poll), or null.
    package static func reviews(
        _ snapshot: ReviewsSnapshot, consent: Bool?, round: (PRKey) -> RoundPhase?
    ) -> JSONValue {
        let rows = (snapshot.toReview + snapshot.mine).map { row -> JSONValue in
            let paused = if case .toReview(.paused) = row.state { true } else { false }
            var fields: [String: JSONValue] = [
                "pr": .string(row.id.text),
                "tab": .string(row.tab == .toReview ? "toReview" : "mine"),
                "flash": .bool(row.flash), "paused": .bool(paused),
                "state": .string(row.status.text),
            ]
            if let step = round(row.id) { fields["round"] = .string(step.rawValue) }
            return .object(fields)
        }
        let problem: String? =
            if case .refused(let failure) = snapshot.phase { failure.message } else {
                snapshot.problem?.message
            }
        return [
            "rows": .array(rows), "autoFixConsent": consent.map(JSONValue.bool) ?? .null,
            "problem": problem.map(JSONValue.string) ?? .null,
        ]
    }

    // The ID and the name of each row, in the order of the list.
    package static func rows(_ rows: [SessionRow]) -> JSONValue {
        .array(rows.map { ["id": .string($0.sessionId), "name": .string($0.name)] })
    }

    // The PR line of Show Info: null while the lookup runs, then the PR, {"none":true} for no PR,
    // or {"unavailable":<reason>}.
    package static func pr(_ info: PRInfo?) -> JSONValue {
        switch info {
        case nil: .null
        case .some(.none): ["none": true]
        case .some(.unavailable(let reason)): ["unavailable": .string(reason.text)]
        case .some(.pr(let number, let title, let url, let state)):
            [
                "number": .int(number), "title": .string(title), "url": .string(url.absoluteString),
                "state": .string(state),
            ]
        }
    }

    // The Performance monitor: the level ("checking" while it has no level, then "ok",
    // "warning" or "problem") and the number of reasons.
    package static func performance(_ snapshot: PerformanceSnapshot) -> JSONValue {
        let level =
            switch snapshot.level {
            case nil: "checking"
            case .ok: "ok"
            case .warning: "warning"
            case .problem: "problem"
            }
        return ["level": .string(level), "reasons": .int(snapshot.reasons.count)]
    }
}
#endif
