// The rules of the text that a chat writes to its pseudo-terminal: the keys of the user, the
// text of the hold key and the writes of dictation. They read the data as Unicode scalars, as
// the terminal sends it. ChatInput reads the cursor keys, and the typer of dictation reads the
// end of the typed text for its leading space.
package enum PTYText {
    // True when the data has a cursor key: ESC [ or ESC O, then A, B, C or D. CSI keys can have
    // parameters, for example Ctrl+Right. The replies of the terminal end with other letters.
    package static func movesCursor(_ data: String) -> Bool {
        let scalars = Array(data.unicodeScalars)
        var i = 0
        while i < scalars.count {
            defer { i += 1 }
            guard scalars[i] == "\u{1B}", i + 1 < scalars.count else { continue }
            var j = i + 2
            if scalars[i + 1] == "[" {
                while j < scalars.count, ("0"..."9").contains(scalars[j]) || scalars[j] == ";" {
                    j += 1
                }
            } else if scalars[i + 1] != "O" {
                continue
            }
            if j < scalars.count, ("A"..."D").contains(scalars[j]) { return true }
        }
        return false
    }

    // The most Characters that typedTail keeps.
    private static let maxTail = 1000
    private static let esc: Unicode.Scalar = "\u{1B}"

    // The length in scalars of the escape sequence at index i of the scalars. scalars[i] is ESC.
    private static func escapeLength(_ scalars: [Unicode.Scalar], _ i: Int) -> Int {
        guard i + 1 < scalars.count else { return 1 }
        let next = scalars[i + 1]
        // CSI: the parameter and intermediate bytes, then one final character.
        if next == "[" {
            var j = i + 2
            while j < scalars.count, (0x20...0x3F).contains(scalars[j].value) { j += 1 }
            return min(j + 1, scalars.count) - i
        }
        // OSC, DCS, SOS, PM and APC: a string up to BEL or ST.
        if ["]", "P", "X", "^", "_"].contains(next) {
            var j = i + 2
            while j < scalars.count {
                if scalars[j] == "\u{07}" { return j + 1 - i }
                if scalars[j] == esc, j + 1 < scalars.count, scalars[j + 1] == "\\" {
                    return j + 2 - i
                }
                j += 1
            }
            return scalars.count - i
        }
        // SS3 and its key, or ESC and one character.
        return min(next == "O" ? 3 : 2, scalars.count - i)
    }

    private static func isControl(_ scalar: Unicode.Scalar) -> Bool {
        scalar.value < 0x20 || (0x7F...0x9F).contains(scalar.value)
    }

    // The end of the text that the user typed into the prompt, after one more write to the PTY.
    // The typer of dictation reads it for its leading space.
    // - The escape sequences go, for example the arrow keys, the bracket marks of a paste and the
    //   replies of the terminal. ESC and CR is the new line of Shift+Enter
    //   (KeyRoute.newLineText).
    // - A DEL or a backspace removes one Character. Enter adds a new line.
    // - Ctrl+C and Ctrl+U clear the line in Claude's prompt. The other control characters go.
    // - The tail keeps the last 1,000 Characters.
    package static func typedTail(_ tail: String, _ data: String) -> String {
        var next = tail
        let scalars = Array(data.unicodeScalars)
        var deletes = 0
        func applyDeletes() {
            if deletes > 0 { next = String(next.dropLast(deletes)) }
            deletes = 0
        }
        var i = 0
        while i < scalars.count {
            let scalar = scalars[i]
            if scalar == "\u{7F}" || scalar == "\u{08}" {
                deletes += 1
                i += 1
                continue
            }
            applyDeletes()
            if scalar == esc, i + 1 < scalars.count, scalars[i + 1] == "\r" {
                next.append("\n")
                i += 2
            } else if scalar == esc {
                i += escapeLength(scalars, i)
            } else {
                if scalar == "\r" || scalar == "\n" {
                    next.append("\n")
                } else if scalar == "\u{03}" || scalar == "\u{15}" {
                    next = ""
                } else if !isControl(scalar) {
                    next.unicodeScalars.append(scalar)
                }
                i += 1
            }
        }
        applyDeletes()
        return String(next.suffix(maxTail))
    }
}
