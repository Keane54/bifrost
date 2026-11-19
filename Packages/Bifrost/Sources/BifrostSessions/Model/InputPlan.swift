// The text that Bifrost types into a session, and the checks on it. The behaviour list is in
// docs/behaviour/input.md. The session input (SessionInput) runs the plan. The send box of phase 4
// uses the same checks to show a reason early.
//
// The length limits count Characters, and white space is Character.isWhitespace (TextRules.swift).
// The clean-up and the slash rule read Unicode scalars: Claude reads the first "/" and each line
// break as they are.
import BifrostFoundation

// Wait the delay, then write data.
package struct InputStep: Sendable, Equatable {
    package var delay: Duration
    package var data: String

    package init(delay: Duration = .zero, data: String) {
        self.delay = delay
        self.data = data
    }
}

// How a slash command goes to the session. A hands-on check found that a paste works.
package enum SlashForm: Sendable, Equatable {
    case paste, typed
}

// The reason why Bifrost does not type a text, or does not rename a session. message is the text
// that the user sees.
public enum InputRefusal: Error, Sendable, Equatable {
    // The text: no text, too long, a slash command with a line break.
    case empty, tooLong, slashLines
    // The rename: no name, or a name that is too long.
    case noName, nameTooLong
    // A red box of a prompt blocks the send.
    case prompt
    // The session: not an owned session that runs, or no process ID yet.
    case notOwned, noPid
    // The attach of the job.
    case noSize, notReady, endedBeforeReady, agentView, chatGone, attachGone, oldAttach
    // An Interrupt cancelled the send before its first write.
    case cancelled

    public var message: String {
        switch self {
        case .empty: "Type a message first."
        case .tooLong: "The text is too long. The maximum is 20,000 characters."
        case .slashLines: "A slash command has one line."
        case .noName: "Type a name first."
        case .nameTooLong: "The name is too long. The maximum is 64 characters."
        case .prompt: "Answer the prompt in the chat window first."
        case .notOwned: "Bifrost can only type into a session that it started and that is running."
        case .noPid: "The session is still starting. Try again in a moment."
        case .noSize:
            "Bifrost cannot read the session size. Open the chat window and send from there."
        case .notReady: "The session did not get ready in 15 seconds. Bifrost sent nothing."
        case .endedBeforeReady:
            "The connection to the session ended before it was ready. Bifrost sent nothing."
        case .agentView:
            "The chat window shows the agent view. Close the window and open it again."
        case .chatGone: "The chat window closed during the send."
        case .attachGone: "The connection to the session ended during the send."
        case .oldAttach:
            "The chat window shows an old connection to the session. Close the window and open "
                + "it again."
        case .cancelled: "Interrupt stopped the send before it went."
        }
    }
}

// The steps that send a text, or the reason why the text cannot go.
package enum InputPlan: Sendable, Equatable {
    case ready(slash: Bool, steps: [InputStep])
    case refused(InputRefusal)

    package static let pasteStart = "\u{1b}[200~"
    package static let pasteEnd = "\u{1b}[201~"
    package static let cr = "\r"
    package static let esc = "\u{1b}"

    // The gap between the text and the CR. A hands-on check found that 300 ms works for a paste.
    package static let pasteCRDelay = Duration.milliseconds(300)
    package static let typedCRDelay = Duration.milliseconds(500)
    package static let maxText = 20_000
    package static let maxRename = 64

    package static let slashForm = SlashForm.paste

    // Interrupt sends one Esc. Two Esc open the rewind menu.
    package static let interruptSteps = [InputStep(data: esc)]

    // Make the steps that send the text. Each plan writes the text first, then CR. No plan has
    // only a CR, so Bifrost never sends CR to an empty prompt. The length limit applies to the
    // text as the user typed it, before the clean-up. So the send box can count the Characters
    // itself, and a large text costs no clean-up time.
    package static func plan(_ text: String, form: SlashForm = slashForm) -> InputPlan {
        guard text.count <= maxText else { return .refused(.tooLong) }
        let t = clean(text).trimmed()
        guard let first = t.unicodeScalars.first else { return .refused(.empty) }
        let slash = first == "/"
        if slash && t.unicodeScalars.contains("\n") { return .refused(.slashLines) }
        if slash && form == .typed {
            return .ready(
                slash: slash, steps: [InputStep(data: t), InputStep(delay: typedCRDelay, data: cr)])
        }
        // A terminal changes each line break in a paste to CR. This plan does the same. After the
        // clean-up, each line break is one LF.
        let body = t.replacing("\n", with: "\r")
        return .ready(
            slash: slash,
            steps: [
                InputStep(data: pasteStart + body + pasteEnd),
                InputStep(delay: pasteCRDelay, data: cr),
            ])
    }

    // Change CRLF and a lone CR to LF. Then remove the control characters: C0 without tab and
    // LF, DEL and C1. Keep tab and LF. The text cannot hold ESC, so it cannot end the paste early
    // or press a key.
    package static func clean(_ text: String) -> String {
        var result = String.UnicodeScalarView()
        var afterCR = false
        for scalar in text.unicodeScalars {
            defer { afterCR = scalar == "\r" }
            if scalar == "\n" && afterCR { continue }
            if scalar == "\r" {
                result.append("\n")
            } else if !isControl(scalar) {
                result.append(scalar)
            }
        }
        return String(result)
    }

    // The slash command that renames a session (the Rename action). Each run of white space
    // becomes one space. The 64 Character limit applies to the name after the clean-up. A name
    // that is longer than maxText gets no clean-up.
    package static func rename(_ name: String) -> Result<String, InputRefusal> {
        guard name.count <= maxText else { return .failure(.nameTooLong) }
        var collapsed = ""
        for character in clean(name) {
            if !character.isWhitespace {
                collapsed.append(character)
            } else if collapsed.last != " " {
                collapsed.append(" ")
            }
        }
        let n = collapsed.trimmed()
        guard !n.isEmpty else { return .failure(.noName) }
        guard n.count <= maxRename else { return .failure(.nameTooLong) }
        return .success("/rename \(n)")
    }

    // The control characters that the text cannot hold: U+0000 to U+0008, U+000B to U+001F and
    // U+007F to U+009F.
    private static func isControl(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x00...0x08, 0x0B...0x1F, 0x7F...0x9F: true
        default: false
        }
    }
}
