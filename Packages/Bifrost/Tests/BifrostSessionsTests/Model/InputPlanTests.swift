// The text that Bifrost types into a session and the
// checks on it (docs/behaviour/input.md).
import Testing

@testable import BifrostSessions

// The paste body of a plan, or nil for a plan that is not a paste.
private func pasteBody(_ text: String) -> String? {
    guard case .ready(_, let steps) = InputPlan.plan(text), let first = steps.first?.data,
        first.hasPrefix(InputPlan.pasteStart), first.hasSuffix(InputPlan.pasteEnd)
    else { return nil }
    let scalars = Array(first.unicodeScalars)
    let start = InputPlan.pasteStart.unicodeScalars.count
    let end = scalars.count - InputPlan.pasteEnd.unicodeScalars.count
    var body = String.UnicodeScalarView()
    body.append(contentsOf: scalars[start..<end])
    return String(body)
}

private func step(_ data: String, _ milliseconds: Int) -> InputStep {
    InputStep(delay: .milliseconds(milliseconds), data: data)
}

// A text of one scalar between a and b.
private func between(_ code: UInt32) -> String {
    guard let scalar = Unicode.Scalar(code) else { return "" }
    return "a\(Character(scalar))b"
}

@Suite("the input values")
struct InputValuesTests {
    @Test("the markers, keys and texts have the designed values")
    func values() {
        #expect(InputPlan.pasteStart == "\u{1b}[200~")
        #expect(InputPlan.pasteEnd == "\u{1b}[201~")
        #expect(InputPlan.cr == "\r")
        #expect(InputPlan.esc == "\u{1b}")
        #expect(InputPlan.maxText == 20_000)
        #expect(InputPlan.maxRename == 64)
        #expect(InputRefusal.prompt.message == "Answer the prompt in the chat window first.")
        #expect(InputPlan.interruptSteps == [step("\u{1b}", 0)])
    }

    @Test("the slash form is the paste form")
    func slashForm() {
        #expect(InputPlan.slashForm == .paste)
    }
}

@Suite("text plan")
struct PlanTextTests {
    @Test("text goes in as a bracketed paste, then CR after 300 ms")
    func paste() {
        #expect(
            InputPlan.plan("Reply with OK")
                == .ready(
                    slash: false,
                    steps: [step("\u{1b}[200~Reply with OK\u{1b}[201~", 0), step("\r", 300)]))
    }

    @Test("each line break in a paste becomes CR")
    func lineBreaks() {
        #expect(pasteBody("a\nb\r\nc\rd") == "a\rb\rc\rd")
    }

    @Test("escape and control characters are removed")
    func controls() {
        #expect(pasteBody("a\u{1b}[201~b\u{03}c\u{7f}d\u{9b}e\tf") == "a[201~bcde\tf")
    }

    @Test("empty text is refused and CR never goes alone")
    func empty() {
        for text in ["", " \n\t ", "\u{1b}\u{03}"] {
            #expect(InputPlan.plan(text) == .refused(.empty))
        }
        #expect(InputRefusal.empty.message == "Type a message first.")
    }

    @Test("the text is trimmed")
    func trims() {
        #expect(pasteBody("  hi  \n") == "hi")
    }

    @Test("text over 20,000 characters is refused")
    func tooLong() {
        let refused = InputPlan.refused(.tooLong)
        #expect(InputPlan.plan(String(repeating: "a", count: 20_000)) != refused)
        #expect(InputPlan.plan(String(repeating: "a", count: 20_001)) == refused)
        // The limit applies to the text as the user typed it, before the clean-up and the trim.
        #expect(InputPlan.plan(String(repeating: "a", count: 20_000) + " ") == refused)
        #expect(InputPlan.plan(String(repeating: " ", count: 20_001)) == refused)
        #expect(
            InputRefusal.tooLong.message
                == "The text is too long. The maximum is 20,000 characters.")
    }

    @Test("a slash command goes in the typed form")
    func typedForm() {
        #expect(
            InputPlan.plan("/compact", form: .typed)
                == .ready(slash: true, steps: [step("/compact", 0), step("\r", 500)]))
        #expect(
            InputPlan.plan("/compact", form: .paste)
                == .ready(
                    slash: true,
                    steps: [step("\u{1b}[200~/compact\u{1b}[201~", 0), step("\r", 300)]))
    }

    @Test("a slash command with a line break is refused")
    func slashLines() {
        for form in [SlashForm.paste, .typed] {
            #expect(
                InputPlan.plan("/compact\nnow", form: form)
                    == .refused(.slashLines))
        }
        #expect(InputRefusal.slashLines.message == "A slash command has one line.")
    }

    @Test
    func crAfterText() {
        for text in ["x", "/x", " y\n", "a\u{1b}b"] {
            for form in [SlashForm.paste, .typed] {
                guard case .ready(_, let steps) = InputPlan.plan(text, form: form) else {
                    Issue.record("no plan for \(text.debugDescription)")
                    continue
                }
                #expect(steps.count == 2)
                #expect(steps.first?.data != InputPlan.cr)
                #expect(steps.first?.data.isEmpty == false)
                #expect(steps.last?.data == InputPlan.cr)
            }
        }
    }
}

@Suite("text cleaning")
struct CleanTextTests {
    @Test("clean text keeps tab and LF and turns CRLF and CR into LF")
    func keeps() {
        #expect(InputPlan.clean("a\tb\nc\r\nd\re") == "a\tb\nc\nd\ne")
    }

    @Test("clean text removes C0, C1 and DEL")
    func removes() {
        let removed = Array(0..<9) + Array(0x0b..<0x20).filter { $0 != 0x0d } + Array(0x7f..<0xa0)
        for code in removed {
            #expect(InputPlan.clean(between(UInt32(code))) == "ab", "\(code)")
        }
        // A no-break space (U+00A0) and a dash (U+2014) are not control characters. They stay.
        let kept = "a\u{a0}b\u{2014}c"
        #expect(InputPlan.clean(kept) == kept)
    }
}

@Suite("rename text")
struct RenameTextTests {
    @Test("rename text is /rename and the name")
    func gives() {
        #expect(InputPlan.rename(" new\n name ") == .success("/rename new name"))
        #expect(InputPlan.rename("a\u{1b}[201~b") == .success("/rename a[201~b"))
        let x64 = String(repeating: "x", count: 64)
        #expect(InputPlan.rename(x64) == .success("/rename \(x64)"))
    }

    @Test("rename refuses an empty name and a name over 64 characters")
    func refuses() {
        let noName = Result<String, InputRefusal>.failure(.noName)
        let long = Result<String, InputRefusal>.failure(.nameTooLong)
        #expect(InputPlan.rename(" \n\t\u{1b} ") == noName)
        #expect(InputPlan.rename(String(repeating: "x", count: 65)) == long)
        // The 64 character limit applies after the clean-up, so runs of spaces count as one.
        #expect(InputPlan.rename("a" + String(repeating: " ", count: 100) + "b") == .success(
            "/rename a b"))
        #expect(InputPlan.rename(String(repeating: " ", count: 20_001)) == long)
        #expect(InputRefusal.noName.message == "Type a name first.")
        #expect(
            InputRefusal.nameTooLong.message
                == "The name is too long. The maximum is 64 characters.")
    }
}

@Suite("prompt blocks")
struct PromptBlocksTests {
    @Test("only a red box of a prompt blocks")
    func blocks() {
        #expect(SessionAlert.red(.prompt, since: 1).blocksPrompt)
        #expect(!SessionAlert.red(.escalated, since: 1).blocksPrompt)
        #expect(!SessionAlert.red(.error, since: 1).blocksPrompt)
        #expect(!SessionAlert.yellow(since: 1).blocksPrompt)
        #expect(!SessionAlert.none.blocksPrompt)
    }
}

// InputTextRuleTests checks the length limits with emoji and combined letters.
@Suite("input: the slash rule")
struct InputSlashTests {
    // A slash with a combining mark is one Character, but the text starts with the scalar "/",
    // as Claude reads it. A line break is found on the Unicode scalars.
    @Test func theSlashRuleReadsUnicodeScalars() {
        guard case .ready(let slash, _) = InputPlan.plan("/\u{301}x") else {
            Issue.record("no plan")
            return
        }
        #expect(slash)
        #expect(InputPlan.plan("/a\n\u{301}") == .refused(.slashLines))
    }
}
