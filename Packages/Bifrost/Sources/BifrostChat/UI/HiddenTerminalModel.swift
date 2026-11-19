// The terminal model of a hidden attach (the section "Processes" of the architecture design): a
// SwiftTerm Terminal with no view, at the session size. The session input feeds it each chunk of
// the attach. The model gives the replies of the terminal, for example a cursor position report,
// and the session input writes them to the PTY. So Claude Code gets the answers that a chat window
// gives (docs/behaviour/input.md).
//
// The model draws nothing and has no scrollback. It answers a colour query with the colours of the
// chat terminal. It uses no clipboard, sends no notification and makes no sound: the delegate
// methods for them keep the defaults of SwiftTerm, which do nothing.
//
// It gives no answer to the query of the kitty keyboard protocol (CSI ? u). With no answer, Claude
// Code keeps the legacy form of the keys, so the raw ESC of an Interrupt is the Escape key.
import BifrostLook
import BifrostSessions
import SwiftTerm

@MainActor
public final class HiddenTerminalModel: HiddenTerminal {
    private let replies: ReplySink
    private let terminal: Terminal

    public init(size: TerminalSize) {
        // The colours of a chat terminal (ChatTerminalView): SwiftTerm converts them in the
        // same way for its answers.
        let sink = ReplySink(
            foreground: Color(nsColor: ThemeTokens.text.nsColor),
            background: Color(nsColor: ThemeTokens.terminalBackground.nsColor))
        replies = sink
        terminal = Terminal(
            delegate: sink,
            options: TerminalOptions(
                cols: size.cols, rows: size.rows, scrollback: 0, ansi256PaletteStrategy: .xterm))
    }

    public func feed(_ bytes: [UInt8]) -> [UInt8] {
        terminal.feed(byteArray: bytes)
        return replies.take()
    }
}

// The delegate of the terminal of a hidden attach. It keeps the replies of one feed. It is not
// Sendable: it stays with its model, which uses it only on the main actor.
nonisolated private final class ReplySink: TerminalDelegate {
    private let colours: (foreground: Color, background: Color)
    private var bytes: [UInt8] = []

    init(foreground: Color, background: Color) {
        colours = (foreground, background)
    }

    // SwiftTerm gives each reply in one call.
    func send(source: Terminal, data: ArraySlice<UInt8>) {
        guard !Self.isKittyKeyboardReport(data) else { return }
        bytes.append(contentsOf: data)
    }

    // True for the reply to the kitty keyboard query: CSI ? <digits> u, with the 7-bit CSI (ESC [)
    // or the 8-bit CSI (0x9B).
    static func isKittyKeyboardReport(_ data: ArraySlice<UInt8>) -> Bool {
        var rest = data[...]
        if rest.starts(with: [0x1b, 0x5b]) {
            rest = rest.dropFirst(2)
        } else if rest.first == 0x9b {
            rest = rest.dropFirst()
        } else {
            return false
        }
        guard rest.first == UInt8(ascii: "?"), rest.last == UInt8(ascii: "u") else { return false }
        let digits = rest.dropFirst().dropLast()
        return digits.allSatisfy { $0 >= UInt8(ascii: "0") && $0 <= UInt8(ascii: "9") }
    }

    func getColors(source: Terminal) -> (foreground: Color, background: Color) {
        colours
    }

    // The replies since the last call.
    func take() -> [UInt8] {
        defer { bytes = [] }
        return bytes
    }
}
