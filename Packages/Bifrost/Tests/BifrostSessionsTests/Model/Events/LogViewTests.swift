import BifrostSessions
import BifrostTestSupport
import Testing

// The rules of the Event log panel (docs/behaviour/panels.md, The Event log panel): the filter,
// the texts of a row, the session labels and the session options.

private func entry(
    _ seq: Int, _ session: String = "s1", name: HookEventName = .stop, tool: String? = nil
) -> LogEntry {
    LogEntry(seq: seq, at: seq, sessionId: session, name: name, tool: tool)
}

private func notice(_ seq: Int, _ text: String) -> LogEntry {
    LogEntry(seq: seq, at: seq, notice: text)
}

private let notificationText =
    "macOS didn't show a notification. Allow notifications for Bifrost in System Settings."

@Suite("event log view")
struct LogViewTests {
    @Test func theFilterKeepsOneSession() {
        let all = [entry(1, "a"), entry(2, "b"), entry(3, "a")]
        #expect(LogView.filter(all, session: "a").map(\.seq) == [1, 3])
        #expect(LogView.filter(all, session: "c").isEmpty)
        #expect(LogView.filter(all, session: nil) == all)
    }

    @Test func theTextOfAnEventIsItsNameThenItsToolInBrackets() {
        #expect(
            LogView.text(entry(1, name: .preToolUse, tool: "AskUserQuestion"))
                == "PreToolUse (AskUserQuestion)")
        #expect(LogView.text(entry(1)) == "Stop")
    }

    @Test func theTextOfANoticeIsItsPlainText() {
        #expect(LogView.text(notice(1, "Allow it.")) == "Allow it.")
    }

    // A narrow panel cuts the text, so the title holds the whole text.
    @Test func aNoticeRowSpansTheSessionAndTheEventWithItsWholeTextAsTitle() {
        let row = LogView.row(notice(1, notificationText), names: [:])
        #expect(row == LogRow(session: nil, text: notificationText, title: notificationText))
    }

    @Test func anEventRowHasItsSessionLabelAndItsTextAndNoTitle() {
        let names = ["aaaaaaaa-1111": "zeta"]
        let row = LogView.row(
            entry(1, "aaaaaaaa-1111", name: .postToolUse, tool: "Bash"), names: names)
        #expect(row == LogRow(session: "zeta", text: "PostToolUse (Bash)", title: nil))
    }

    @Test func theSessionLabelIsTheRowNameElseTheFirst8CharactersOfTheID() {
        let names = ["aaaaaaaa-1111": "zeta", "bbbbbbbb-2222": ""]
        #expect(LogView.sessionLabel("aaaaaaaa-1111", names: names) == "zeta")
        #expect(LogView.sessionLabel("gone1234-5678", names: names) == "gone1234")
        #expect(LogView.sessionLabel("bbbbbbbb-2222", names: names) == "bbbbbbbb")
        #expect(LogView.sessionLabel("short", names: names) == "short")
    }

    // A name gets the clean, the mask and the cut of the texts of the log, so a label never
    // shows a hidden character or a token.
    @Test func theNamesAreSafeToShow() {
        let token = "ghp_" + String(repeating: "A", count: 24)
        let rows = [
            SessionRow.test(sessionId: "s1", name: "ze\u{202E}ta\u{2060}"),
            SessionRow.test(sessionId: "s2", name: "\u{200B}\u{2066}\u{AD}"),
            SessionRow.test(sessionId: "s3", name: "bot \(token)"),
            SessionRow.test(sessionId: "s4", name: "a\nb"),
            SessionRow.test(sessionId: "s5", name: String(repeating: "n", count: 600)),
        ]
        var known: [String: String] = [:]
        let names = LogView.names(rows, known: &known)
        #expect(names["s1"] == "zeta")
        #expect(names["s3"] == "bot ***")
        #expect(names["s4"] == "a b")
        #expect(names["s5"]?.count == EventLog.textMax)
        #expect(LogView.sessionLabel("s1", names: names) == "zeta")
        // A name of hidden characters only is no name.
        #expect(LogView.sessionLabel("s2", names: names) == "s2")
        // The short ID is 8 Characters that show.
        #expect(LogView.sessionLabel("ab\u{202E}cdefghij", names: [:]) == "abcdefgh")
    }

    // The names come from the rows in their one place. The first row of an ID wins.
    @Test func theNamesAreTheNamesOfTheRowsByRowID() {
        let rows = [
            SessionRow.test(sessionId: "s1", name: "alpha"),
            SessionRow.test(sessionId: "s2", name: "beta"),
            SessionRow.test(sessionId: "s1", name: "other"),
        ]
        var known: [String: String] = [:]
        #expect(LogView.names(rows, known: &known) == ["s1": "alpha", "s2": "beta"])
    }

    // known keeps the safe form of each name of the last rows, and only of those.
    @Test func knownHoldsTheSafeFormOfEachNameOfTheLastRows() {
        let token = "ghp_" + String(repeating: "A", count: 24)
        var known: [String: String] = [:]
        _ = LogView.names(
            [SessionRow.test(sessionId: "s1", name: "x \(token)"), .test(sessionId: "s2")],
            known: &known)
        #expect(known == ["x \(token)": "x ***", "alpha": "alpha"])
        // A value in known is the safe form that the next call uses.
        known["alpha"] = "kept"
        let names = LogView.names([.test(sessionId: "s2"), .test(sessionId: "s3")], known: &known)
        #expect(names == ["s2": "kept", "s3": "kept"])
        #expect(known == ["alpha": "kept"])
    }

    @Test func theSessionOptionsUseTheRowNameAndTheShortFormOfAGoneSession() {
        let names = ["aaaaaaaa-1111": "zeta"]
        let options = LogView.sessionOptions(
            [
                entry(1, "aaaaaaaa-1111"), entry(2, "gone1234-5678"), entry(3, "aaaaaaaa-1111"),
                notice(4, "A notice."),
            ], names: names)
        #expect(
            options == [
                SessionOption(id: "gone1234-5678", label: "gone1234"),
                SessionOption(id: "aaaaaaaa-1111", label: "zeta"),
            ])
    }

    // The order is the English order of the labels: case and accents count less than letters.
    @Test func theSessionOptionsAreInTheOrderOfTheirLabels() {
        let names = [
            "1": "beta", "2": "Alpha", "3": "émile", "4": "Gamma", "5": "beta", "6": "zeta",
        ]
        let options = LogView.sessionOptions(
            ["5", "4", "3", "2", "1", "6"].enumerated().map { entry($0.offset, $0.element) },
            names: names)
        #expect(options.map(\.label) == ["Alpha", "beta", "beta", "émile", "Gamma", "zeta"])
        // Two equal labels keep the order of their first entry.
        #expect(options.map(\.id) == ["2", "5", "1", "3", "4", "6"])
    }
}
