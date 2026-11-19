import BifrostSessions
import CoreGraphics
import Testing

@testable import BifrostChat

// The geometry of the terminal of a chat window: a cell of 8 x 16 points, with and with no scroll
// bar of 15 points.
@Suite("terminal fit")
struct TerminalFitTests {
    private let plain = TerminalFit(cell: CGSize(width: 8, height: 16), scrollBar: 0)
    private let withBar = TerminalFit(cell: CGSize(width: 8, height: 16), scrollBar: 15)

    @Test func theCellIsTheOptimalFrameLessTheScrollBarOverTheGrid() {
        let fit = TerminalFit(
            optimalFrame: CGSize(width: 815, height: 512), cols: 100, rows: 32, scrollBar: 15)
        #expect(fit == withBar)
        let noGrid = TerminalFit(
            optimalFrame: CGSize(width: 815, height: 512), cols: 0, rows: 32, scrollBar: 15)
        #expect(noGrid.cell == .zero)
    }

    @Test func theFitIsTheWholeCellsOfThePanel() {
        let panel = CGSize(width: 803, height: 607)
        #expect(plain.size(fitting: panel) == TerminalSize(cols: 100, rows: 37))
        // The scroll bar takes 15 points of the width.
        #expect(withBar.size(fitting: panel) == TerminalSize(cols: 98, rows: 37))
    }

    @Test func noPanelNoCellOrLessThanOneCellGivesNoFit() {
        #expect(plain.size(fitting: nil) == nil)
        #expect(plain.size(fitting: CGSize(width: 7, height: 100)) == nil)
        #expect(plain.size(fitting: CGSize(width: 100, height: 15)) == nil)
        #expect(withBar.size(fitting: CGSize(width: 22, height: 100)) == nil)
        let noCell = TerminalFit(cell: .zero, scrollBar: 0)
        #expect(noCell.size(fitting: CGSize(width: 800, height: 600)) == nil)
    }

    @Test func theScreenSizeHasTheScrollBarAndTheFrameHasHalfAPointOfSlack() {
        let size = TerminalSize(cols: 100, rows: 30)
        #expect(plain.screen(size) == CGSize(width: 800, height: 480))
        #expect(withBar.screen(size) == CGSize(width: 815, height: 480))
        #expect(withBar.frame(size) == CGSize(width: 815.5, height: 480.5))
        let noCell = TerminalFit(cell: .zero, scrollBar: 15)
        #expect(noCell.screen(size) == nil)
        #expect(noCell.frame(size) == nil)
    }
}
