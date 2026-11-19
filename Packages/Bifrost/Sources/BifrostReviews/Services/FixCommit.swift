// The fix commit of a request round (docs/behaviour/reviews.md, "The push and the writes").
// Bifrost makes the commit, not Claude: only the paths that the result lists, after
// CommitFileCheck, in one commit with the message of the result and the git identity of the user.
// The commit is never signed (GitCommand.commit). A file that the session changed but did not list
// never goes: the index holds the head of the round (the session cannot write the git folder),
// and git add takes only the listed paths.
// The session stays open after its turn, so it can change the worktree between CommitFileCheck and
// git add (for example a listed file that becomes a link). Thus the commit itself is checked after
// git made it, and also a commit that a resume finds again (checkMade).
import BifrostFoundation
import Foundation

// Why Bifrost made no fix commit.
package enum FixCommitFailure: Error, Sendable, Equatable {
    // A listed path breaks a rule of a fix commit.
    case refused(CommitFileRefusal)
    // A git command failed. The text is for the log.
    case git(String)
}

package enum FixCommit {
    // Commit the paths of the worktree of the PR with the message, on the head of the round. The
    // result is the new commit. A worktree on a commit whose one parent is the head, with the
    // same first line of the message, holds the commit of an earlier run that a quit cut off:
    // that commit is the result, so a resume never makes a second commit. A commit that breaks a
    // rule (checkMade) gives refused; the caller resets the worktree to the head.
    @concurrent package static func make(
        paths: [String], message: String, head: CommitID, pr: PRKey, git: RepoGit
    ) async throws(FixCommitFailure) -> CommitID {
        let place = GitPlace.worktree(pr)
        let now = try await headCommit(git, place)
        if now != head {
            guard let object = await object(now, git, place), object.parents == [head],
                subject(object.message) == subject(message), !object.signed
            else { throw .git("The worktree isn't on the head of the round.") }
            try await checkMade(now, head: head, paths: paths, pr: pr, git: git)
            return now
        }
        if let refusal = await CommitFileCheck.check(paths, in: pr, git: git) {
            throw .refused(refusal)
        }
        try await mustRun(.add(paths), git, place)
        try await mustRun(.commit(message: message), git, place)
        let made = try await headCommit(git, place)
        guard made != head, let object = await object(made, git, place), object.parents == [head],
            !object.signed
        else { throw .git("git didn't make the fix commit on the head of the round.") }
        try await checkMade(made, head: head, paths: paths, pr: pr, git: git)
        return made
    }

    // The check of the fix commit itself: each path that it changes from the head is a listed
    // path that passes the path rule, and each listed path that it holds is a plain or an
    // executable file (not a link and not a submodule) of at most CommitFileRule.maxFileBytes.
    // Both reads use the objects of the clone, not the worktree.
    private static func checkMade(
        _ fix: CommitID, head: CommitID, paths: [String], pr: PRKey, git: RepoGit
    ) async throws(FixCommitFailure) {
        let place = GitPlace.clone(pr.repo)
        let listed = Set(paths)
        let changed = await git.run(.changedPaths(head, fix), in: place)
        guard changed.succeeded else { throw .git(RepoStore.reason(changed)) }
        for path in changed.stdout.split(separator: "\0").map(String.init) {
            if let refusal = CommitFileRule.pathRefusal(path) { throw .refused(refusal) }
            // A path that the session did not list: a listed path that became a folder.
            guard listed.contains(path) else { throw .refused(.link) }
        }
        guard !paths.isEmpty else { return }
        let tree = await git.run(.treeSizes(fix, paths), in: place)
        guard tree.succeeded else { throw .git(RepoStore.reason(tree)) }
        guard let entries = TreeEntry.listing(tree.stdout) else {
            throw .git("git gave a bad tree.")
        }
        for entry in entries.values {
            if let refusal = TreeEntry.refusal(entry.mode) { throw .refused(refusal) }
            guard let size = entry.size else { throw .git("git gave a bad tree.") }
            // The file can grow between CommitFileCheck and git add.
            if size > CommitFileRule.maxFileBytes { throw .refused(.tooLarge) }
        }
    }

    private static func headCommit(_ git: RepoGit, _ place: GitPlace)
        async throws(FixCommitFailure) -> CommitID
    {
        let result = await git.run(.revParse("HEAD^{commit}"), in: place)
        guard result.succeeded, let commit = CommitID(result.stdout.trimmed()) else {
            throw .git(RepoStore.reason(result))
        }
        return commit
    }

    private static func object(_ commit: CommitID, _ git: RepoGit, _ place: GitPlace) async
        -> CommitObject?
    {
        let result = await git.run(.catFile(commit.hex), in: place)
        return result.succeeded ? CommitObject(result.stdout) : nil
    }

    private static func mustRun(_ command: GitCommand, _ git: RepoGit, _ place: GitPlace)
        async throws(FixCommitFailure)
    {
        let result = await git.run(command, in: place)
        guard result.succeeded else { throw .git(RepoStore.reason(result)) }
    }

    // The first line of a message, with no white space at its ends.
    private static func subject(_ message: String) -> String {
        message.trimmed().split(separator: "\n", maxSplits: 1).first.map { $0.trimmed() } ?? ""
    }
}
