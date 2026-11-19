// The values of the New session form and the rules of its fields (docs/behaviour/actions.md,
// "New session"). The dialog shows the form and sends each change of a field as a FormAction.
import BifrostFoundation

// A change of one field of the form.
package enum FormAction: Sendable, Equatable {
    case cwd(String)
    case name(String)
    case model(ModelChoice)
    // nil: the default mode of Claude Code.
    case mode(PermissionMode?)
    case prompt(String)
    case worktree(Bool)
}

// The state of the folder check of the form. The dialog runs the check only for an absolute
// folder (NewSessionForm.isAbsoluteDir), and a new folder starts a new check.
package enum FolderCheck: Sendable, Equatable {
    case checking
    case failed
    case done(DirInfo)
}

package struct NewSessionForm: Sendable, Equatable {
    // The folder part of a suggested name has at most this many Characters.
    package static let maxNameBase = 40

    package private(set) var cwd: String
    package private(set) var name: String
    // True after the user changed the name. A new folder then keeps the name.
    package private(set) var nameEdited: Bool
    // The end of the suggested name, for example "a1b2".
    package let suffix: String
    package private(set) var model: ModelChoice
    package private(set) var permissionMode: PermissionMode?
    package private(set) var prompt: String
    package private(set) var worktree: Bool

    // The first form: the newest folder, the model and the mode of the last new session, and
    // the suggested name of that folder.
    package static func initial(_ history: History, suffix: String) -> NewSessionForm {
        let cwd = history.recentDirs.first ?? ""
        return NewSessionForm(
            cwd: cwd, name: suggestName(cwd, suffix: suffix), nameEdited: false, suffix: suffix,
            model: history.model, permissionMode: history.permissionMode, prompt: "",
            worktree: false)
    }

    // A new folder gives the suggested name of the folder, while the user did not change the
    // name, and turns the worktree option off. Each change of the name marks the name as edited.
    package mutating func apply(_ action: FormAction) {
        switch action {
        case .cwd(let next):
            guard next != cwd else { return }
            cwd = next
            if !nameEdited { name = Self.suggestName(next, suffix: suffix) }
            worktree = false
        case .name(let next):
            name = next
            nameEdited = true
        case .model(let next): model = next
        case .mode(let next): permissionMode = next
        case .prompt(let next): prompt = next
        case .worktree(let next): worktree = next
        }
    }

    // The checked values of the form, or the reason of the first value that fails.
    package func spec() -> Result<NewSessionSpec, ActionRefusal> {
        NewSessionSpec.check(
            cwd: cwd, name: name, model: model, permissionMode: permissionMode, prompt: prompt,
            worktree: worktree)
    }

    // The last part of the path with no hidden character of a name (withoutHiddenCharacters),
    // cut to maxNameBase Characters, then "-" and the suffix. Thus the spec check accepts the
    // suggestion. A path with no part, or a last part of only hidden characters, gives "session"
    // and the suffix. The path splits at each "/" scalar.
    package static func suggestName(_ cwd: String, suffix: String) -> String {
        let last = cwd.unicodeScalars.split(separator: "/").last.map {
            withoutHiddenCharacters(String($0))
        }
        guard let last, !last.isEmpty else { return "session-\(suffix)" }
        return "\(String(last.prefix(maxNameBase)))-\(suffix)"
    }

    // A new suffix for the suggested name: 4 lower-case hex digits.
    package static func newSuffix() -> String {
        var generator = SystemRandomNumberGenerator()
        return newSuffix(using: &generator)
    }

    package static func newSuffix(using generator: inout some RandomNumberGenerator) -> String {
        let value = UInt16(truncatingIfNeeded: generator.next())
        let digits = String(value, radix: 16)
        return String(repeating: "0", count: 4 - digits.count) + digits
    }

    // True when the folder, after the trim, starts with "/". The folder check and the reason of
    // the worktree option use this rule.
    package static func isAbsoluteDir(_ cwd: String) -> Bool {
        cwd.trimmed().unicodeScalars.first == "/"
    }

    // Whether the worktree option works for the folder, with the reason when it does not. A
    // folder that is not absolute gets no check, so its reason is the reason of the start
    // button.
    package static func worktreeState(cwd: String, _ check: FolderCheck) -> ActionState {
        guard isAbsoluteDir(cwd) else { return .off(ActionRefusal.noFolder.message) }
        switch check {
        case .checking: return .off(NewSessionRules.reasonChecking)
        case .failed: return .off(NewSessionRules.reasonCheckFailed)
        case .done(let info):
            if info.kind != .dir { return .off(ActionRefusal.dirMissing.message) }
            if !info.git { return .off(ActionRefusal.noGit.message) }
            return .on
        }
    }
}
