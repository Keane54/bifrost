import BifrostFoundation

// The form of a slash command that the app keeps: a command in the settings or in the history of
// the New session dialog. The start and the line breaks read Unicode scalars, as Claude reads
// them, and the length limit counts Characters (TextRules.swift).
package enum SlashCommand {
    package static let maxLength = 200

    // Why a text is not a slash command.
    package enum Refusal: Error, Sendable, Equatable {
        // The text does not start with "/" and then a character that is not white space.
        case start
        // The text has a CR or an LF.
        case lines
        // The text has more than maxLength Characters.
        case tooLong
    }

    // The trimmed text when it is a slash command: it starts with "/", the next character is
    // not white space, it has no CR or LF and not more than maxLength Characters.
    package static func clean(_ text: String) throws(Refusal) -> String {
        let command = text.trimmed()
        let scalars = Array(command.unicodeScalars.prefix(2))
        guard scalars.count == 2, scalars[0] == "/", !scalars[1].properties.isWhitespace else {
            throw .start
        }
        if command.unicodeScalars.contains(where: { $0 == "\r" || $0 == "\n" }) {
            throw .lines
        }
        if command.count > maxLength { throw .tooLong }
        return command
    }
}
