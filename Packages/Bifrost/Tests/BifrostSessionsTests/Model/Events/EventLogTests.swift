import BifrostSessions
import BifrostTestSupport
import Testing

// The rules of the Event log (docs/behaviour/panels.md, The Event log). Each token of a test is a
// fake that the test makes from repeated characters.

private func event(
    _ i: Int, _ name: HookEventName = .stop, session: String = "s1", tool: String? = nil,
    seq: Int? = nil
) -> HookEvent {
    HookEvent(name, session, at: 1000 + i, seq: seq, toolName: tool)
}

private let token = "ghp_" + String(repeating: "A", count: 24)

@Suite("event log")
struct EventLogTests {
    @Test func appendGivesEachEventANumberAndItsTool() {
        var log = EventLog()
        let added = log.append([
            event(1, .preToolUse, tool: "AskUserQuestion"),
            event(2, .permissionRequest, session: "s2", tool: "Bash"),
            event(3, .turnAborted),
        ])
        #expect(
            added == [
                LogEntry(
                    seq: 1, at: 1001, sessionId: "s1", name: .preToolUse,
                    tool: "AskUserQuestion"),
                LogEntry(
                    seq: 2, at: 1002, sessionId: "s2", name: .permissionRequest, tool: "Bash"),
                LogEntry(seq: 3, at: 1003, sessionId: "s1", name: .turnAborted),
            ])
        #expect(added[2].tool == nil)
        #expect(log.entries == added)
    }

    @Test func theNumberOfAnEntryIsTheNumberOfTheLogNotTheNumberOfTheMod() {
        var log = EventLog()
        #expect(log.append([event(1, seq: 77)]).map(\.seq) == [1])
        #expect(log.append([event(2, seq: 3)]).map(\.seq) == [2])
    }

    @Test func theLogKeepsTheNewest5000() {
        #expect(EventLog.max == 5000)
        var log = EventLog()
        _ = log.append((0..<4900).map { event($0) })
        let burst = log.append((0..<300).map { event($0) })
        #expect(burst.count == 300)
        #expect(log.entries.count == 5000)
        #expect(log.entries.first?.seq == 201)
        #expect(log.entries.last?.seq == 5200)
        // One event at a time, as the shell gives them.
        for i in 0..<12_000 { _ = log.append([event(i)]) }
        #expect(log.entries.count == 5000)
        #expect(log.entries.first?.seq == 12_201)
        #expect(log.entries.last?.seq == 17_200)
        #expect(log.entries.map(\.seq) == Array(12_201...17_200))
    }

    @Test func aLogWithASmallerMaxKeepsThatMany() {
        var log = EventLog(max: 3)
        for i in 1...7 { _ = log.append([event(i)]) }
        #expect(log.entries.map(\.seq) == [5, 6, 7])
        _ = log.line("A line.", at: 9)
        #expect(log.entries.map(\.seq) == [6, 7, 8])
    }

    @Test func aNoticeShowsOneTimeForEachText() {
        var log = EventLog()
        _ = log.append([event(1)])
        let first = log.notice(EventLog.notificationRefused, at: 5000)
        #expect(
            first
                == LogEntry(seq: 2, at: 5000, notice: EventLog.notificationRefused))
        #expect(log.notice(EventLog.notificationRefused, at: 6000) == nil)
        #expect(log.entries.count == 2)
        #expect(log.notice("Another text.", at: 7000)?.seq == 3)
    }

    @Test func aLineShowsEachTime() {
        var log = EventLog()
        let text = "Daily update: the drafts are ready."
        #expect(
            log.line(text, at: 5000)
                == LogEntry(seq: 1, at: 5000, notice: text))
        #expect(log.line(text, at: 6000).seq == 2)
        #expect(log.entries.count == 2)
    }

    @Test func theNoticeTextIsPlainAndFriendly() {
        #expect(
            EventLog.notificationRefused
                == "macOS didn't show a notification. Allow notifications for Bifrost in System "
                + "Settings.")
    }

    @Test func aLineAndANoticeKeepTheMaskAndNoToken() {
        var log = EventLog()
        #expect(log.lineText("bad credentials \(token)", at: 1) == "bad credentials ***")
        #expect(log.notice("again \(token)", at: 2).map(LogView.text) == "again ***")
        // The notice counts by its masked text, so another token gives no second notice.
        let other = "github_pat_" + String(repeating: "B", count: 30)
        #expect(log.notice("again \(other)", at: 3) == nil)
        let texts = log.entries.map(LogView.text)
        #expect(!texts.contains { $0.contains("AAAA") || $0.contains("BBBB") })
    }

    @Test func theToolOfAnEventHasTheMask() {
        var log = EventLog()
        let added = log.append([event(1, .postToolUse, tool: "mcp \(token) end")])
        #expect(added.first?.tool == "mcp *** end")
        #expect(log.entries.first?.tool == "mcp *** end")
    }

    // A text from Claude Code can hold a bidi control, which can reverse how the rest of the
    // row reads, or a line break, which breaks the row.
    @Test func theTextsOfTheLogHaveNoHiddenCharacters() {
        var log = EventLog()
        let added = log.append([
            event(1, .postToolUse, tool: "Bash\u{202E}txt.exe"),
            event(2, .postToolUse, tool: "a\u{200B}b\u{0}c\u{7F}d\u{2066}e\u{FEFF}f"),
            event(3, .postToolUse, tool: "one\ntwo\r\nthree\tfour\u{2028}five"),
        ])
        #expect(added.map(\.tool) == ["Bashtxt.exe", "abcdef", "one two  three four five"])
        #expect(log.lineText("x\u{202D}y\nz", at: 1) == "xy z")
    }

    // The mask comes after the clean, so an invisible character inside a token does not stop
    // it: a hidden character of the name rule or a default-ignorable character.
    @Test func aHiddenCharacterInsideATokenDoesNotStopTheMask() {
        var log = EventLog()
        let half = String(repeating: "A", count: 12)
        let splitters = [
            "\u{200B}", "\u{AD}", "\u{2060}", "\u{2062}", "\u{180E}", "\u{34F}", "\u{FE0F}",
            "\u{E0020}", "\u{3164}",
        ]
        for splitter in splitters {
            let split = "ghp_" + half + splitter + half
            #expect(log.append([event(1, .postToolUse, tool: split)]).first?.tool == "***")
            #expect(log.lineText("key \(split)", at: 1) == "key ***")
        }
        let bearer = "Bearer abcdefgh\u{2060}ijklmnop"
        #expect(log.lineText(bearer, at: 1) == "Bearer ***")
    }

    // A visible mark (a combining accent or a no-break space) shows on screen, so it stays, as
    // in the Electron app. The text then has no token of a known form.
    @Test func aVisibleMarkInsideATokenStays() {
        var log = EventLog()
        let half = String(repeating: "A", count: 12)
        #expect(log.lineText("ghp_\(half)\u{301}\(half)", at: 1) == "ghp_\(half)\u{301}\(half)")
        #expect(log.lineText("ghp_\(half)\u{A0}\(half)", at: 2) == "ghp_\(half)\u{A0}\(half)")
    }

    @Test func aLongTextIsCutWithAnEllipsis() {
        #expect(EventLog.textMax == 500)
        var log = EventLog()
        let long = String(repeating: "é", count: 600)
        let detail = log.append([event(1, .postToolUse, tool: long)]).first?.tool ?? ""
        #expect(detail.count == 500)
        #expect(detail == String(repeating: "é", count: 499) + "…")
        let exact = String(repeating: "x", count: 500)
        #expect(log.lineText(exact, at: 1) == exact)
        #expect(log.lineText(exact + "y", at: 2) == String(repeating: "x", count: 499) + "…")
    }

    // The cut comes after the mask, so a cut never leaves a part of a token.
    @Test func theCutNeverLeavesAPartOfAToken() {
        var log = EventLog()
        let text = String(repeating: "x", count: 480) + " " + token
        #expect(log.lineText(text, at: 1) == String(repeating: "x", count: 480) + " ***")
    }
}

extension EventLog {
    // Add a line, and give the text of its entry.
    fileprivate mutating func lineText(_ text: String, at: Int) -> String {
        LogView.text(line(text, at: at))
    }
}
