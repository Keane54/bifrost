// The push of the fix commit of a request round, or of the merge of a conflict round
// (docs/behaviour/reviews.md, "The push and the writes"). It is the only git write to GitHub, and
// it has one form (GitCommand.push): a fast forward of one commit to the head branch of the PR,
// with no force, so GitHub refuses each push that is not a fast-forward. Each git command runs in
// Bifrost's clone (GitPlace.clone).
//
// 1. The checks of the target, with local git only, before any network call (PushPlan): not a
//    fork, not the base branch or the default branch, origin has one URL (the address of the
//    clone) and no push URL, no insteadOf or pushInsteadOf rule changes the address, and the
//    parents of the commit are the expected parents: the head of the round for a fix, or the
//    head and the base for a merge.
// 2. The fetch of the branch. A branch that has the commit gets nothing. A branch without the
//    head of the round was rewritten, and gets nothing. A branch with new commits gets a merge of
//    the commit and the branch (merge-tree and commit-tree: no worktree, no hook, no signature);
//    a conflict gets nothing. With BranchMoved.stop, a branch with new commits gets nothing, and
//    the push throws moved: the new head is a new case for the round.
// 3. The push. GitHub refuses a push that is not a fast-forward when the branch moved after the
//    fetch: then one more fetch and one more try (PushPlan.maxTries). A push that made a new
//    branch shows that GitHub deleted the branch. After a push, a fetch of the branch gives the
//    true outcome, also after a failed push, which can still have reached GitHub. A branch that
//    the server refuses ([remote rejected]: a protected branch or a hook) gives refused, because
//    each run gets the same refusal.
// A merge holds only files that a fix commit can hold (checkMerge). merge-tree follows renames,
// so a fix of a file that the other person moved lands at the new path of that file.
import BifrostFoundation
import Foundation

// The outcome of a push: the step that went, and the commit that the push post keeps: the fix
// or the merge of a git push, or the commit that GitHub made for a signed fix.
package struct PushResult: Sendable, Equatable {
    package var step: PushStep
    package var commit: CommitID

    package init(step: PushStep, commit: CommitID) {
        self.step = step
        self.commit = commit
    }
}

// What the push does when the branch on GitHub has new commits on top of the head of the round.
package enum BranchMoved: Sendable {
    // Merge the commit and the branch, and push the merge (a request round).
    case merge
    // Push nothing and throw moved (a conflict round): the new head is a new case.
    case stop
}

package struct Pusher: Sendable {
    private let git: RepoGit
    // The source of the clone: the one address that the push can go to.
    private let address: URL

    package init(git: RepoGit, address: URL) {
        self.git = git
        self.address = address
    }

    // Push the commit of the round on the head to the branch of the target. parents: the parents
    // that the commit must have, in their order; nil means the head only (a fix). onMove: what a
    // branch with new commits gets.
    package func push(
        _ commit: CommitID, head: CommitID, pr: PRKey, to target: PushTarget,
        parents: [CommitID]? = nil, onMove: BranchMoved = .merge
    ) async throws(PushRefusal) -> PushResult {
        try await checkTarget(commit, head: head, pr: pr, target: target, parents: parents)
        for _ in 1...PushPlan.maxTries {
            let remote = try await fetchBranch(target.branch, pr: pr)
            let need = try PushPlan.need(
                fixOnBranch: try await isAncestor(commit, of: remote, pr: pr),
                headOnBranch: try await isAncestor(head, of: remote, pr: pr),
                branchInFix: try await isAncestor(remote, of: commit, pr: pr))
            let push: GitPush
            let step: PushStep
            switch (need, onMove) {
            case (.nothing, _):
                return PushResult(step: .nothing(remote), commit: commit)
            case (.fastForward, _):
                push = GitPush(commit: commit, branch: target.branch)
                step = .push(push)
            case (.merge, .stop):
                throw .moved
            case (.merge, .merge):
                let merged = try await merge(commit, head: head, remote: remote, pr: pr, target)
                push = GitPush(commit: merged, branch: target.branch)
                step = .merge(push)
            }
            let result = await git.run(.push(push), in: .clone(pr.repo))
            let answer = PushPlan.answer(result)
            switch answer {
            case .lostRace: continue
            case .madeBranch: throw .deleted(madeAgain: true)
            case .pushed, .refused, .failed: break
            }
            // The branch on GitHub gives the true outcome.
            let after: CommitID
            do throws(PushRefusal) {
                after = try await fetchBranch(target.branch, pr: pr)
            } catch {
                throw .unknown(answer == .pushed ? "" : RepoStore.reason(result))
            }
            if (try? await isAncestor(push.commit, of: after, pr: pr)) == true {
                return PushResult(step: step, commit: push.commit)
            }
            if answer == .pushed {
                throw .unknown("The branch on GitHub doesn't have the fix after the push.")
            }
            if case .refused(let reason) = answer { throw .refused(reason) }
            // git ended the push with an error of its own, so the push is over. A push that git
            // did not end (a time limit or a stop) can still reach GitHub.
            if case .exited = result.end { throw .git(RepoStore.reason(result)) }
            throw .unknown(RepoStore.reason(result))
        }
        throw .moved
    }

    // MARK: - The parts, also of the signed push

    // The checks of the target with local git only (PushPlan.targetRefusal), and the check that
    // the parents of the commit are the parents, in their order. nil means the head of the round
    // only (a fix).
    func checkTarget(
        _ commit: CommitID, head: CommitID, pr: PRKey, target: PushTarget,
        parents: [CommitID]? = nil
    ) async throws(PushRefusal) {
        if target.isFork { throw .fork }
        let remote = RemoteURLs(
            urls: try await values(.configGetAll("remote.origin.url"), pr),
            pushURLs: try await values(.configGetAll("remote.origin.pushurl"), pr),
            fetchTargets: try await values(.remoteURLs(push: false), pr),
            pushTargets: try await values(.remoteURLs(push: true), pr))
        if let refusal = PushPlan.targetRefusal(target, remote: remote, address: address) {
            throw refusal
        }
        guard try await object(commit, pr: pr).parents == (parents ?? [head]) else {
            throw .target
        }
    }

    // Fetch the branch into a ref of Bifrost, and give its commit. A branch that GitHub does not
    // have gives deleted.
    func fetchBranch(_ branch: BranchName, pr: PRKey) async throws(PushRefusal) -> CommitID {
        let ref = "refs/bifrost/remote/\(pr.number)"
        let fetched = await git.run(
            .fetch(refspec: "+refs/heads/\(branch.text):\(ref)"), in: .clone(pr.repo))
        guard fetched.succeeded else {
            if fetched.stderr.contains("couldn't find remote ref") {
                throw .deleted(madeAgain: false)
            }
            throw .git(RepoStore.reason(fetched))
        }
        let parsed = await git.run(.revParse(ref + "^{commit}"), in: .clone(pr.repo))
        guard parsed.succeeded, let commit = CommitID(parsed.stdout.trimmed()) else {
            throw .git(RepoStore.reason(parsed))
        }
        return commit
    }

    // True when the first commit is an ancestor of the second one, or the same commit.
    func isAncestor(_ commit: CommitID, of other: CommitID, pr: PRKey) async throws(PushRefusal)
        -> Bool
    {
        let result = await git.run(.isAncestor(commit, of: other), in: .clone(pr.repo))
        if result.succeeded { return true }
        if result.end == .exited(1) { return false }
        throw .git(RepoStore.reason(result))
    }

    // The raw form of the commit.
    func object(_ commit: CommitID, pr: PRKey) async throws(PushRefusal) -> CommitObject {
        let result = await git.run(.catFile(commit.hex), in: .clone(pr.repo))
        guard result.succeeded, let object = CommitObject(result.stdout) else {
            throw .git(RepoStore.reason(result))
        }
        return object
    }

    // The newest commits from the commit, each with its parents.
    func newest(_ commit: CommitID, pr: PRKey) async throws(PushRefusal) -> [[CommitID]] {
        let result = await git.run(
            .revList(commit, max: PushPlan.maxLookup), in: .clone(pr.repo))
        guard result.succeeded else { throw .git(RepoStore.reason(result)) }
        return result.stdout.split(separator: "\n").map {
            $0.split(separator: " ").compactMap { CommitID(String($0)) }
        }
    }

    // The entries of the tree of the commit at the paths: the mode and the object of each path.
    // No path gives no entry.
    func entries(_ commit: CommitID, paths: [String], pr: PRKey) async throws(PushRefusal)
        -> [String: TreeEntry]
    {
        guard !paths.isEmpty else { return [:] }
        let result = await git.run(.treeEntries(commit, paths), in: .clone(pr.repo))
        guard result.succeeded else { throw .git(RepoStore.reason(result)) }
        guard let entries = TreeEntry.listing(result.stdout) else {
            throw .git("git gave a bad tree.")
        }
        return entries
    }

    // The bytes of the blob as git keeps them. They do not come from the worktree: git changes
    // the line ends, the ident and the encoding of a file in the worktree by its attributes, and
    // the session can still change the worktree.
    func blob(_ object: String, pr: PRKey) async throws(PushRefusal) -> Data {
        let result = await git.run(.blob(object), in: .clone(pr.repo))
        guard result.succeeded, let bytes = result.stdoutBytes else {
            throw .git(RepoStore.reason(result))
        }
        return bytes
    }

    // The merge commit of the fix and the branch, with the head of the round as the merge base.
    // A conflict gives conflict.
    private func merge(
        _ fix: CommitID, head: CommitID, remote: CommitID, pr: PRKey, _ target: PushTarget
    ) async throws(PushRefusal) -> CommitID {
        let tree = await git.run(
            .mergeTree(base: head, ours: fix, theirs: remote), in: .clone(pr.repo))
        if tree.end == .exited(1) { throw .conflict }
        let id = tree.stdout.split(separator: "\n").first.map { $0.trimmed() } ?? ""
        guard tree.succeeded, CommitID.isObjectID(id) else { throw .git(RepoStore.reason(tree)) }
        let made = await git.run(
            .commitTree(
                tree: id, parents: [fix, remote],
                message: PushPlan.mergeMessage(target.branch)),
            in: .clone(pr.repo))
        guard made.succeeded, let commit = CommitID(made.stdout.trimmed()) else {
            throw .git(RepoStore.reason(made))
        }
        try await checkMerge(commit, onto: remote, pr: pr)
        return commit
    }

    // The merge must hold only files that a fix commit can hold: each path that it changes on the
    // branch passes the path rule (CommitFileRule) and is a plain or an executable file. Else it
    // gets nothing, as a conflict does, and Try again lets Claude fix it on the new code.
    private func checkMerge(_ merge: CommitID, onto remote: CommitID, pr: PRKey)
        async throws(PushRefusal)
    {
        let listed = await git.run(.changedPaths(remote, merge), in: .clone(pr.repo))
        guard listed.succeeded else { throw .git(RepoStore.reason(listed)) }
        let paths = listed.stdout.split(separator: "\0").map(String.init)
        if paths.contains(where: { CommitFileRule.pathRefusal($0) != nil }) { throw .conflict }
        let entries = try await entries(merge, paths: paths, pr: pr)
        if entries.values.contains(where: { TreeEntry.refusal($0.mode) != nil }) {
            throw .conflict
        }
    }

    // The values of a config key or of the addresses of origin. A key with no value (exit code
    // 1) gives none. Each other exit code refuses the target. A git that did not end by itself
    // (a time limit or a cancel) gives git, so the push can go in a later run.
    private func values(_ command: GitCommand, _ pr: PRKey) async throws(PushRefusal) -> [String]
    {
        let result = await git.run(command, in: .clone(pr.repo))
        if case .configGetAll = command, result.end == .exited(1), result.stdout.isEmpty {
            return []
        }
        guard result.succeeded else {
            if case .exited = result.end { throw .target }
            throw .git(RepoStore.reason(result))
        }
        // An empty value is a value too, so only the line end of the last value goes.
        var lines = result.stdout.split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
        if lines.last == "" { lines.removeLast() }
        return lines
    }
}
