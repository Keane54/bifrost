// The rules of the push of a fix (docs/behaviour/reviews.md, "The push and the writes"). The push
// is the only git write to GitHub, and it never uses force, so GitHub refuses each push that is
// not a fast-forward. These rules are pure: the checks of the target on the local values of git,
// the step that the state of the branch asks for, the answer of git push, and the raw form of a
// commit. Pusher and SignedPusher run the git commands and the GitHub write.
import BifrostFoundation
import Foundation

// What Bifrost sends for the fix.
package enum PushStep: Sendable, Equatable {
    // The branch has the fix already, so nothing goes. The commit is the head of the branch.
    case nothing(CommitID)
    // A fast-forward of the branch to the fix.
    case push(GitPush)
    // The branch moved: a merge of the fix and the branch, which is a fast-forward of the branch.
    case merge(GitPush)
    // The commit that GitHub makes and signs (createCommitOnBranch).
    case signed(SignedCommit)
}

// Why the fix did not go to GitHub, or why Bifrost can't tell. message is the text of the row;
// detail goes only to the Event log.
package enum PushRefusal: Error, Sendable, Equatable {
    // The checks of the target refused the branch or the remote. No network call ran.
    case target
    // The PR comes from a fork. No network call ran.
    case fork
    // The head of the round is not on the branch: the user rewrote it.
    case rewritten
    // The fix and the new commits of the branch do not merge cleanly.
    case conflict
    // The branch moved again after the last try, or (signed) after the round read it.
    case moved
    // GitHub deleted the branch. madeAgain: the push made the branch again.
    case deleted(madeAgain: Bool)
    // Signed: the files of the fix are over CommitFileRule.maxSignedBytes.
    case tooLarge
    // Signed: the fix changes a link, a submodule or a file that is not a plain file (for
    // example an executable file). GitHub makes each file of the commit a plain file.
    case fileMode
    // GitHub refused the fix, and it comes again in each run: a git push that the server refused
    // ([remote rejected], for example a protected branch or a hook), or a signed commit that GitHub
    // did not make. The text is the reason of git or of GitHub.
    case refused(String)
    // GitHub refused the fix because the gh login has no workflow scope: the fix changes a file
    // below .github/workflows. The text is the line of git or of GitHub. The refusal comes again
    // in each run until the user adds the scope.
    case workflowScope(String)
    // A git command failed (or gh did not send the signed commit), and the branch on GitHub does
    // not have the fix. A later run can work, so the outbox keeps the push. The text is the line
    // of git or of gh.
    case git(String)
    // The push or the signed commit can be on GitHub, and Bifrost can't tell. The text is the
    // line of git or of GitHub.
    case unknown(String)

    // The fix did not go, and the other writes of the round can go: the writes that name the fix
    // drop, and the row asks for Try again.
    package var keepsOtherWrites: Bool {
        switch self {
        case .rewritten, .conflict, .moved: true
        default: false
        }
    }

    // The refusal for the reason of a server or of GitHub: workflowScope when the line names the
    // workflow scope (the words "workflow" and "scope", in any case), else refused.
    package static func server(_ line: String) -> PushRefusal {
        namesWorkflowScope(line) ? .workflowScope(line) : .refused(line)
    }

    // True when the line names the words "workflow" and "scope", in any case.
    package static func namesWorkflowScope(_ line: String) -> Bool {
        let text = line.lowercased()
        return text.contains("workflow") && text.contains("scope")
    }

    // The text for the Event log, or nil.
    package var detail: String? {
        switch self {
        case .refused(let line), .workflowScope(let line), .git(let line), .unknown(let line):
            line.isEmpty ? nil : line
        default: nil
        }
    }

    // The command that adds the workflow scope to the gh login.
    package static let refreshCommand = "gh auth refresh -h github.com -s workflow"

    package var message: String {
        let unsigned =
            "Turn off Sign commits through GitHub and choose Try again, or make the change "
            + "yourself."
        switch self {
        case .target: return "Bifrost won't push to this branch, so it posted nothing."
        case .fork:
            return "This pull request comes from a fork, where Bifrost can't push, so it posted "
                + "nothing."
        case .rewritten:
            return "Someone rewrote this branch while Claude worked, so Bifrost didn't push the "
                + "fix. Bifrost posted the other replies. Choose Try again to let Claude fix it "
                + "on the new code."
        case .conflict:
            return "Someone pushed to this branch, and Claude's fix doesn't merge cleanly. "
                + "Bifrost posted the other replies. Choose Try again to let Claude fix it on the "
                + "new code."
        case .moved:
            return "The branch kept changing while Bifrost pushed. Bifrost posted the other "
                + "replies. Choose Try again."
        case .deleted(madeAgain: false):
            return "The branch is gone from GitHub, so Bifrost didn't push the fix or say it's "
                + "fixed."
        case .deleted(madeAgain: true):
            return "The branch was deleted on GitHub while Bifrost pushed, so the push made it "
                + "again. Delete it on GitHub if you don't need it."
        case .tooLarge:
            return "Claude's fix is over 4 MB, which is too large for a commit that GitHub "
                + "signs. Nothing was posted. \(unsigned)"
        case .fileMode:
            return "Claude's fix changes a link or a file that must stay executable, and GitHub "
                + "can't keep that in a commit it signs. Nothing was posted. \(unsigned)"
        case .refused:
            return "GitHub didn't accept Claude's fix, so Bifrost posted nothing. The branch may "
                + "be protected. The Event log has GitHub's reason."
        case .workflowScope:
            return "GitHub refused Claude's fix because it changes a workflow file and your GitHub "
                + "login can't push workflow changes, so run \(PushRefusal.refreshCommand) in a "
                + "terminal and then try again."
        case .git:
            return "Bifrost couldn't push Claude's fix, so it posted nothing. The Event log has "
                + "the details. Choose Try again."
        case .unknown:
            return "Bifrost can't tell if Claude's fix reached GitHub. Check the pull request on "
                + "GitHub, then choose Try again."
        }
    }
}

// The values of the PR that the checks of the target read: the head branch, the base branch, the
// default branch of the repository and whether the PR comes from a fork, from a fresh read.
package struct PushTarget: Sendable, Equatable {
    package var branch: BranchName
    package var base: String
    package var defaultBranch: String
    package var isFork: Bool

    package init(branch: BranchName, base: String, defaultBranch: String, isFork: Bool) {
        self.branch = branch
        self.base = base
        self.defaultBranch = defaultBranch
        self.isFork = isFork
    }

    // The target of a fresh read of the PR, or nil when its head branch is not a branch name.
    package init?(_ full: FullPR) {
        guard let branch = BranchName(full.headRef) else { return nil }
        self.init(
            branch: branch, base: full.baseRef, defaultBranch: full.defaultBranch,
            isFork: full.isCrossRepository)
    }

    // The target of a fresh read of the head, or nil when its head branch is not a branch name.
    package init?(_ read: HeadRead) {
        guard let branch = BranchName(read.headRef) else { return nil }
        self.init(
            branch: branch, base: read.baseRef, defaultBranch: read.defaultBranch,
            isFork: read.isFork)
    }
}

// The values of the remote origin of the clone, from local git only.
package struct RemoteURLs: Sendable, Equatable {
    // Each value of remote.origin.url and of remote.origin.pushurl.
    package var urls: [String]
    package var pushURLs: [String]
    // The addresses that git fetches from and pushes to, after the insteadOf and pushInsteadOf
    // rules of each config.
    package var fetchTargets: [String]
    package var pushTargets: [String]

    package init(urls: [String], pushURLs: [String], fetchTargets: [String], pushTargets: [String])
    {
        self.urls = urls
        self.pushURLs = pushURLs
        self.fetchTargets = fetchTargets
        self.pushTargets = pushTargets
    }
}

// What the state of the branch asks for, before any merge.
package enum BranchNeed: Sendable, Equatable {
    // The branch has the fix.
    case nothing
    // The branch is at the head of the fix or before it: a fast-forward.
    case fastForward
    // The branch has new commits: a merge.
    case merge
}

// The answer of one git push.
package enum PushAnswer: Sendable, Equatable {
    case pushed
    // The push made a new branch: GitHub deleted the branch after the fetch.
    case madeBranch
    // GitHub refused a push that is not a fast-forward: the branch moved after the fetch.
    case lostRace
    // The server refused the branch ([remote rejected]): a protected branch or a hook. Each run
    // gets the same refusal. The text is the reason of the server.
    case refused(String)
    // The server refused the branch because the gh login has no workflow scope. The text is the
    // reason of the server. The words are read before the text is cut for the log.
    case workflowScope(String)
    case failed
}

// One entry of a tree of a commit (git ls-tree): the mode and the object of a path, and the size
// of a blob in a listing with sizes (ls-tree -l).
package struct TreeEntry: Sendable, Equatable {
    // The modes of a file that a fix commit can hold: a plain file and an executable file. A
    // link (120000) and a submodule (160000) are not files.
    package static let fileModes: Set<String> = ["100644", "100755"]

    package var mode: String
    package var object: String
    // The size in bytes of a blob, or nil (no sizes in the listing, or not a blob).
    package var size: Int?

    package init(mode: String, object: String, size: Int? = nil) {
        self.mode = mode
        self.object = object
        self.size = size
    }

    // The entries of the output of ls-tree -r -z, by path: "<mode> <type> <object>\t<path>" for
    // each entry, or "<mode> <type> <object> <size>\t<path>" with -l, where the size can have
    // spaces before it and is "-" for an entry that is not a blob. nil for an output that does
    // not have this form.
    package static func listing(_ output: String) -> [String: TreeEntry]? {
        var entries: [String: TreeEntry] = [:]
        for entry in output.split(separator: "\0") {
            guard let tab = entry.firstIndex(of: "\t") else { return nil }
            let fields = entry[..<tab].split(separator: " ")
            guard fields.count == 3 || fields.count == 4 else { return nil }
            entries[String(entry[entry.index(after: tab)...])] = TreeEntry(
                mode: String(fields[0]), object: String(fields[2]),
                size: fields.count == 4 ? Int(fields[3]) : nil)
        }
        return entries
    }

    // Why a fix can't hold an entry of this mode, or nil for a plain or an executable file.
    package static func refusal(_ mode: String) -> CommitFileRefusal? {
        if fileModes.contains(mode) { return nil }
        return mode == "160000" ? .submodule : .link
    }
}

// The raw form of a commit (git cat-file commit): its tree, its parents, its message, and
// whether it has a signature.
package struct CommitObject: Sendable, Equatable {
    package var tree: String
    package var parents: [CommitID]
    package var message: String
    package var signed: Bool

    // nil for a text that is not the raw form of a commit.
    package init?(_ text: String) {
        guard let split = text.range(of: "\n\n") else { return nil }
        var tree: String?
        var parents: [CommitID] = []
        var signed = false
        for line in text[..<split.lowerBound].split(separator: "\n") {
            if line.hasPrefix("tree ") {
                tree = String(line.dropFirst(5))
            } else if line.hasPrefix("parent ") {
                guard let parent = CommitID(String(line.dropFirst(7))) else { return nil }
                parents.append(parent)
            } else if line.hasPrefix("gpgsig") {
                signed = true
            }
        }
        guard let tree, CommitID.isObjectID(tree) else { return nil }
        self.tree = tree
        self.parents = parents
        self.message = String(text[split.upperBound...])
        self.signed = signed
    }
}

package enum PushPlan {
    // The most pushes of one fix. A push that GitHub refuses because the branch moved fetches the
    // branch again before the next one.
    package static let maxTries = 2
    // The most commits that the search for the commit that GitHub made checks.
    package static let maxLookup = 20

    // Why Bifrost must not push to the target, or nil. Each value comes from the fresh read and
    // from local git: the branch is not the base branch or the default branch (in any case),
    // origin has one URL, the address of the clone, and no push URL, and no insteadOf or
    // pushInsteadOf rule sends the fetch or the push to another address.
    package static func targetRefusal(
        _ target: PushTarget, remote: RemoteURLs, address: URL
    ) -> PushRefusal? {
        if target.isFork { return .fork }
        let branch = target.branch.text.lowercased()
        guard !target.base.isEmpty, !target.defaultBranch.isEmpty,
            branch != target.base.lowercased(), branch != target.defaultBranch.lowercased()
        else { return .target }
        let one = [address.absoluteString]
        guard remote.urls == one, remote.pushURLs.isEmpty, remote.fetchTargets == one,
            remote.pushTargets == one
        else { return .target }
        return nil
    }

    // The need of the branch: fixOnBranch (the fix is an ancestor of the branch), headOnBranch
    // (the head of the round is an ancestor of the branch) and branchInFix (the branch is an
    // ancestor of the fix). A branch without the head of the round was rewritten: a merge or a
    // fast-forward would put back what the user removed.
    package static func need(fixOnBranch: Bool, headOnBranch: Bool, branchInFix: Bool)
        throws(PushRefusal) -> BranchNeed
    {
        if fixOnBranch { return .nothing }
        guard headOnBranch else { throw .rewritten }
        return branchInFix ? .fastForward : .merge
    }

    // The message of the merge commit of the fix and the branch.
    package static func mergeMessage(_ branch: BranchName) -> String {
        "Merge remote-tracking branch 'origin/\(branch.text)'"
    }

    // The answer of git push --porcelain. A refusal of the server ([remote rejected]) is not a
    // lost race: its text is the reason of the server, with the first "remote:" line of git.
    package static func answer(_ result: ExecResult) -> PushAnswer {
        if result.succeeded {
            let made = result.stdout.split(separator: "\n").contains { $0.hasPrefix("*\t") }
            return made ? .madeBranch : .pushed
        }
        let marker = "[remote rejected]"
        if let line = result.stdout.split(separator: "\n").first(where: { $0.contains(marker) }),
            let start = line.range(of: marker)
        {
            let remote = result.stderr.split(whereSeparator: \.isNewline)
                .map { $0.trimmed() }.first { $0.hasPrefix("remote:") }
            let reason = [String(line[start.lowerBound...]).trimmed(), remote]
                .compactMap { $0 }.joined(separator: " ")
            let cut = String(reason.prefix(200))
            return PushRefusal.namesWorkflowScope(reason) ? .workflowScope(cut) : .refused(cut)
        }
        guard result.end != .timedOut else { return .failed }
        let text = result.stdout + "\n" + result.stderr
        let lost = ["[rejected]", "fetch first", "non-fast-forward"].contains {
            text.contains($0)
        }
        return lost ? .lostRace : .failed
    }

    // The headline and the body of a signed commit, as GitHub takes them: the first line, and
    // the rest after one empty line. GitHub makes the message "headline", or "headline", an
    // empty line and "body".
    package static func signedMessage(_ message: String) -> (headline: String, body: String) {
        let text = message.trimmed()
        guard let end = text.firstIndex(of: "\n") else { return (text, "") }
        let headline = String(text[..<end]).trimmed()
        return (headline, String(text[text.index(after: end)...]).trimmed())
    }
}
