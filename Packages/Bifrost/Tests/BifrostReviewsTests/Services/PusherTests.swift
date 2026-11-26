// The push of a fix (docs/behaviour/reviews.md, "The push and the writes"), with the real git on a
// local source that plays GitHub: its branch feat is the head branch of PR 7. A test moves or
// rewrites feat as another person would, and checks what reached the source.
import BifrostFoundation
import BifrostTestSupport
import Foundation
import Synchronization
import Testing

@testable import BifrostReviews

@Suite("the push of a fix", .serialized, .timeLimit(.minutes(3)), .tags(.realProcess))
struct PusherTests {
    // The branch is at the head of the round: the fix goes as a fast-forward.
    @Test func anAncestorBranchGetsAFastForwardPush() async throws {
        let f = try await PushTestRepo.make()
        defer { f.remove() }
        let fix = try await f.fix(["a.txt": "fixed\n"])
        let result = try await Pusher(git: f.git, address: f.address)
            .push(fix, head: f.head, pr: f.pr, to: try f.target)
        let push = GitPush(commit: fix, branch: try f.target.branch)
        #expect(result == PushResult(step: .push(push), commit: fix))
        #expect(try await f.branch() == fix)
        #expect(f.runner.pushes.count == 1 && f.runner.fetches.count == 2)
    }

    // Another person pushed to the branch while Claude worked: the fix and the branch merge with
    // merge-tree and commit-tree, and the merge goes as a fast-forward. No force: the commit of
    // the other person stays on the branch.
    @Test func aMovedBranchGetsAMergeAndNoForce() async throws {
        let f = try await PushTestRepo.make()
        defer { f.remove() }
        let fix = try await f.fix(["a.txt": "fixed\n"])
        let other = try await f.moveBranch("d.txt", "theirs\n")
        let result = try await Pusher(git: f.git, address: f.address)
            .push(fix, head: f.head, pr: f.pr, to: try f.target)
        guard case .merge(let push) = result.step else {
            Issue.record("The step is \(result.step), not a merge.")
            return
        }
        #expect(result.commit == push.commit && push.commit != fix)
        let now = try await f.branch()
        #expect(now == push.commit)
        let parents = try await f.output(
            ["rev-list", "--parents", "-n", "1", now.hex], in: f.repo.source)
        #expect(parents == "\(now.hex) \(fix.hex) \(other.hex)")
        for args in f.runner.pushes {
            #expect(!args.contains { $0.hasPrefix("--force") || $0 == "-f" })
            #expect(args.last?.hasPrefix("+") == false)
        }
        let files = try await f.output(["ls-tree", "--name-only", now.hex], in: f.repo.source)
        #expect(files.split(separator: "\n") == ["a.txt", "d.txt"])
    }

    // The other person changed the same line: the merge has a conflict, and nothing goes.
    @Test func aConflictPushesNothing() async throws {
        let f = try await PushTestRepo.make()
        defer { f.remove() }
        let fix = try await f.fix(["a.txt": "fixed\n"])
        let other = try await f.moveBranch("a.txt", "theirs\n")
        await #expect(throws: PushRefusal.conflict) {
            _ = try await Pusher(git: f.git, address: f.address)
                .push(fix, head: f.head, pr: f.pr, to: try f.target)
        }
        #expect(try await f.branch() == other)
        #expect(f.runner.pushes.isEmpty)
    }

    // The user rewrote the branch, so the head of the round is not on it: nothing goes, so no
    // merge puts back what the user removed.
    @Test func aRewrittenBranchPushesNothing() async throws {
        let f = try await PushTestRepo.make()
        defer { f.remove() }
        let fix = try await f.fix(["a.txt": "fixed\n"])
        let tree = try await f.output(["rev-parse", "\(f.head.hex)^{tree}"], in: f.repo.source)
        let root = try await f.output(["commit-tree", tree, "-m", "rewritten"], in: f.repo.source)
        try await f.output(["update-ref", "refs/heads/feat", root], in: f.repo.source)
        await #expect(throws: PushRefusal.rewritten) {
            _ = try await Pusher(git: f.git, address: f.address)
                .push(fix, head: f.head, pr: f.pr, to: try f.target)
        }
        #expect(try await f.branch().hex == root)
        #expect(f.runner.pushes.isEmpty)
    }

    // The branch moves between the fetch and the push: GitHub refuses the push, so Bifrost
    // fetches again and tries once more, with a merge.
    @Test func aRefusedPushFetchesAndTriesOnceMore() async throws {
        let moved = Mutex(false)
        let place = Mutex<(source: String, env: [String: String])?>(nil)
        let f = try await PushTestRepo.make { args in
            guard RecordingGit.isPush(args), let spot = place.withLock({ $0 }),
                moved.withLock({ flag in
                    defer { flag = true }
                    return !flag
                })
            else { return }
            _ = try? await PushTestRepo.moveBranch(
                "d.txt", "theirs\n", source: spot.source, env: spot.env)
        }
        defer { f.remove() }
        place.withLock { $0 = (f.repo.source, f.repo.env) }
        let fix = try await f.fix(["a.txt": "fixed\n"])
        let result = try await Pusher(git: f.git, address: f.address)
            .push(fix, head: f.head, pr: f.pr, to: try f.target)
        // A fetch before each push, and one after the last push.
        #expect(f.runner.pushes.count == 2 && f.runner.fetches.count == 3)
        guard case .merge(let push) = result.step else {
            Issue.record("The step is \(result.step), not a merge.")
            return
        }
        #expect(try await f.branch() == push.commit)
    }

    // A second URL of origin, a push URL, or an insteadOf rule that sends the fetch or the push
    // to another address stops the push before any network call.
    @Test func aSecondOriginURLOrAnInsteadOfRuleStopsThePush() async throws {
        let f = try await PushTestRepo.make()
        defer { f.remove() }
        let fix = try await f.fix(["a.txt": "fixed\n"])
        let clone = f.repo.clone
        let rules: [[String]] = [
            ["config", "--add", "remote.origin.url", "https://example.invalid/other.git"],
            ["config", "remote.origin.pushurl", "https://example.invalid/other.git"],
            ["config", "url.https://example.invalid/.insteadOf", "file://"],
            ["config", "url.https://example.invalid/.pushInsteadOf", "file://"],
        ]
        func config() async throws -> Set<Substring> {
            let list = try await f.output(["config", "--list", "--local"], in: clone)
            return Set(list.split(separator: "\n"))
        }
        for rule in rules {
            let saved = try await config()
            try await f.output(rule, in: clone)
            await #expect(throws: PushRefusal.target) {
                _ = try await Pusher(git: f.git, address: f.address)
                    .push(fix, head: f.head, pr: f.pr, to: try f.target)
            }
            // The rule goes, and the clone has its config of before again.
            let key = rule[1] == "--add" ? rule[2] : rule[1]
            try await f.output(["config", "--unset-all", key], in: clone)
            if key == "remote.origin.url" {
                try await f.output(["config", key, f.address.absoluteString], in: clone)
            }
            #expect(try await config() == saved)
        }
        #expect(f.runner.fetches.isEmpty && f.runner.pushes.isEmpty)
        #expect(try await f.branch() == f.head)
    }

    // The base branch and the default branch of the repository are never a target, in any case.
    @Test func theBaseOrDefaultBranchIsNeverATarget() async throws {
        let f = try await PushTestRepo.make()
        defer { f.remove() }
        let fix = try await f.fix(["a.txt": "fixed\n"])
        let targets = [
            ("main", "main", "main"), ("Release", "release", "main"), ("TRUNK", "main", "trunk"),
        ]
        for (branch, base, main) in targets {
            let target = PushTarget(
                branch: try #require(BranchName(branch)), base: base, defaultBranch: main,
                isFork: false)
            await #expect(throws: PushRefusal.target) {
                _ = try await Pusher(git: f.git, address: f.address)
                    .push(fix, head: f.head, pr: f.pr, to: target)
            }
        }
        var fork = try f.target
        fork.isFork = true
        await #expect(throws: PushRefusal.fork) {
            _ = try await Pusher(git: f.git, address: f.address)
                .push(fix, head: f.head, pr: f.pr, to: fork)
        }
        #expect(f.runner.fetches.isEmpty && f.runner.pushes.isEmpty)
    }

    // The branch has the fix already (a push of an earlier run that a quit cut off): nothing
    // goes.
    @Test func aBranchWithTheFixPushesNothing() async throws {
        let f = try await PushTestRepo.make()
        defer { f.remove() }
        let fix = try await f.fix(["a.txt": "fixed\n"])
        let pusher = Pusher(git: f.git, address: f.address)
        _ = try await pusher.push(fix, head: f.head, pr: f.pr, to: try f.target)
        let again = try await pusher.push(fix, head: f.head, pr: f.pr, to: try f.target)
        #expect(again == PushResult(step: .nothing(fix), commit: fix))
        #expect(f.runner.pushes.count == 1)
        // Each check of the branch is a merge-base --is-ancestor of git.
        #expect(f.runner.all.contains { $0.contains("--is-ancestor") })
    }

    // The other person moved the fixed file below .github/workflows. merge-tree follows the
    // rename, so the merge would change a workflow: nothing goes, as for a conflict.
    @Test func aMergeThatChangesAWorkflowPushesNothing() async throws {
        let f = try await PushTestRepo.make()
        defer { f.remove() }
        let fix = try await f.fix(["a.txt": "fixed\n"])
        let source = f.repo.source
        try await f.output(["checkout", "-q", "feat"], in: source)
        try FileManager.default.createDirectory(
            atPath: source + "/.github/workflows", withIntermediateDirectories: true)
        try await f.output(["mv", "a.txt", ".github/workflows/a.txt"], in: source)
        try await f.output(["commit", "-q", "-m", "move"], in: source)
        try await f.output(["checkout", "-q", "main"], in: source)
        let moved = try await f.branch()
        await #expect(throws: PushRefusal.conflict) {
            _ = try await Pusher(git: f.git, address: f.address)
                .push(fix, head: f.head, pr: f.pr, to: try f.target)
        }
        #expect(f.runner.pushes.isEmpty)
        #expect(try await f.branch() == moved)
    }

    // GitHub refuses the branch ([remote rejected], here a hook as for a protected branch). Each
    // run would get the same refusal, so the outbox goes: nothing is posted, the item waits in
    // held, and the Event log has the reason of the server.
    @MainActor
    @Test func aBranchThatTheServerRefusesDropsTheOutbox() async throws {
        let repo = try await PushTestRepo.make()
        defer { repo.remove() }
        let hook = repo.repo.source + "/.git/hooks/pre-receive"
        try "#!/bin/sh\necho 'protected branch' >&2\nexit 1\n".write(
            toFile: hook, atomically: false, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hook)
        try repo.repo.write("a.txt", "fixed\n", in: repo.repo.worktree)
        let f = try await WritesFixture(repo: repo) {
            WritesData.github(head: $0, threads: [WritesData.thread("PRRT_1")])
        }
        let item = try ReviewData.node("PRRT_1")
        await f.save(
            f.outbox(
                [Posts.commit(["a.txt"]), Posts.push(), try Posts.reply("PRRT_1", nil),
                    try Posts.resolve("PRRT_1")], seen: [item: Rows.at(-120)]))
        let reason = "[remote rejected] (pre-receive hook declined) remote: protected branch"
        await #expect(throws: RoundFailure.pushFailed(.refused(reason))) {
            try await f.writes.run(try #require(f.state?.outbox), for: f.pr)
        }
        #expect(repo.runner.pushes.count == 1 && f.written.isEmpty)
        #expect(f.state?.outbox == nil && f.state?.held == [item])
        #expect(f.lines.values.contains { $0.hasSuffix("git said: \(reason)") })
        #expect(try await repo.branch() == repo.head)
        await f.end()
    }

    // A hook that says the token needs the workflow scope (as GitHub does for a change of a
    // workflow file) gives the refusal with its own case, and the Event log has the line.
    @MainActor
    @Test func aPushThatNeedsTheWorkflowScopeHasItsOwnRefusal() async throws {
        let repo = try await PushTestRepo.make()
        defer { repo.remove() }
        let hook = repo.repo.source + "/.git/hooks/pre-receive"
        try "#!/bin/sh\necho 'without workflow scope' >&2\nexit 1\n".write(
            toFile: hook, atomically: false, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hook)
        let fix = try await repo.fix(["a.txt": "fixed\n"])
        let target = try repo.target
        do throws(PushRefusal) {
            _ = try await Pusher(git: repo.git, address: repo.address)
                .push(fix, head: repo.head, pr: repo.pr, to: target)
            Issue.record("The push should have failed.")
        } catch {
            guard case .workflowScope(let line) = error else {
                Issue.record("Wrong refusal: \(error)")
                return
            }
            #expect(line.contains("[remote rejected]") && line.contains("workflow scope"))
        }
    }

    // Another person changed the fixed line: the push has a conflict. The other reply and its
    // resolve still go, the "Fixed by" reply and its resolve drop, the outbox goes, the fixed item
    // waits in held and the other item is handled.
    @MainActor
    @Test func aConflictPostsTheOtherRepliesAndHoldsTheFixedItem() async throws {
        let repo = try await PushTestRepo.make()
        defer { repo.remove() }
        try repo.repo.write("a.txt", "fixed\n", in: repo.repo.worktree)
        let other = try await repo.moveBranch("a.txt", "theirs\n")
        let f = try await WritesFixture(repo: repo) {
            WritesData.github(
                head: $0, threads: [WritesData.thread("PRRT_1"), WritesData.thread("PRRT_2")])
        }
        let (fixed, kept) = (try ReviewData.node("PRRT_1"), try ReviewData.node("PRRT_2"))
        await f.save(
            f.outbox(
                [
                    Posts.commit(["a.txt"]), Posts.push(), try Posts.reply("PRRT_1", nil),
                    try Posts.resolve("PRRT_1"), try Posts.reply("PRRT_2", "No change needed."),
                    try Posts.resolve("PRRT_2"), Posts.rerequest(),
                ], seen: [fixed: Rows.at(-120), kept: Rows.at(-120)]))
        await #expect(throws: RoundFailure.pushFailed(.conflict)) {
            try await f.writes.run(try #require(f.state?.outbox), for: f.pr)
        }
        #expect(
            f.written == [
                .replyToThread(thread: kept, body: "No change needed."), .resolveThread(kept),
            ])
        #expect(repo.runner.pushes.isEmpty)
        #expect(try await repo.branch() == other)
        let state = try #require(f.state)
        #expect(state.outbox == nil && state.held == [fixed] && state.handled[kept] != nil)
        await f.end()
    }

    // The fetch fails (here the source is away for a time): the push can still go later, so the
    // outbox stays with the push as sending, and nothing is posted. Try again checks the branch,
    // pushes the fix and posts the rest.
    @MainActor
    @Test func aFailedFetchKeepsThePushForTryAgain() async throws {
        let repo = try await PushTestRepo.make()
        defer { repo.remove() }
        try repo.repo.write("a.txt", "fixed\n", in: repo.repo.worktree)
        let f = try await WritesFixture(repo: repo) {
            WritesData.github(head: $0, threads: [WritesData.thread("PRRT_1")])
        }
        let item = try ReviewData.node("PRRT_1")
        await f.save(
            f.outbox(
                [Posts.commit(["a.txt"]), Posts.push(), try Posts.reply("PRRT_1", nil),
                    try Posts.resolve("PRRT_1")], seen: [item: Rows.at(-120)]))
        let (source, away) = (repo.repo.source, repo.repo.source + "-away")
        try FileManager.default.moveItem(atPath: source, toPath: away)
        let outbox = try #require(f.state?.outbox)
        do throws(RoundFailure) {
            try await f.writes.run(outbox, for: f.pr)
            Issue.record("The writes went with no source.")
        } catch {
            guard case .pushFailed(.git(_)) = error else {
                Issue.record("The failure is \(error), not a git failure.")
                return
            }
        }
        let kept = try #require(f.state?.outbox)
        #expect(kept.posts.map(\.state) == [.done, .sending, .todo, .todo])
        #expect(f.written.isEmpty && f.lines.values.contains { $0.contains("git said:") })
        try FileManager.default.moveItem(atPath: away, toPath: source)
        try await f.writes.run(kept, for: f.pr)
        let fix = try await repo.branch()
        #expect(fix != repo.head)
        #expect(
            f.written == [
                .replyToThread(thread: item, body: "Fixed by \(fix.short)"), .resolveThread(item),
            ])
        #expect(f.state?.outbox == nil && f.state?.handled[item] != nil)
        await f.end()
    }

    // Bifrost quits while git reads the config of origin for the checks of the target: the push
    // stays sending, no refusal drops the outbox, and the next start pushes the fix.
    @MainActor
    @Test func aQuitDuringTheTargetChecksKeepsThePush() async throws {
        let quit = Mutex<Task<Void, Never>?>(nil)
        let repo = try await PushTestRepo.make { args in
            guard args.contains("--get-all") else { return }
            quit.withLock { task in
                task?.cancel()
                task = nil
            }
        }
        defer { repo.remove() }
        try repo.repo.write("a.txt", "fixed\n", in: repo.repo.worktree)
        let f = try await WritesFixture(repo: repo) {
            WritesData.github(head: $0, threads: [WritesData.thread("PRRT_1")])
        }
        let item = try ReviewData.node("PRRT_1")
        await f.save(
            f.outbox(
                [Posts.commit(["a.txt"]), Posts.push(), try Posts.reply("PRRT_1", nil),
                    try Posts.resolve("PRRT_1")], seen: [item: Rows.at(-120)]),
            posting: true, items: [item: Rows.at(-120)])
        let task = Task { await f.writes.resume(f.pr) }
        quit.withLock { $0 = task }
        await task.value
        let kept = try #require(f.state?.outbox)
        #expect(kept.posts.map(\.state) == [.done, .sending, .todo, .todo])
        #expect(f.state?.round?.phase == .posting && f.state?.lastError == nil)
        #expect(f.lines.values.isEmpty && f.written.isEmpty && repo.runner.pushes.isEmpty)

        let restarted = RoundWrites(
            store: f.store, github: GitHubClient(access: f.github), repos: f.repos,
            clock: GapClock(), now: { Rows.now }, viewer: { WritesData.viewer },
            eventLine: { _ in })
        await restarted.resume(f.pr)
        let fix = try await repo.branch()
        #expect(fix != repo.head && repo.runner.pushes.count == 1)
        #expect(f.written.first == .replyToThread(thread: item, body: "Fixed by \(fix.short)"))
        #expect(f.state?.round == nil && f.state?.outbox == nil)
        await f.end()
    }

    // MARK: - The merge of a conflict round

    // The merge of the head of the round and a new commit of the base branch main, as a conflict
    // round makes it. The result is the merge and the base.
    private func mergeOfBase(_ f: PushTestRepo) async throws -> (merge: CommitID, base: CommitID) {
        try await f.commit(on: "main", ["b.txt": "base\n"])
        let base = try await f.fetch("main", to: "refs/bifrost/base/7")
        return (try await f.merge(head: f.head, base: base), base)
    }

    // A merge must have the head and the base as its parents, in that order. With no parents
    // given, the one parent must be the head, so a merge is refused, and a fix is refused as a
    // merge. Each refusal comes before any network call.
    @Test func aMergePushChecksBothParents() async throws {
        let f = try await PushTestRepo.make()
        defer { f.remove() }
        let (merge, base) = try await mergeOfBase(f)
        let fix = try await f.fix(["a.txt": "fixed\n"])
        let pusher = Pusher(git: f.git, address: f.address)
        let refused: [(CommitID, [CommitID]?)] = [
            (merge, nil), (merge, [f.head]), (merge, [base, f.head]), (merge, [f.head, fix]),
            (fix, [f.head, base]),
        ]
        for (commit, parents) in refused {
            await #expect(throws: PushRefusal.target) {
                _ = try await pusher.push(
                    commit, head: f.head, pr: f.pr, to: try f.target, parents: parents,
                    onMove: .stop)
            }
        }
        #expect(f.runner.fetches.isEmpty && f.runner.pushes.isEmpty)
        let result = try await pusher.push(
            merge, head: f.head, pr: f.pr, to: try f.target, parents: [f.head, base],
            onMove: .stop)
        #expect(result.commit == merge && f.runner.pushes.count == 1)
        #expect(try await f.branch() == merge)
    }

    // Another person pushed to the branch after the round read it: a conflict round pushes
    // nothing and makes no merge of its own, because the new head is a new case.
    @Test func aMovedBranchStopsAMergePush() async throws {
        let f = try await PushTestRepo.make()
        defer { f.remove() }
        let (merge, base) = try await mergeOfBase(f)
        let other = try await f.moveBranch("d.txt", "theirs\n")
        await #expect(throws: PushRefusal.moved) {
            _ = try await Pusher(git: f.git, address: f.address)
                .push(
                    merge, head: f.head, pr: f.pr, to: try f.target, parents: [f.head, base],
                    onMove: .stop)
        }
        #expect(f.runner.pushes.isEmpty && f.runner.fetches.count == 1)
        #expect(!f.runner.all.contains { $0.contains("merge-tree") || $0.contains("commit-tree") })
        #expect(try await f.branch() == other)
    }

    // The base branch and the default branch are never the target of a merge, in any case.
    @Test func aMergePushToTheBaseBranchIsRefused() async throws {
        let f = try await PushTestRepo.make()
        defer { f.remove() }
        let (merge, base) = try await mergeOfBase(f)
        let targets = [("main", "main", "main"), ("Develop", "develop", "main")]
        for (branch, baseName, main) in targets {
            let target = PushTarget(
                branch: try #require(BranchName(branch)), base: baseName, defaultBranch: main,
                isFork: false)
            await #expect(throws: PushRefusal.target) {
                _ = try await Pusher(git: f.git, address: f.address)
                    .push(
                        merge, head: f.head, pr: f.pr, to: target, parents: [f.head, base],
                        onMove: .stop)
            }
        }
        #expect(f.runner.fetches.isEmpty && f.runner.pushes.isEmpty)
        #expect(try await f.output(["rev-parse", "main"], in: f.repo.source) == base.hex)
    }

    // The branch is still at the head: the merge goes as one fast-forward push with no force, and
    // the branch then has the merge with its two parents.
    @Test func aMergePushIsAFastForwardWithNoForce() async throws {
        let f = try await PushTestRepo.make()
        defer { f.remove() }
        let (merge, base) = try await mergeOfBase(f)
        let result = try await Pusher(git: f.git, address: f.address)
            .push(
                merge, head: f.head, pr: f.pr, to: try f.target, parents: [f.head, base],
                onMove: .stop)
        let push = GitPush(commit: merge, branch: try f.target.branch)
        #expect(result == PushResult(step: .push(push), commit: merge))
        #expect(try await f.branch() == merge)
        let parents = try await f.output(
            ["rev-list", "--parents", "-n", "1", merge.hex], in: f.repo.source)
        #expect(parents == "\(merge.hex) \(f.head.hex) \(base.hex)")
        #expect(f.runner.pushes.count == 1)
        for args in f.runner.pushes {
            #expect(!args.contains { $0.hasPrefix("--force") || $0 == "-f" })
            #expect(args.last == "\(merge.hex):refs/heads/feat")
        }
        #expect(try await f.output(["rev-parse", "main"], in: f.repo.source) == base.hex)
    }
}
