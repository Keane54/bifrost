import BifrostSessions

// The state of the Bifrost skills for the user, with the texts and the rules of Settings > Skills
// and of the skills step of the Setup dialog (docs/behaviour/skills.md, "Settings > Skills"). The
// rules are pure, so the tests can check each one. A status that Bifrost has not read yet is
// loading.
package enum SkillsNotice: Sendable, Equatable {
    case loading, notInstalled, off, on
    // Bifrost cannot read the plugin state, or the plugin reads other files. The text tells why.
    case problem(String)

    package static func of(_ status: SkillsStatus?) -> SkillsNotice {
        guard let status else { return .loading }
        switch status.plugin {
        case .unknown: return .problem(status.error ?? notChecked)
        case .notInstalled: return .notInstalled
        case .disabled: return .off
        case .enabled:
            if status.folderCurrent { return .on }
            // A problem text of the control (for example a marketplace of another program)
            // comes first.
            return .problem(status.error ?? filesDiffer)
        }
    }

    // The state line of the Skills section.
    package var stateLine: String {
        switch self {
        case .loading: "Checking the skills..."
        case .notInstalled: "Not installed."
        case .off: "Off."
        case .on: "On."
        case .problem(let message): message
        }
    }

    // The line of the done view of the Setup dialog. A problem text names the skills itself.
    package var doneLine: String {
        if case .problem(let message) = self { return message }
        return "Skills: \(stateLine)"
    }

    // MARK: - The texts

    package static let about =
        "Bifrost skills give Claude tested steps for common jobs: review a PR, resolve PR "
        + "comments, humanise text, grill a plan and hand over a session. Start one by typing its "
        + "name in a chat, for example /bifrost-review. They're a small Claude Code plugin that "
        + "Bifrost keeps up to date."
    package static let setupIntro = about + " Bifrost makes these changes only if you install them:"
    // The changes of Install, in the order that Install makes them.
    package static let steps = [
        "Copy the skills plugin files to the folder ~/.bifrost/skills.",
        #"Add that folder as the plugin marketplace "bifrost-skills", then install the plugin "#
            + #""bifrost" for your user with claude plugin."#,
    ]
    package static let withoutSkills =
        "You can install the skills later in Settings > Skills. The Hand over button works "
        + "without them."
    package static let removeConfirm = ConfirmText(
        title: "Remove skills",
        body: #"Bifrost turns off its skills, removes the plugin "bifrost" and the marketplace "#
            + #""bifrost-skills", and deletes the folder ~/.bifrost/skills."#,
        confirm: "Remove")
    package static let groupHint =
        "Listed skills are in Claude's skill list, so Claude can start them by itself. Skills "
        + "called by name cost no context until you type their name."

    static let notChecked = "Bifrost couldn't check the skills."
    static let filesDiffer =
        "The skills use files that don't match this Bifrost. Turn them off, then on again."

    // The label of the group of a skill in the list of the section.
    package static func groupLabel(_ group: SkillGroup) -> String {
        switch group {
        case .calledByName: "Called by name"
        case .listed: "Listed"
        }
    }

    // MARK: - The rules

    // The buttons follow the table of Live details. The labels are LiveActionID.label.
    package static func actions(_ status: SkillsStatus?) -> [LiveActionID] {
        guard let status else { return [] }
        switch status.plugin {
        case .unknown: return [.retry]
        case .notInstalled: return [.install]
        case .disabled: return [.enable, .remove]
        case .enabled: return of(status) == .on ? [.disable, .remove] : [.disable, .enable, .remove]
        }
    }

    // The Setup dialog offers the skills only when the plugin is not installed.
    package static func stepNeeded(_ status: SkillsStatus?) -> Bool {
        status?.plugin == .notInstalled
    }

    // What comes after the Live details step or the skills step of the Setup dialog. installed
    // holds what the user installed in this open of the dialog. close: the dialog closes.
    package static func nextSetupPhase(
        from step: SetupStep, _ skills: SkillsStatus?, installed: (live: Bool, skills: Bool)
    ) -> SetupNext {
        if step == .live && stepNeeded(skills) { return .skills }
        return installed.live || installed.skills ? .done : .close
    }
}

// A step of the Setup dialog that can end: the Live details step or the skills step.
package enum SetupStep: Sendable {
    case live, skills
}

// What comes after a step of the Setup dialog: the skills step, the done view, or the close.
package enum SetupNext: Sendable {
    case skills, done, close
}
