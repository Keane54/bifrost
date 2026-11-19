import AppKit
import BifrostSessions
import BifrostTestSupport
import Testing

@testable import BifrostLook
@testable import BifrostWindows

// The content of the cells (CellContent): the texts, the colours of the state labels, the
// priorities and a parked row, and the tooltip of the Project cell.
@Suite("Overview cells", .tags(.window))
@MainActor
struct OverviewCellsTests {
    init() { UITestApp.prepare() }

    private func colour(_ row: SessionRow, _ column: OverviewColumn) -> TokenColour {
        CellContent.of(row, column, now: 0).textColour(parked: row.state == .parked)
    }

    private func row(_ state: SessionState, alert: SessionAlert = .none) -> SessionRow {
        var row = SessionRow.test(state: state)
        row.alert = alert
        return row
    }

    @Test func theStateLabelsHaveTheColoursOfTheirTone() {
        #expect(colour(row(.working), .state) == ThemeTokens.textStrong)
        #expect(colour(row(.needsYou), .state) == ThemeTokens.boxRed)
        #expect(colour(row(.needsYou, alert: .yellow(since: 1)), .state) == ThemeTokens.boxYellow)
        #expect(
            colour(row(.needsYou, alert: .red(.prompt, since: 1)), .state) == ThemeTokens.boxRed)
        #expect(colour(row(.error), .state) == ThemeTokens.boxRed)
        #expect(colour(row(.idle), .state) == ThemeTokens.textDim)
        #expect(colour(row(.parked), .state) == ThemeTokens.parked)
        #expect(CellContent.of(row(.needsYou), .state, now: 0).text == "Alert")
    }

    @Test func aPriorityHasItsColour() {
        for priority in SessionPriority.allCases {
            var row = SessionRow.test()
            row.priority = priority
            let content = CellContent.of(row, .priority, now: 0)
            #expect(content.text == "\(priority.rawValue)")
            #expect(
                content.textColour(parked: false)
                    == ThemeTokens.priorities[priority.rawValue - 1])
        }
        #expect(CellContent.of(SessionRow.test(), .priority, now: 0).text.isEmpty)
    }

    // A parked row has the parked colour, except for the cells with a colour of their own.
    @Test func aParkedRowHasTheParkedTextColour() {
        var parked = row(.parked)
        parked.priority = .p1
        #expect(colour(parked, .name) == ThemeTokens.parked)
        #expect(colour(parked, .project) == ThemeTokens.parked)
        #expect(colour(parked, .priority) == ThemeTokens.priorities[0])
        #expect(colour(row(.idle), .name) == ThemeTokens.text)
    }

    @Test func theProjectCellHasTheFolderAsItsTooltip() {
        let content = CellContent.of(SessionRow.test(cwd: "/work/demo/app"), .project, now: 0)
        #expect(content.text == "demo/app")
        #expect(content.tooltip == "/work/demo/app")
        #expect(CellContent.of(SessionRow.test(cwd: ""), .project, now: 0).tooltip == nil)
        #expect(CellContent.of(SessionRow.test(), .name, now: 0).tooltip == nil)
        // The cell view gives the tooltip to the Bifrost tooltip, and a reused cell drops it.
        let cell = OverviewTextCell(frame: NSRect(x: 0, y: 0, width: 200, height: 22))
        let metrics = CanvasMetrics(interfaceScale: 100)
        cell.show(content, parked: false, metrics: metrics)
        #expect(TooltipController.shared.text(of: cell) == "/work/demo/app")
        cell.show(CellContent("alpha"), parked: false, metrics: metrics)
        #expect(TooltipController.shared.text(of: cell) == nil)
    }
}
