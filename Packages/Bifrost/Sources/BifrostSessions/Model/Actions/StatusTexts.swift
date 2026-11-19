// The texts of the status icon in the name line of the Selected Item panel
// (docs/behaviour/actions.md, "The Selected Item panel"). The error of the actions, the notice of
// the actions and the line of the send box show in the tooltip of one icon, not as lines under the
// send box.
package struct StatusTexts: Sendable, Equatable {
    // The look of the icon: the error icon or the info icon.
    package enum Kind: Sendable {
        case error, info
    }

    // The texts in order: the error, the notice, then the line of the send box. An empty text is
    // not a line.
    package var lines: [String]
    // The error kind shows for an error of the actions and for a failed send. nil: no text, so no
    // icon.
    package var kind: Kind?

    package init(lines: [String], kind: Kind?) {
        self.lines = lines
        self.kind = kind
    }

    // The texts of the icon. sendFailed is true when the line of the send box is a failed send.
    package static func of(
        error: String?, notice: String?, sendLine: String?, sendFailed: Bool
    ) -> StatusTexts {
        let lines = [error, notice, sendLine].compactMap { $0 }.filter { !$0.isEmpty }
        guard !lines.isEmpty else { return StatusTexts(lines: [], kind: nil) }
        let failed = sendFailed && !(sendLine ?? "").isEmpty
        let hasError = !(error ?? "").isEmpty || failed
        return StatusTexts(lines: lines, kind: hasError ? .error : .info)
    }

    // The tooltip of the icon: each line on its own line.
    package var text: String { lines.joined(separator: "\n") }
}
