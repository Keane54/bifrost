// The session commands that SessionActions runs, and their results (docs/behaviour/actions.md,
// "The session commands").

// A session command. A String is the row ID of the session. Only NewSessionSpec.check makes a
// spec, so a create always has values that passed the checks.
package enum SessionCommand: Sendable, Equatable {
    case create(NewSessionSpec)
    case stop(String)
    case resume(String)
    case resumeAll
    // Delete. confirmed is true only after the user accepted the confirmation. seen is the check
    // that the Delete dialog showed, or nil when the dialog showed no check of a worktree.
    case remove(String, confirmed: Bool, seen: SeenCounts?)
    // Take control. confirmed is true only after the user accepted the confirmation.
    case takeControl(String, confirmed: Bool)
}

// The counts of the worktree check that the Delete dialog showed, the worktree of that check and
// its HEAD commit. A discard of the commits that claude rm keeps needs them. Only a check that
// found a worktree and read its HEAD makes them, so each value comes from git.
package struct SeenCounts: Sendable, Equatable {
    package let changedFiles: UInt
    package let unmergedCommits: UInt
    package let worktree: String
    package let head: String

    // The values of the check. nil for a check that found no worktree or read no HEAD commit.
    package init?(_ check: WorktreeCheck) {
        guard let worktree = check.worktree, let head = check.head else { return nil }
        changedFiles = check.changedFiles
        unmergedCommits = check.unmergedCommits
        self.worktree = worktree
        self.head = head
    }
}

// One session that Resume all did not resume, and the reason.
package struct ResumeFailure: Sendable, Equatable {
    package var sessionId: String
    package var name: String
    package var error: ActionRefusal

    package init(sessionId: String, name: String, error: ActionRefusal) {
        self.sessionId = sessionId
        self.name = name
        self.error = error
    }
}

// The result of Resume all: the number of sessions that run again, and each failure in the order
// of the rows.
package struct ResumeAllResult: Sendable, Equatable {
    package var resumed: Int
    package var failed: [ResumeFailure]

    package init(resumed: Int = 0, failed: [ResumeFailure] = []) {
        self.resumed = resumed
        self.failed = failed
    }
}

// A step of a New session start before its end (SessionActions.newSession), in this order.
package enum StartStep: Sendable, Equatable {
    // The checks passed, and claude --bg starts now. From this step on, only claude and the wait
    // for the row can stop the start.
    case accepted
    // claude --bg ended and gave the short ID of the new session.
    case launched(ShortID)
}

// What a session command did. created gives the row ID of the new session. tookControl gives the
// row ID of the session that Take control resumed in Bifrost: the row ID of the command.
package enum ActionDone: Sendable, Equatable {
    case done
    case created(sessionId: String)
    case resumedAll(ResumeAllResult)
    case tookControl(sessionId: String)
}
