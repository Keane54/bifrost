import BifrostChat
import Testing

// The agent view check (docs/behaviour/chat.md, "The agent view"). The reattach cases use
// AgentView.step with an agent view and a target that is ready: the steps reattach and giveUp.

private let countsLine = "0 awaiting input · 0 working · 6 completed"
private let footerLine =
    "enter to return · space to reply · hold space to speak · ctrl+x to delete · ? for shortcuts"
private let promptBox = ["╭───────╮", "│ >     │", "╰───────╯", "  ? for shortcuts"]

@Suite("agent view detection")
struct IsAgentViewTests {
    @Test
    func theAgentViewScreen() {
        let lines = [countsLine, "", "  session one", "  session two", footerLine, "", "", ""]
        #expect(AgentView.isAgentView(lines))
    }

    @Test("a normal prompt screen is not the agent view")
    func aPromptScreen() {
        #expect(!AgentView.isAgentView(["hello"] + promptBox))
    }

    @Test("a footer above the last three lines is not the agent view")
    func aQuotedFooter() {
        let lines = ["> show the screen", countsLine, footerLine, "I quoted it."] + promptBox
        #expect(!AgentView.isAgentView(lines))
    }

    @Test("a footer pasted into the prompt line is not the agent view")
    func aPastedFooter() {
        let lines = [
            countsLine, "", "╭───────╮", "│ > \(footerLine) │", "╰───────╯", "  ? for shortcuts",
        ]
        #expect(!AgentView.isAgentView(lines))
    }

    // A paste of two lines: the counts line on the prompt line, the footer on the next line.
    @Test
    func aTwoLinePasteInABox() {
        let box = ["hello", "╭───────╮", "│ > \(countsLine) │", "│   \(footerLine) │", "╰───────╯"]
        #expect(!AgentView.isAgentView(box + ["  ? for shortcuts"]))
        #expect(!AgentView.isAgentView(box))
    }

    @Test
    func aTwoLinePasteWithRules() {
        let rules = ["hello", "─────────", "> \(countsLine)", "  \(footerLine)", "─────────"]
        #expect(!AgentView.isAgentView(rules + ["  ? for shortcuts"]))
        #expect(!AgentView.isAgentView(rules))
    }

    @Test
    func anEmptyBoxLineAfterTheFooter() {
        let lines = [countsLine, "╭───────╮", "│ \(footerLine) │", "│       │", "╰───────╯"]
        #expect(!AgentView.isAgentView(lines))
    }

    @Test("a pasted footer before the counts line is not the agent view")
    func theFooterFirst() {
        let lines = ["╭───────╮", "│ > \(footerLine) │", "│   \(countsLine) │", "╰───────╯"]
        #expect(!AgentView.isAgentView(lines))
    }

    @Test("a footer framed by box characters is the agent view")
    func aFramedFooter() {
        #expect(AgentView.isAgentView([countsLine, "│ \(footerLine) │"]))
    }

    @Test
    func theLastThreeLines() {
        #expect(AgentView.isAgentView([countsLine, footerLine, "a", "", "b", ""]))
        #expect(!AgentView.isAgentView([countsLine, footerLine, "a", "b", "c"]))
    }

    @Test("the agent view needs the footer and the counts line together")
    func bothLines() {
        #expect(!AgentView.isAgentView(["session", footerLine]))
        #expect(!AgentView.isAgentView([countsLine, "session", "? for shortcuts"]))
    }
}

// The rows of a terminal with the given width for one line of text. The last row has spaces.
// The width counts characters: each character of the two lines is one cell.
private func wrap(_ text: String, _ width: Int) -> [ScreenRow] {
    let characters = Array(text)
    return stride(from: 0, to: characters.count, by: width).map { at in
        let part = String(characters[at..<min(at + width, characters.count)])
        let padded = part + String(repeating: " ", count: width - part.count)
        return ScreenRow(text: padded, wrapped: at > 0)
    }
}

@Suite("joining wrapped lines")
struct JoinWrappedTests {
    @Test
    func joinsTheRows() {
        // At 18 columns, the first footer row is "enter to return · ". It ends with a space.
        let rows =
            wrap(countsLine, 18) + wrap(footerLine, 18)
            + [ScreenRow(text: String(repeating: " ", count: 18), wrapped: false)]
        #expect(rows[3].text == "enter to return · ")
        let lines = AgentView.joinWrapped(rows)
        #expect(lines == [countsLine, footerLine, ""])
        #expect(AgentView.isAgentView(lines))
    }

    @Test
    func aWrappedFirstRow() {
        #expect(AgentView.joinWrapped([ScreenRow(text: "tail  ", wrapped: true)]) == ["tail"])
    }
}

// An instant at a time in milliseconds after a fixed start.
private let origin = ContinuousClock.now
private func at(_ milliseconds: Int) -> ContinuousClock.Instant {
    origin.advanced(by: .milliseconds(milliseconds))
}

// The step of a check that sees the agent view, with a target that is ready.
private func decision(_ history: [Int], _ now: Int) -> AgentStep {
    AgentView.step(
        .watching, agentView: true, targetReady: true, history: history.map(at), now: at(now))
}

@Suite("reattach decision")
struct ReattachDecisionTests {
    @Test("reattach is allowed three times in 60 seconds")
    func threeReattaches() {
        #expect(AgentView.maxReattach == 3)
        #expect(decision([], 100_000) == .reattach)
        #expect(decision([99_000, 99_500], 100_000) == .reattach)
        #expect(decision([98_000, 99_000, 99_500], 100_000) == .giveUp)
    }

    @Test
    func forgetsOldReattaches() {
        #expect(AgentView.reattachWindow == .seconds(60))
        #expect(decision([30_000, 99_000, 99_500], 100_000) == .reattach)
        #expect(decision([40_000, 99_000, 99_500], 100_000) == .reattach)
        #expect(decision([39_000, 99_000, 99_500], 100_000) == .reattach)
        #expect(decision([40_001, 99_000, 99_500], 100_000) == .giveUp)
    }
}

@Suite("recent attaches")
struct RecentAttachesTests {
    @Test
    func dropsOldAttaches() {
        #expect(
            AgentView.recentAttaches([39_999, 40_000, 40_001, 99_000].map(at), now: at(100_000))
                == [40_001, 99_000].map(at))
        #expect(AgentView.recentAttaches([], now: at(100_000)).isEmpty)
    }
}

// The times of the checks for chunks at these times, in milliseconds. A chunk starts the timer
// of the check again.
private func checkTimes(_ chunks: [Int]) -> [Int] {
    var checks: [ContinuousClock.Instant] = []
    var first: ContinuousClock.Instant?
    var due: ContinuousClock.Instant?
    for time in chunks.map(at) {
        if let check = due, check <= time {
            checks.append(check)
            first = nil
        }
        let start = first ?? time
        first = start
        due = time.advanced(by: AgentView.checkDelay(firstAt: start, now: time))
    }
    if let check = due { checks.append(check) }
    return checks.map { Int(origin.duration(to: $0) / .milliseconds(1)) }
}

@Suite("agent view check delay")
struct AgentCheckDelayTests {
    @Test("the check waits for 250 ms of quiet and at most 1000 ms")
    func theDelay() {
        #expect(AgentView.quiet == .milliseconds(250))
        #expect(AgentView.maxWait == .seconds(1))
        #expect(AgentView.checkDelay(firstAt: at(0), now: at(0)) == .milliseconds(250))
        #expect(AgentView.checkDelay(firstAt: at(0), now: at(900)) == .milliseconds(100))
        #expect(AgentView.checkDelay(firstAt: at(0), now: at(1000)) == .zero)
        #expect(AgentView.checkDelay(firstAt: at(0), now: at(1500)) == .zero)
    }

    @Test("a short burst is checked 250 ms after its last chunk")
    func aShortBurst() {
        #expect(checkTimes([0, 100, 200]) == [450])
    }

    @Test("continuous output is checked every 1000 ms")
    func continuousOutput() {
        let chunks = (0..<30).map { $0 * 100 }
        #expect(checkTimes(chunks) == [1000, 2000, 3000])
    }
}

@Suite("the step of an agent view check")
struct AgentStepTests {
    private func screen(
        _ watch: AgentWatch = .watching, agentView: Bool = true, targetReady: Bool = true,
        history: [Int] = []
    ) -> AgentStep {
        AgentView.step(
            watch, agentView: agentView, targetReady: targetReady, history: history.map(at),
            now: at(100_000))
    }

    private func full(_ now: Int) -> [Int] {
        (0..<AgentView.maxReattach).map { now - 1000 * ($0 + 1) }
    }

    @Test("the agent view blocks input and attaches again")
    func reattach() {
        #expect(screen() == .reattach)
        #expect(AgentView.blocks(.reattach))
    }

    @Test("a row that cannot attach keeps the input blocked and waits")
    func wait() {
        #expect(screen(targetReady: false) == .wait)
        #expect(AgentView.blocks(.wait))
    }

    @Test("the window gives up at the attach limit and keeps the input blocked")
    func giveUp() {
        #expect(screen(history: full(100_000)) == .giveUp)
        #expect(AgentView.blocks(.giveUp))
    }

    @Test("closing the agent view during the wait frees the input")
    func free() {
        #expect(screen(.waiting, agentView: false) == .free)
        #expect(!AgentView.blocks(.free))
        #expect(screen(agentView: false) == AgentStep.none)
        #expect(!AgentView.blocks(AgentStep.none))
    }

    @Test("a window that waits sees the agent view again and attaches")
    func waitingSeesTheAgentView() {
        #expect(screen(.waiting) == .reattach)
        #expect(screen(.waiting, targetReady: false) == .wait)
    }

    @Test("a window that gave up does no more checks")
    func gaveUp() {
        #expect(screen(.gaveUp) == AgentStep.none)
        #expect(screen(.gaveUp, agentView: false) == AgentStep.none)
    }
}

// The blank rule of a row. The chat window shows its first text when a row is not blank.
// TextRuleTests checks the white space of one Character.
@Suite("screen row")
struct ScreenRowTests {
    @Test func aBlankRowHasOnlyWhiteSpace() {
        #expect(ScreenRow(text: "", wrapped: false).isBlank)
        #expect(ScreenRow(text: " \t\u{A0}\u{3000}\u{85}\u{2028}", wrapped: true).isBlank)
        #expect(!ScreenRow(text: "  │", wrapped: false).isBlank)
        #expect(!ScreenRow(text: " > hi ", wrapped: false).isBlank)
    }
}
