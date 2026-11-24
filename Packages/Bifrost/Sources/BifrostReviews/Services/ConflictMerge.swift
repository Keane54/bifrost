// The git of a conflict round (docs/behaviour/reviews.md, "Merging the base branch"). Bifrost, not
// Claude, runs each git command. It merges the base branch into the head of a PR of the user, and
// never rebases. Claude gets only conflicts of plain text. After Claude resolves them, Bifrost
// commits only the conflicted paths as a merge of the head and the base, and then checks the made
// commit.
//
// 1. start, in the clone: the merge (merge-tree: no worktree, no hook). git finds each merge base
//    itself, as git merge and GitHub do. A clean merge gives noConflict, because GitHub may not
//    have the new state yet. Each conflicted path must pass the path rule of a commit
//    (forbidden), and there are at most maxFiles of them (tooMany). In the merge, each one must
//    be a plain or an executable file of at most 1 MiB with a "<", ">" or "|" marker line
//    (notText): a delete, a rename, a binary file, a link or a submodule has none. The result is
//    the merge with the markers (auto), a commit whose parents are the head and the base.
// 2. checkWorktree, after the worktree goes to auto and before Claude starts: the worktree is at
//    auto, and CommitFileCheck accepts the conflicted files as they are (forbidden). A filter
//    attribute or a submodule in the repository would refuse each commit, so Claude does not
//    start. A check that git or the file system could not do gives git, so a new try can work.
// 3. commit: auto is the merge of this head and this base, the worktree is at auto, the worktree
//    changes only conflicted paths (otherFiles), and CommitFileCheck accepts them
//    (commitRefused). git add takes only those paths, write-tree makes the tree of the index, and
//    commit-tree makes the merge of the head and the base. It never signs. The session can still
//    change the worktree after the checks, so the made commit gets its own check: no signature,
//    the parents are the head and the base, it changes from auto only conflicted paths
//    (otherFiles), each conflicted file is a plain or an executable file of at most 1 MiB
//    (commitRefused), and no file has more marker lines (also a lone line of 7 "=") than its head
//    and its base each have (markersLeft). Thus a heading underline or a line that the file had
//    before stays.
// Each read of a merge uses the objects of the clone, not the files of the worktree.
import BifrostFoundation
import Foundation

package enum ConflictMerge {
    // The most conflicted files of a round (MergeStart.maxFiles).
    package static let maxFiles = MergeStart.maxFiles
    // The message of the auto commit. Only the clone of Bifrost holds this commit.
    package static let autoMessage = "Bifrost: conflicts to resolve"

    // The message of the merge commit (ConflictRule.mergeMessage).
    package static func message(base: String, into branch: BranchName) -> String {
        ConflictRule.mergeMessage(base: base, branch: branch.text)
    }

    // Merge the base into the head of the PR, and give the merge with the conflict markers and
    // the conflicted paths. The head and the base must be in the clone.
    @concurrent package static func start(
        pr: PRKey, head: CommitID, base: CommitID, git: RepoGit
    ) async throws(ConflictFailure) -> MergeStart {
        let merged = await git.run(
            .mergeTreeNames(ours: head, theirs: base), in: .clone(pr.repo))
        guard case .exited(let code) = merged.end, code == 0 || code == 1 else {
            throw .git(RepoStore.reason(merged))
        }
        guard let output = MergeTreeOutput.parse(merged.stdout, exit: code) else {
            throw .git("git gave a bad merge.")
        }
        let conflicted = output.conflicted
        if conflicted.isEmpty { throw .noConflict }
        for path in conflicted {
            if let refusal = CommitFileRule.pathRefusal(path) { throw .forbidden(refusal) }
        }
        guard conflicted.count <= maxFiles else { throw .tooMany }
        let auto = try await commitTree(output.tree, head: head, base: base, autoMessage, git, pr)
        let entries = try await sizes(auto, conflicted, git, pr)
        for path in conflicted {
            guard let entry = entries[path], TreeEntry.fileModes.contains(entry.mode) else {
                throw .notText
            }
            guard let size = entry.size else { throw .git("git gave a bad tree.") }
            guard size <= CommitFileRule.maxFileBytes,
                ConflictMarkers.found(in: try await blob(entry.object, git, pr))
            else { throw .notText }
        }
        return MergeStart(auto: auto, conflicted: conflicted)
    }

    // The check of the worktree of the PR at start.auto, before the session. A refusal of
    // CommitFileCheck for the conflicted files with their markers comes again after each turn of
    // Claude, so it gives forbidden, and Claude does not start. A check that git or the file
    // system could not do (unchecked) can work in a later try, so it gives git.
    @concurrent package static func checkWorktree(pr: PRKey, start: MergeStart, git: RepoGit)
        async throws(ConflictFailure)
    {
        try await checkHead(pr, start, git)
        switch await CommitFileCheck.check(start.conflicted, in: pr, git: git) {
        case nil: return
        case .unchecked?: throw .git(uncheckedLine)
        case let refusal?: throw .forbidden(refusal)
        }
    }

    // The line of git for a check of the files that git or the file system could not do.
    private static let uncheckedLine = "Bifrost couldn't check the conflicted files."

    // Commit the resolved conflicts of the worktree of the PR, which is at start.auto, as a merge
    // of the head and the base with the message. start must be the merge of this head and this
    // base: else the merge would drop the commits of the branch after the start. The result is
    // the made commit. It is not on any branch, and the worktree stays as it is.
    @concurrent package static func commit(
        pr: PRKey, start: MergeStart, head: CommitID, base: CommitID, message: String,
        git: RepoGit
    ) async throws(ConflictFailure) -> CommitID {
        let read = await git.run(.catFile(start.auto.hex), in: .clone(pr.repo))
        guard read.succeeded, let auto = CommitObject(read.stdout) else {
            throw .git(RepoStore.reason(read))
        }
        guard auto.parents == [head, base] else {
            throw .git("The merge to resolve isn't the merge of this head and base.")
        }
        try await checkHead(pr, start, git)
        let worktree = GitPlace.worktree(pr)
        let status = await git.run(.status, in: worktree)
        guard status.succeeded else { throw .git(RepoStore.reason(status)) }
        let conflicted = Set(start.conflicted)
        guard RepoStore.statusPaths(status.stdout).isSubset(of: conflicted) else {
            throw .otherFiles
        }
        let checked = await CommitFileCheck.prove(start.conflicted, in: pr, git: git)
        switch checked.refusal {
        case nil: break
        case .unchecked?: throw .git(uncheckedLine)
        case let refusal?: throw .commitRefused(refusal)
        }
        // The proof of the one submodule check covers the add. Between them, only git commands
        // that read run, and none of them changes the index or HEAD.
        let added = await git.run(.add(start.conflicted), in: worktree, proof: checked.proof)
        guard added.succeeded else { throw .git(RepoStore.reason(added)) }
        let written = await git.run(.writeTree, in: worktree)
        let tree = written.stdout.trimmed()
        guard written.succeeded, CommitID.isObjectID(tree) else {
            throw .git(written.succeeded ? "git gave a bad tree." : RepoStore.reason(written))
        }
        let made = try await commitTree(tree, head: head, base: base, message, git, pr)
        try await checkMade(made, start: start, head: head, base: base, pr: pr, git: git)
        return made
    }

    // The check of the made commit, with the objects of the clone.
    private static func checkMade(
        _ made: CommitID, start: MergeStart, head: CommitID, base: CommitID, pr: PRKey,
        git: RepoGit
    ) async throws(ConflictFailure) {
        let clone = GitPlace.clone(pr.repo)
        let read = await git.run(.catFile(made.hex), in: clone)
        guard read.succeeded, let object = CommitObject(read.stdout), !object.signed,
            object.parents == [head, base]
        else { throw .git("git didn't make the merge of the head and the base.") }
        let changed = await git.run(.changedPaths(start.auto, made), in: clone)
        guard changed.succeeded else { throw .git(RepoStore.reason(changed)) }
        let conflicted = Set(start.conflicted)
        guard changed.stdout.split(separator: "\0").allSatisfy({ conflicted.contains(String($0)) })
        else { throw .otherFiles }
        // The start refuses each delete conflict, so each conflicted file is in both sides. A
        // conflicted path with no entry is a delete of the session, and the merge must not drop a
        // file that both sides keep.
        let entries = try await sizes(made, start.conflicted, git, pr)
        var marked: [(path: String, bytes: Data)] = []
        for path in start.conflicted {
            guard let entry = entries[path] else { throw .git("Claude deleted a conflicted file.") }
            if let refusal = TreeEntry.refusal(entry.mode) { throw .commitRefused(refusal) }
            guard let size = entry.size else { throw .git("git gave a bad tree.") }
            if size > CommitFileRule.maxFileBytes { throw .commitRefused(.tooLarge) }
            let bytes = try await blob(entry.object, git, pr)
            if ConflictMarkers.lines(in: bytes) > 0 { marked.append((path, bytes)) }
        }
        guard !marked.isEmpty else { return }
        // A marker line counts only when the head and the base of the file each have fewer.
        let paths = marked.map(\.path)
        let heads = try await sizes(head, paths, git, pr)
        let bases = try await sizes(base, paths, git, pr)
        for (path, bytes) in marked {
            let before = try await earlier(heads[path], git, pr)
            let after = try await earlier(bases[path], git, pr)
            if ConflictMarkers.added(merged: bytes, head: before, base: after) {
                throw .markersLeft
            }
        }
    }

    // The bytes of a file of the head or of the base, or nil when the commit does not have it as a
    // plain or an executable file.
    private static func earlier(_ entry: TreeEntry?, _ git: RepoGit, _ pr: PRKey)
        async throws(ConflictFailure) -> Data?
    {
        guard let entry, TreeEntry.fileModes.contains(entry.mode) else { return nil }
        return try await blob(entry.object, git, pr)
    }

    // The worktree of the PR must be at start.auto: git status and git add compare with its HEAD.
    private static func checkHead(_ pr: PRKey, _ start: MergeStart, _ git: RepoGit)
        async throws(ConflictFailure)
    {
        let parsed = await git.run(.revParse("HEAD^{commit}"), in: .worktree(pr))
        guard parsed.succeeded, let now = CommitID(parsed.stdout.trimmed()) else {
            throw .git(RepoStore.reason(parsed))
        }
        guard now == start.auto else { throw .git("The worktree isn't at the merge to resolve.") }
    }

    // MARK: - The git commands

    // A commit of the tree whose parents are the head and the base. It never signs.
    private static func commitTree(
        _ tree: String, head: CommitID, base: CommitID, _ message: String, _ git: RepoGit,
        _ pr: PRKey
    ) async throws(ConflictFailure) -> CommitID {
        let made = await git.run(
            .commitTree(tree: tree, parents: [head, base], message: message), in: .clone(pr.repo))
        guard made.succeeded, let commit = CommitID(made.stdout.trimmed()) else {
            throw .git(RepoStore.reason(made))
        }
        return commit
    }

    // The entries of the tree of the commit at the paths, with the size of each blob.
    private static func sizes(
        _ commit: CommitID, _ paths: [String], _ git: RepoGit, _ pr: PRKey
    ) async throws(ConflictFailure) -> [String: TreeEntry] {
        let listed = await git.run(.treeSizes(commit, paths), in: .clone(pr.repo))
        guard listed.succeeded else { throw .git(RepoStore.reason(listed)) }
        guard let entries = TreeEntry.listing(listed.stdout) else {
            throw .git("git gave a bad tree.")
        }
        return entries
    }

    // The bytes of the blob as git keeps them.
    private static func blob(_ object: String, _ git: RepoGit, _ pr: PRKey)
        async throws(ConflictFailure) -> Data
    {
        let result = await git.run(.blob(object), in: .clone(pr.repo))
        guard result.succeeded, let bytes = result.stdoutBytes else {
            throw .git(RepoStore.reason(result))
        }
        return bytes
    }
}
