// The confirmation dialogs of Stop, Delete and Take control (docs/behaviour/actions.md,
// "Confirmations"): the texts for a row, and the click rule of the confirm button.
import BifrostFoundation

// The texts of one confirmation dialog.
package struct ConfirmText: Sendable, Equatable {
    package var title: String
    package var body: String
    package var confirm: String
    // The first click changes the confirm button to this label. Only a second click confirms.
    package var confirmAgain: String?
    // A folder that the dialog can open, so the user can look at the work first.
    package var openFolder: String?

    package init(
        title: String, body: String, confirm: String, confirmAgain: String? = nil,
        openFolder: String? = nil
    ) {
        self.title = title
        self.body = body
        self.confirm = confirm
        self.confirmAgain = confirmAgain
        self.openFolder = openFolder
    }
}

// The result of the check for unmerged work before a Delete. The counts cannot be negative, so
// the Delete can compare the counts that the dialog showed with a new check.
package struct WorktreeCheck: Sendable, Equatable {
    // nil when git gave no branch.
    package var branch: String?
    package var changedFiles: UInt
    package var unmergedCommits: UInt
    // The worktree root, or nil when the folder of the session is not a worktree.
    package var worktree: String?
    // The HEAD commit of the worktree, when the check read it (WorktreeChecker.checkWithHead).
    package var head: String?

    package init(
        branch: String?, changedFiles: UInt, unmergedCommits: UInt, worktree: String?,
        head: String? = nil
    ) {
        self.branch = branch
        self.changedFiles = changedFiles
        self.unmergedCommits = unmergedCommits
        self.worktree = worktree
        self.head = head
    }
}

// What the Delete dialog knows about the worktree of the session.
package enum DeleteCheck: Sendable, Equatable {
    // No check ran yet. The run plan gives this text, and the runner makes the final text after
    // the check.
    case unchecked
    // Another session uses the folder, so the Delete keeps it and runs no check.
    case shared
    case failed
    case checked(WorktreeCheck)
}

package enum ConfirmKind: Sendable, Equatable {
    case stop, takeControl
    case delete(DeleteCheck)
}

// first: the button shows the confirm label. again: the button shows the confirmAgain label.
package enum ConfirmStep: Sendable {
    case first, again
}

package enum Confirm {
    // The second click counts only this long after the label change. So a held key or a fast
    // double click cannot pass both steps.
    package static let againWait = Duration.milliseconds(500)

    // The sentence of a Delete body when the check shows changed files. claude rm keeps a
    // worktree with changes that are not committed.
    private static let keepsChanges =
        "Claude Code keeps a worktree with changes that are not committed, so commit or discard "
        + "them first."
    // A Delete in a folder that another session uses. Bifrost runs claude rm for it at the Delete
    // of the last session in that folder.
    private static let sharedKeeps = "Another session still uses this folder, so Bifrost keeps it."
    private static let sharedLater =
        "It goes from the list now, and Bifrost removes it from Claude Code when you delete the "
        + "last session in this folder."

    // The texts of the dialog, or nil when the action needs no confirmation. Only a Stop of a
    // session that works asks first. Delete and Take control always ask.
    package static func text(_ kind: ConfirmKind, _ row: SessionRow, _ labels: LabelSet)
        -> ConfirmText?
    {
        switch kind {
        case .stop: stopText(row, labels)
        case .takeControl: takeControlText(row, labels)
        case .delete(let check): deleteText(row, labels, check)
        }
    }

    // The result of a click on the confirm button in the state. The label is the label after
    // the click. With confirmAgain, the first click only changes the label. Only the second click
    // confirms, and only againWait or more after the label change. sinceAgain is that time.
    package static func step(_ state: ConfirmStep, _ text: ConfirmText, sinceAgain: Duration)
        -> (label: String, resolve: Bool)
    {
        guard let again = text.confirmAgain else { return (text.confirm, true) }
        return (again, state == .again && sinceAgain >= againWait)
    }

    // The label of the confirm button in the state.
    package static func label(_ state: ConfirmStep, _ text: ConfirmText) -> String {
        if state == .again, let again = text.confirmAgain { return again }
        return text.confirm
    }

    // MARK: - The texts

    private static func stopText(_ row: SessionRow, _ labels: LabelSet) -> ConfirmText? {
        guard row.state == .working else { return nil }
        let label = ActionID.stop.title(labels)
        let body =
            "\(named(row)) is working right now. \(verbs(labels).stopIt) anyway? The current "
            + "turn will end."
        return ConfirmText(title: label, body: body, confirm: label)
    }

    private static func takeControlText(_ row: SessionRow, _ labels: LabelSet) -> ConfirmText {
        let label = ActionID.takeControl.title(labels)
        let who = row.name == row.claudeName ? "" : " \(named(row))"
        let app = row.terminalApp.map(withoutHiddenCharacters) ?? ""
        let place = app.isEmpty ? "its terminal" : app
        let body = "This closes the session\(who) in \(place) and moves it into Bifrost."
        return ConfirmText(title: label, body: body, confirm: label)
    }

    private static func deleteText(_ row: SessionRow, _ labels: LabelSet, _ check: DeleteCheck)
        -> ConfirmText
    {
        let label = ActionID.delete.title(labels)
        // The title names the session, so the word "session" of the plain label goes:
        // "Delete fix-a", or "Self-destruct fix-a" with the space labels.
        let word = " session"
        let verbOfTitle = label.hasSuffix(word) ? String(label.dropLast(word.count)) : label
        let title = "\(verbOfTitle) \(named(row))"
        let verb = verbs(labels).delete
        let ask = "Are you sure you want to \(verb.lowercased()) this?"
        let again = "\(verb) anyway"
        // claude rm keeps the transcript file, so the text does not say that the conversation
        // goes.
        let plain = ConfirmText(
            title: title,
            body: "\(verb) \(named(row))? This removes the session from Claude Code and Bifrost.",
            confirm: label)
        switch check {
        case .unchecked:
            return plain
        case .shared:
            return ConfirmText(
                title: title, body: "\(sharedKeeps) \(verb) \(named(row))? \(sharedLater)",
                confirm: label)
        case .failed:
            return ConfirmText(
                title: title,
                body: "Bifrost could not check this session for unmerged work. \(ask)",
                confirm: label, confirmAgain: again,
                openFolder: WorktreeRoot(cwd: row.cwd, stored: row.worktree)?.worktree)
        case .checked(let check):
            guard let worktree = check.worktree, let work = unmergedWork(check) else {
                return plain
            }
            let place =
                check.branch.map { "on \(withoutHiddenCharacters($0))" } ?? "in its worktree"
            let keeps = check.changedFiles > 0 ? " \(keepsChanges)" : ""
            return ConfirmText(
                title: title, body: "This session has \(work) \(place).\(keeps) \(ask)",
                confirm: label, confirmAgain: again, openFolder: worktree)
        }
    }

    // The unmerged work of the check, for example "2 commits that are not merged and 1 changed
    // file", or nil for none. A count of 0 gives no part.
    private static func unmergedWork(_ check: WorktreeCheck) -> String? {
        var parts: [String] = []
        let commits = check.unmergedCommits
        if commits > 0 {
            parts.append(
                "\(commits) \(commits == 1 ? "commit" : "commits") that "
                    + "\(commits == 1 ? "is" : "are") not merged")
        }
        let files = check.changedFiles
        if files > 0 { parts.append("\(files) changed \(files == 1 ? "file" : "files")") }
        return parts.isEmpty ? nil : parts.joined(separator: " and ")
    }

    // The name of the session in a text. A local name comes with the Claude Code name, so the
    // text names the session without doubt. The names lose the hidden characters of a name, so
    // a bidi control in a name cannot reverse the rest of the text.
    private static func named(_ row: SessionRow) -> String {
        let name = withoutHiddenCharacters(row.name)
        guard row.name != row.claudeName else { return name }
        return "\(name) (Claude Code name: \(withoutHiddenCharacters(row.claudeName)))"
    }

    // The verbs of the dialog bodies. The body uses the verbs of the label set, as the title and
    // the button do.
    private static func verbs(_ labels: LabelSet) -> (delete: String, stopIt: String) {
        switch labels {
        case .plain: ("Delete", "Stop it")
        case .space: ("Self-destruct", "Power it down")
        }
    }
}
