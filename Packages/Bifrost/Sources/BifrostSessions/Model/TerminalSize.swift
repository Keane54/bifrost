// The size of a terminal in columns and rows.
public struct TerminalSize: Sendable, Equatable {
    package var cols: Int
    package var rows: Int

    package init(cols: Int, rows: Int) {
        self.cols = cols
        self.rows = rows
    }

    // The largest number of columns or rows that a PTY gets. A 5K screen with a small font can
    // have more than 500 columns.
    package static let maximum = 1000

    // True for a number of columns or rows that a PTY accepts: 1 to 1000.
    package static func isValid(_ n: Int) -> Bool {
        n >= 1 && n <= maximum
    }

    // True when the columns and the rows are both valid.
    package var isValid: Bool { Self.isValid(cols) && Self.isValid(rows) }
}
