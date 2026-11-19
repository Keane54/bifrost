import BifrostSessions
import BifrostWindows
import Testing

// The cell texts and tones of the Overview (the section "Cell texts" of
// docs/behaviour/overview.md).

@Suite("overview format")
struct OverviewFormatTests {
    // Each row shows the label of its state.
    @Test func theStateLabels() {
        #expect(OverviewFormat.stateLabel(.working) == "Working")
        #expect(OverviewFormat.stateLabel(.needsYou) == "Alert")
        #expect(OverviewFormat.stateLabel(.error) == "Error")
        #expect(OverviewFormat.stateLabel(.idle) == "Idle")
        #expect(OverviewFormat.stateLabel(.parked) == "Parked")
    }

    @Test func theShownContextBandUsesTheRoundedPercent() {
        #expect(OverviewFormat.shownContextBand(39.4) == .low)
        #expect(OverviewFormat.shownContextBand(39.6) == .mid)
        #expect(OverviewFormat.shownContextBand(69.6) == .high)
        #expect(OverviewFormat.shownContextBand(39.5) == .mid)
        #expect(OverviewFormat.shownContextBand(nil) == nil)
        #expect(OverviewFormat.shownContextBand(.nan) == nil)
    }

    @Test func theContextBandIsLowBelow40MidBelow70AndHighFrom70() {
        #expect(OverviewFormat.contextBand(0) == .low)
        #expect(OverviewFormat.contextBand(39.9) == .low)
        #expect(OverviewFormat.contextBand(40) == .mid)
        #expect(OverviewFormat.contextBand(69.9) == .mid)
        #expect(OverviewFormat.contextBand(70) == .high)
        #expect(OverviewFormat.contextBand(100) == .high)
        #expect(OverviewFormat.contextBand(nil) == nil)
        #expect(OverviewFormat.contextBand(.nan) == nil)
        #expect(OverviewFormat.contextBand(.infinity) == nil)
    }

    @Test func theProjectLabelIsTheLastTwoPartsOfThePath() {
        #expect(OverviewFormat.projectLabel("/Users/o/Developer/bifrost") == "Developer/bifrost")
        #expect(OverviewFormat.projectLabel("/a") == "a")
        #expect(OverviewFormat.projectLabel("/") == "/")
        #expect(OverviewFormat.projectLabel("//") == "/")
        #expect(OverviewFormat.projectLabel("") == "")
        #expect(OverviewFormat.projectLabel("/x/y/") == "x/y")
        #expect(OverviewFormat.projectLabel("a//b") == "a/b")
    }

    @Test func theProjectLabelOfAClaudeWorktreeIsItsRepository() {
        #expect(
            OverviewFormat.projectLabel("/Users/o/Developer/bifrost/.claude/worktrees/fix-a")
                == "Developer/bifrost")
        #expect(
            OverviewFormat.projectLabel("/Users/o/Developer/bifrost/.claude/worktrees/fix-a/src")
                == "Developer/bifrost")
    }

    @Test func theCostAndPercentTexts() {
        #expect(OverviewFormat.cost(0.4249) == "≈$0.42")
        #expect(OverviewFormat.cost(0) == "≈$0.00")
        #expect(OverviewFormat.percent(41.6) == "42%")
        #expect(OverviewFormat.percent(0) == "0%")
    }

    @Test func aCostOrPercentWithNoFiniteValueHasNoText() {
        #expect(OverviewFormat.cost(nil) == "")
        #expect(OverviewFormat.cost(.nan) == "")
        #expect(OverviewFormat.percent(nil) == "")
        #expect(OverviewFormat.percent(.nan) == "")
        #expect(OverviewFormat.percent(.infinity) == "")
    }

    // A half rounds up, also below zero.
    @Test func thePercentRoundsAHalfUp() {
        #expect(OverviewFormat.percent(2.5) == "3%")
        #expect(OverviewFormat.percent(-2.5) == "-2%")
        #expect(OverviewFormat.percent(-0.4) == "0%")
        #expect(OverviewFormat.percent(0.49999999999999994) == "0%")
    }

    @Test func aCostAbove0AndBelowOneCentIsBelowOneCent() {
        #expect(OverviewFormat.cost(0.0042) == "<$0.01")
        #expect(OverviewFormat.cost(0.0099) == "<$0.01")
        #expect(OverviewFormat.cost(0.00001) == "<$0.01")
        #expect(OverviewFormat.cost(0.01) == "≈$0.01")
    }

    // The cost from Claude Code is a simulated API cost, so it has the mark of an approximate
    // value. The text keeps two decimals.
    @Test func theCostHasTheApproximateMark() {
        #expect(OverviewFormat.cost(1.234) == "≈$1.23")
        #expect(OverviewFormat.cost(12) == "≈$12.00")
        #expect(OverviewFormat.cost(1234.5) == "≈$1234.50")
        #expect(OverviewFormat.cost(.infinity) == "")
        #expect(OverviewFormat.cost(-1) == "≈$-1.00")
    }

    // A cost exactly halfway between two cent values goes up. A cost a little below the half
    // goes down.
    @Test func aCostExactlyHalfwayRoundsUp() {
        #expect(OverviewFormat.cost(0.125) == "≈$0.13")
        #expect(OverviewFormat.cost(0.375) == "≈$0.38")
        #expect(OverviewFormat.cost(0.625) == "≈$0.63")
        #expect(OverviewFormat.cost(2.875) == "≈$2.88")
        #expect(OverviewFormat.cost(1.005) == "≈$1.00")
        #expect(OverviewFormat.cost(0.995) == "≈$0.99")
    }

    // A cell has 4 units of padding on each side, and a character is 7.2 units wide. The default
    // width of the Cost column holds a cost of three digits with the mark.
    @Test func theDefaultCostWidthHoldsACostOfThreeDigits() {
        let text = OverviewFormat.cost(123.45)
        #expect(Double(text.count) * 7.2 + 8 <= OverviewColumn.cost.defaultWidth)
    }

    @Test func theBarFillIsFrom0To100() {
        #expect([41.6, -5, 140].map { OverviewFormat.barFill($0) } == [41.6, 0, 100])
        #expect(OverviewFormat.barFill(nil) == 0)
        #expect(OverviewFormat.barFill(.nan) == 0)
    }

    @Test func theStateToneIsRedForAnErrorAndARedBoxAndYellowForAYellowBox() {
        func tone(_ state: SessionState, _ alert: SessionAlert = .none) -> Tone {
            OverviewFormat.stateTone(overviewRow("a", state: state, alert: alert))
        }
        #expect(tone(.needsYou, .yellow(since: 1)) == .yellow)
        #expect(tone(.needsYou, .red(.prompt, since: 1)) == .red)
        #expect(tone(.needsYou) == .red)
        #expect(tone(.error) == .red)
        #expect(tone(.working) == .active)
        #expect(tone(.idle) == .dim)
        #expect(tone(.parked) == .parked)
    }

    @Test func thePreviewIsTheFirstThreeLinesWithText() {
        #expect(OverviewFormat.previewLines("\n a \n\nb\nc\nd") == ["a", "b", "c"])
        #expect(OverviewFormat.previewLines(nil) == [])
        #expect(OverviewFormat.previewLines("") == [])
        #expect(OverviewFormat.previewLines(" \n\t\n") == [])
        #expect(OverviewFormat.previewLines("a\r\nb\r\n") == ["a", "b"])
        #expect(OverviewFormat.previewLines("a\nb\nc", max: 1) == ["a"])
        #expect(OverviewFormat.previewLines("a\nb", max: 0) == [])
    }
}
