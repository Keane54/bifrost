// The rules of the session size read (docs/behaviour/pty.md, "The size of a session"). The size of
// a session is the terminal size that other clients set. Bifrost only reads it, with the process
// APIs of macOS (ProcessInspector). It starts no program and never writes to a TTY.
package enum SessionSizeText {
    // The path of a terminal device from its name, as devname gives it. Only a pseudo-terminal
    // gives a path: "ttys012" gives "/dev/ttys012". "??", an empty name and other text give nil.
    package static func device(name: String) -> String? {
        let number = name.dropFirst("ttys".count)
        guard name.hasPrefix("ttys"), isNumber(number) else { return nil }
        return "/dev/\(name)"
    }

    // The size from the rows and the columns of a terminal (the winsize of TIOCGWINSZ). A size
    // that is not valid (TerminalSize.isValid), for example 0 rows, gives nil.
    package static func size(rows: Int, cols: Int) -> TerminalSize? {
        let size = TerminalSize(cols: cols, rows: rows)
        return size.isValid ? size : nil
    }

    // True for one or more ASCII digits.
    private static func isNumber(_ text: Substring) -> Bool {
        !text.isEmpty && text.utf8.allSatisfy { $0 >= UInt8(ascii: "0") && $0 <= UInt8(ascii: "9") }
    }
}
