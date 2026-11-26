import BifrostFoundation
import BifrostTestSupport
import Foundation
import Testing

@testable import BifrostReviews

@Suite("the rules of the push", .testTimeLimit)
struct PushPlanTests {
    private static let address = URL(filePath: "/tmp/sources/owner-a/repo-a.git")

    private static func target(_ branch: String, fork: Bool = false) throws -> PushTarget {
        PushTarget(
            branch: try #require(BranchName(branch)), base: "main", defaultBranch: "trunk",
            isFork: fork)
    }

    private static func remote(
        urls: [String]? = nil, pushURLs: [String] = [], fetch: [String]? = nil,
        push: [String]? = nil
    ) -> RemoteURLs {
        let one = [address.absoluteString]
        return RemoteURLs(
            urls: urls ?? one, pushURLs: pushURLs, fetchTargets: fetch ?? one,
            pushTargets: push ?? one)
    }

    // Only the head branch of a PR of the repository, on origin with one address and no rule
    // that changes it, is a target.
    @Test func theTargetChecksUseLocalValuesOnly() throws {
        let (other, one) = ("https://example.invalid/x.git", Self.address.absoluteString)
        let feat = try Self.target("feat")
        #expect(PushPlan.targetRefusal(feat, remote: Self.remote(), address: Self.address) == nil)
        let refused: [(PushTarget, RemoteURLs, PushRefusal)] = [
            (try Self.target("feat", fork: true), Self.remote(), .fork),
            (try Self.target("MAIN"), Self.remote(), .target),
            (try Self.target("Trunk"), Self.remote(), .target),
            (feat, Self.remote(urls: [one, other]), .target),
            (feat, Self.remote(pushURLs: [other]), .target),
            (feat, Self.remote(fetch: [other]), .target),
            (feat, Self.remote(push: [other]), .target),
            (feat, Self.remote(urls: [one, ""]), .target),
        ]
        for (target, remote, refusal) in refused {
            let found = PushPlan.targetRefusal(target, remote: remote, address: Self.address)
            #expect(found == refusal)
        }
    }

    // The state of the branch decides the step: nothing for a branch with the fix, no push for a
    // rewritten branch, a fast-forward or a merge else.
    @Test func theBranchDecidesTheStep() throws {
        let need = { (fix: Bool, head: Bool, branch: Bool) throws(PushRefusal) -> BranchNeed in
            try PushPlan.need(fixOnBranch: fix, headOnBranch: head, branchInFix: branch)
        }
        #expect(try need(true, true, false) == .nothing)
        #expect(throws: PushRefusal.rewritten) { try need(false, false, false) }
        #expect(try need(false, true, true) == .fastForward)
        #expect(try need(false, true, false) == .merge)
        #expect(PushRefusal.conflict.keepsOtherWrites && !PushRefusal.target.keepsOtherWrites)
    }

    // The answer of git push: a new branch shows a deleted branch, and only a refusal of a push
    // that is not a fast-forward is a lost race. A refusal of the server ([remote rejected]) gives
    // its reason, with the first "remote:" line of git.
    @Test func theAnswerOfAPushNamesANewBranchAndALostRace() {
        func answer(_ end: ExecEnd, _ flag: String, _ summary: String) -> PushAnswer {
            PushPlan.answer(
                ExecResult(end, stdout: "To file:///s\n\(flag)\ta:refs/heads/feat\t\(summary)\n"))
        }
        #expect(answer(.exited(0), " ", "x..y") == .pushed)
        #expect(answer(.exited(0), "*", "[new branch]") == .madeBranch)
        #expect(answer(.exited(1), "!", "[rejected] (fetch first)") == .lostRace)
        #expect(
            answer(.exited(1), "!", "[remote rejected] (protected)")
                == .refused("[remote rejected] (protected)"))
        let refused = ExecResult(
            .exited(1), stdout: "!\ta:refs/heads/feat\t[remote rejected] (hook declined)\n",
            stderr: "remote: error: GH006: Protected branch update failed.   \nerror: failed\n")
        #expect(
            PushPlan.answer(refused)
                == .refused(
                    "[remote rejected] (hook declined) remote: error: GH006: Protected branch "
                        + "update failed."))
        #expect(PushPlan.answer(ExecResult(.timedOut, stderr: "non-fast-forward")) == .failed)
        #expect(answer(.exited(128), " ", "fatal: unable to access") == .failed)
    }

    // A refusal whose line says that the token needs the workflow scope has its own case, from the
    // [remote rejected] line of git push and from the GraphQL error of a signed commit. Each other
    // refusal stays a plain refusal. The line stays for the Event log.
    @Test func aRefusalThatNamesTheWorkflowScopeHasItsOwnCase() {
        let push =
            "[remote rejected] (refusing to allow an OAuth App to create or update workflow "
            + "`.github/workflows/build.yml` without `workflow` scope)"
        #expect(PushRefusal.server(push) == .workflowScope(push))
        let signed =
            "Refusing to allow an OAuth App to create or update a Workflow without WORKFLOW Scope"
        #expect(PushRefusal.server(signed) == .workflowScope(signed))
        let protected = "[remote rejected] (protected)"
        #expect(PushRefusal.server(protected) == .refused(protected))
        let other = "Updates a workflow file"
        #expect(PushRefusal.server(other) == .refused(other))
        #expect(PushRefusal.workflowScope(push).detail == push)
        #expect(!PushRefusal.workflowScope(push).keepsOtherWrites)
        #expect(
            PushRefusal.workflowScope("x").message
                == "GitHub refused Claude's fix because it changes a workflow file and your GitHub "
                + "login can't push workflow changes, so run gh auth refresh -h github.com -s "
                + "workflow in a terminal and then try again.")
    }

    // The words of the workflow scope are read before the reason is cut to 200 characters, so a
    // long path can't hide them.
    @Test func aLongReasonStillNamesTheWorkflowScope() {
        let path = String(repeating: "a/", count: 120) + "build.yml"
        let reason = "(refusing to allow an OAuth App to create or update workflow `\(path)` "
            + "without `workflow` scope)"
        let result = ExecResult(
            .exited(1), stdout: "!\ta:refs/heads/feat\t[remote rejected] \(reason)\n")
        guard case .workflowScope(let line) = PushPlan.answer(result) else {
            Issue.record("Wrong answer: \(PushPlan.answer(result))")
            return
        }
        #expect(line.count == 200 && line.hasPrefix("[remote rejected] (refusing"))
    }

    // A tree listing gives the mode and the object of each path. A fix commit holds only plain
    // and executable files: a link and a submodule are refused.
    @Test func aTreeListingGivesEachModeAndTheFileRule() {
        let (one, two) = (String(repeating: "1", count: 40), String(repeating: "2", count: 40))
        let listing = TreeEntry.listing(
            "100644 blob \(one)\ta b.txt\0120000 blob \(two)\tlink\0")
        #expect(
            listing == [
                "a b.txt": TreeEntry(mode: "100644", object: one),
                "link": TreeEntry(mode: "120000", object: two),
            ])
        #expect(TreeEntry.listing("100644 blob \(one) no tab\0") == nil)
        // A listing with sizes (ls-tree -l): spaces before the size, and "-" for a submodule.
        let sized = "100644 blob \(one)      12\ta.txt\0160000 commit \(two)       -\tsub\0"
        #expect(
            TreeEntry.listing(sized)
                == [
                    "a.txt": TreeEntry(mode: "100644", object: one, size: 12),
                    "sub": TreeEntry(mode: "160000", object: two),
                ])
        #expect(TreeEntry.listing("") == [:])
        #expect(TreeEntry.refusal("100644") == nil && TreeEntry.refusal("100755") == nil)
        #expect(TreeEntry.refusal("120000") == .link && TreeEntry.refusal("160000") == .submodule)
    }

    // The raw form of a commit gives its tree, its parents, its message and its signature.
    @Test func theRawFormOfACommitGivesItsParts() {
        let tree = String(repeating: "1", count: 40)
        let (one, two) = (String(repeating: "2", count: 40), String(repeating: "3", count: 40))
        let raw =
            "tree \(tree)\nparent \(one)\nparent \(two)\nauthor A <a@x> 1 +0000\n"
            + "committer A <a@x> 1 +0000\n\nfix: the thing\n\nThe body.\n"
        let commit = CommitObject(raw)
        #expect(commit?.tree == tree && commit?.parents.map(\.hex) == [one, two])
        #expect(commit?.message == "fix: the thing\n\nThe body.\n" && commit?.signed == false)
        #expect(CommitObject("tree \(tree)\ngpgsig -----BEGIN\n\nm\n")?.signed == true)
        #expect(CommitObject("no commit") == nil)
        let parts = PushPlan.signedMessage("fix: the thing\n\nThe body.\n")
        #expect(parts.headline == "fix: the thing" && parts.body == "The body.")
    }
}
