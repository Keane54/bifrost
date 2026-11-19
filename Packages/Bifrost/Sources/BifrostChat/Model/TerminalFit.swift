import BifrostSessions
import CoreGraphics

// The geometry of the terminal of a chat window, in points: the size of one cell and the width of
// the scroll bar. The scroll bar shows on the right of the grid and takes a part of the width. It
// gives the size that fits a panel, the size of a grid on the screen (for the zoom) and the frame
// of the terminal view for a size.
package struct TerminalFit: Sendable, Equatable {
    // The size of one cell. Zero when the terminal has no grid.
    package var cell: CGSize
    // The width of the scroll bar while it shows, else 0.
    package var scrollBar: CGFloat

    package init(cell: CGSize, scrollBar: CGFloat) {
        self.cell = cell
        self.scrollBar = scrollBar
    }

    // The cell from the optimal frame size of SwiftTerm, which holds the grid of cols x rows and
    // the scroll bar.
    package init(optimalFrame: CGSize, cols: Int, rows: Int, scrollBar: CGFloat) {
        self.scrollBar = scrollBar
        guard cols > 0, rows > 0 else {
            cell = .zero
            return
        }
        cell = CGSize(
            width: (optimalFrame.width - scrollBar) / CGFloat(cols),
            height: optimalFrame.height / CGFloat(rows))
    }

    // The largest size of whole cells that fits the panel, or nil: no panel, no cell, or less
    // than one cell.
    package func size(fitting panel: CGSize?) -> TerminalSize? {
        guard let panel, hasCell else { return nil }
        let cols = Int(((panel.width - scrollBar) / cell.width).rounded(.down))
        let rows = Int((panel.height / cell.height).rounded(.down))
        guard cols >= 1, rows >= 1 else { return nil }
        return TerminalSize(cols: cols, rows: rows)
    }

    // The size of the grid of a terminal size on the screen, with the scroll bar, or nil with no
    // cell.
    package func screen(_ size: TerminalSize) -> CGSize? {
        guard hasCell else { return nil }
        return CGSize(
            width: cell.width * CGFloat(size.cols) + scrollBar,
            height: cell.height * CGFloat(size.rows))
    }

    // The frame size of the terminal view for a terminal size, or nil with no cell. SwiftTerm
    // takes the whole cells of the frame, so the frame gets a slack of half a point.
    package func frame(_ size: TerminalSize) -> CGSize? {
        screen(size).map { CGSize(width: $0.width + 0.5, height: $0.height + 0.5) }
    }

    private var hasCell: Bool { cell.width > 0 && cell.height > 0 }
}
