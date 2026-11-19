// The rules of the Rename dialog (docs/behaviour/actions.md, "Rename"). The dialog only shows
// what these rules give.
import BifrostFoundation

// The controls of the Rename dialog for a row.
package struct RenameControls: Sendable, Equatable {
    // The check box "Also rename it in Claude Code".
    package enum Box: Sendable, Equatable {
        // The row cannot take /rename: it is not an owned session that runs.
        case hidden
        case enabled
        // The row can take /rename, but not now. The refusal gives the reason that the dialog
        // shows.
        case disabled(ActionRefusal)

        package var reason: String? {
            if case .disabled(let refusal) = self { refusal.message } else { nil }
        }
    }

    package var claudeBox: Box
    // True when the row has a local name, so the dialog shows the reset button.
    package var showReset: Bool

    package init(claudeBox: Box, showReset: Bool) {
        self.claudeBox = claudeBox
        self.showReset = showReset
    }
}

// What one save of the Rename dialog does.
package enum RenamePlan: Sendable, Equatable {
    // Keep the name in Bifrost only. nil clears the local name.
    case local(alias: String?)
    // Type the /rename command into the session, then clear the local name, because the Claude
    // Code name changes.
    case claude(send: String)
}

package enum RenameRules {
    // The texts of the dialog.
    package static let nameFieldLabel = "Name in Bifrost"
    package static let claudeBoxLabel = "Also rename it in Claude Code"
    package static let resetLabel = "Use the Claude Code name"
    package static let lostNoteText =
        "Bifrost can't rename it in Claude Code right now. Save keeps the name in Bifrost only."

    // The controls that the dialog shows for the row. A red box of a prompt turns the check box
    // off, because typed text could answer the prompt.
    package static func controls(_ row: SessionRow) -> RenameControls {
        let showReset = row.name != row.claudeName
        let box: RenameControls.Box =
            if row.kind != .owned || row.state == .parked {
                .hidden
            } else if row.alert.blocksPrompt {
                .disabled(.input(.prompt))
            } else if row.shortId == nil {
                .disabled(.noShortId)
            } else {
                .enabled
            }
        return RenameControls(claudeBox: box, showReset: showReset)
    }

    // The check box counts only while the dialog shows it as usable.
    package static func effectiveAlsoClaude(_ row: SessionRow, alsoClaude: Bool) -> Bool {
        alsoClaude && controls(row).claudeBox == .enabled
    }

    // A note for the user when the check box is on but the row cannot take /rename now.
    package static func lostNote(_ row: SessionRow, alsoClaude: Bool) -> String? {
        alsoClaude && !effectiveAlsoClaude(row, alsoClaude: alsoClaude) ? lostNoteText : nil
    }

    // The plan of a save with the name. With alsoClaude, the save types /rename and the name
    // after the clean-up of the session input. Else the trimmed name is the local name, and an
    // empty name clears it.
    package static func plan(_ row: SessionRow, name: String, alsoClaude: Bool)
        -> Result<RenamePlan, ActionRefusal>
    {
        guard alsoClaude else {
            do {
                let alias = try cleanAlias(name)
                return .success(.local(alias: alias.isEmpty ? nil : alias))
            } catch {
                return .failure(.alias(error))
            }
        }
        switch controls(row).claudeBox {
        case .hidden: return .failure(row.kind == .external ? .external : .parked)
        case .disabled(let refusal): return .failure(refusal)
        case .enabled:
            return InputPlan.rename(name).map { .claude(send: $0) }.mapError { .input($0) }
        }
    }

    // What the app does after a send of the send box or of Run slash command. A /rename changes
    // the Claude Code name, so it clears the local name, as the check box of the dialog does
    // (ruling of 2026-11-06). A /rename does not go into the recent slash commands, because a
    // click on it in the submenu would give its name to another session. The command can have
    // white space before it, and the next character after it is white space or the end.
    package static func afterSend(_ text: String) -> (clearAlias: Bool, rememberSlash: Bool) {
        let rename = isRenameCommand(text.trimmed())
        return (rename, !rename)
    }

    private static func isRenameCommand(_ text: String) -> Bool {
        let command = "/rename".unicodeScalars
        let scalars = text.unicodeScalars
        guard scalars.starts(with: command) else { return false }
        let next = scalars.dropFirst(command.count).first
        return next.map(\.properties.isWhitespace) ?? true
    }
}
