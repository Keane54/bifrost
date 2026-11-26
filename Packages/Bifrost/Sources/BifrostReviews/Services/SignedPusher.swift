// The signed push of a fix (docs/behaviour/reviews.md, "The push and the writes"), with the
// setting "Sign commits through GitHub" on when the round planned its writes. GitHub makes and
// signs the commit (createCommitOnBranch), so the user needs no signing key; Bifrost itself never
// signs. The local fix commit is the source of the change, so the same file rules apply.
//
// 1. A fork is refused before any write, then the checks of the target of the git push run
//    (Pusher.checkTarget).
// 2. The change of the fix commit against the head of the round, for its listed paths: each new
//    file is a plain file in the fix and in the head (GitHub makes each file of the commit a plain
//    file), its bytes are the bytes of its blob in the fix commit as git keeps them (not the file
//    of the worktree, which git changes by the attributes of the file and the session can still
//    change), and the sum is at most CommitFileRule.maxSignedBytes.
// 3. The fetch of the branch, and the search for the commit that GitHub made (an earlier run that
//    a quit or an unknown answer cut off): a child of the head of the round, among the newest
//    PushPlan.maxLookup commits, with the tree of the fix. A branch that moved gets nothing:
//    GitHub would refuse it.
// 4. The write, with expectedHeadOid of the head of the round, so GitHub refuses a branch that
//    moved and never replaces a commit. Then a fetch finds the commit that GitHub made, and the
//    "Fixed by" replies name it. The reason of a refusal of GitHub goes to the Event log only.
import BifrostFoundation
import CryptoKit
import Foundation

@MainActor
package struct SignedPusher {
    // The start of a file that the check of a refusal text looks for: GitHub can quote a value of
    // the write in its text.
    private static let quotedStart = 12

    private let pusher: Pusher
    private let github: GitHubClient

    package init(git: RepoGit, address: URL, github: GitHubClient) {
        pusher = Pusher(git: git, address: address)
        self.github = github
    }

    // Send the fix of the round on the head, with its listed paths, to the branch of the target
    // as a commit that GitHub signs.
    package func push(
        _ fix: CommitID, head: CommitID, paths: [String], pr: PRKey, to target: PushTarget
    ) async throws(PushRefusal) -> PushResult {
        if target.isFork { throw .fork }
        try await pusher.checkTarget(fix, head: head, pr: pr, target: target)
        let tree = try await pusher.object(fix, pr: pr).tree
        let commit = try await signedCommit(fix, head: head, paths: paths, pr: pr, target)
        let remote = try await pusher.fetchBranch(target.branch, pr: pr)
        if let found = try await made(tree, head: head, remote: remote, pr: pr) {
            return PushResult(step: .nothing(remote), commit: found)
        }
        if remote != head {
            guard try await pusher.isAncestor(head, of: remote, pr: pr) else { throw .rewritten }
            throw .moved
        }
        let failure: GitHubError?
        do throws(GitHubError) {
            _ = try await github.write(.createSignedCommit(commit))
            failure = nil
        } catch {
            failure = error
        }
        // The branch on GitHub gives the true outcome.
        let after: CommitID
        do throws(PushRefusal) {
            after = try await pusher.fetchBranch(target.branch, pr: pr)
        } catch {
            throw .unknown(Self.line(failure, commit))
        }
        if let found = try await made(tree, head: head, remote: after, pr: pr) {
            return PushResult(step: .signed(commit), commit: found)
        }
        switch failure {
        case nil:
            throw .unknown("The branch on GitHub doesn't have the signed commit.")
        case let error? where error.writeMayHaveHappened:
            throw .unknown(Self.line(error, commit))
        case .refused? where after != head:
            throw .moved
        case .refused?:
            throw PushRefusal.server(Self.line(failure, commit))
        case let error?:
            // gh did not send the write (not installed or not logged in).
            throw .git(error.message)
        }
    }

    // The commit that GitHub made for the fix, or nil: a child of the head of the round, among the
    // newest commits of the branch, with the tree of the fix. Only the files count, not the
    // message.
    private func made(_ tree: String, head: CommitID, remote: CommitID, pr: PRKey)
        async throws(PushRefusal) -> CommitID?
    {
        for ids in try await pusher.newest(remote, pr: pr) {
            guard ids.count == 2, ids[1] == head else { continue }
            if try await pusher.object(ids[0], pr: pr).tree == tree { return ids[0] }
        }
        return nil
    }

    // The write of the change of the fix commit against the head, for the listed paths.
    private func signedCommit(
        _ fix: CommitID, head: CommitID, paths: [String], pr: PRKey, _ target: PushTarget
    ) async throws(PushRefusal) -> SignedCommit {
        let new = try await pusher.entries(fix, paths: paths, pr: pr)
        let old = try await pusher.entries(head, paths: paths, pr: pr)
        var changes: [FileChange] = []
        var total = 0
        for path in paths {
            guard let entry = new[path] else {
                // A delete of a file of the head. A path that the head does not have either
                // changes nothing.
                if old[path] != nil { changes.append(FileChange(path: path, contents: nil)) }
                continue
            }
            guard entry.mode == Self.plainFile, old[path].map({ $0.mode == Self.plainFile }) ?? true
            else { throw .fileMode }
            let bytes = try await pusher.blob(entry.object, pr: pr)
            // The bytes must be the blob of the fix, so GitHub gets exactly the local commit.
            guard Self.blobID(bytes, like: entry.object) == entry.object else {
                throw .git("git gave other bytes than the blob of the fix commit.")
            }
            total += bytes.count
            guard total <= CommitFileRule.maxSignedBytes else { throw .tooLarge }
            changes.append(FileChange(path: path, contents: bytes))
        }
        let message = PushPlan.signedMessage(try await pusher.object(fix, pr: pr).message)
        return SignedCommit(
            repo: pr.repo, branch: target.branch, expectedHead: head, headline: message.headline,
            body: message.body, changes: changes)
    }

    // The mode of a plain file in a tree.
    private static let plainFile = "100644"

    // The git ID of the bytes as a blob: SHA-1, or SHA-256 for an ID of 64 characters.
    private static func blobID(_ bytes: Data, like id: String) -> String {
        var data = Data("blob \(bytes.count)\0".utf8)
        data.append(bytes)
        if id.utf8.count == 64 { return hex(SHA256.hash(data: data)) }
        return hex(Insecure.SHA1.hash(data: data))
    }

    private static func hex(_ digest: some Digest) -> String {
        digest.map { String(format: "%02x", $0) }.joined()
    }

    // The line of GitHub for the Event log. A line that quotes a file of the fix gives a fixed
    // text, so no file content goes to the log.
    private static func line(_ error: GitHubError?, _ commit: SignedCommit) -> String {
        guard let error else { return "" }
        let text: String
        switch error {
        case .refused(let line), .unknownOutcome(let line): text = line
        default: text = error.message
        }
        let quotes = commit.changes.contains { change in
            guard let contents = change.contents, !contents.isEmpty else { return false }
            let start = String(contents.base64EncodedString().prefix(quotedStart))
            return text.contains(start)
        }
        return quotes ? "GitHub refused the files of the fix." : text
    }
}
