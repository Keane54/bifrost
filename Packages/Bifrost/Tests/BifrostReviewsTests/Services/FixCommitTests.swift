// The fix commit of a request round (docs/behaviour/reviews.md, "The push and the writes"), with
// the real git on the worktree of PR 7 of a local repository.
import BifrostFoundation
import BifrostTestSupport
import Foundation
import Synchronization
import Testing

@testable import BifrostReviews

@MainActor
@Suite("the fix commit", .serialized, .timeLimit(.minutes(1)), .tags(.realProcess))
struct FixCommitTests {
    // The session changed three files and listed two: the commit holds only the two, on the head,
    // and a cut-off run finds the same commit again.
    @Test func onlyTheListedFilesAreCommitted() async throws {
        let f = try await PushTestRepo.make(files: ["b.txt": "two\n"])
        defer { f.remove() }
        let worktree = f.repo.worktree
        try f.repo.write("a.txt", "fixed\n", in: worktree)
        try f.repo.write("b.txt", "not listed\n", in: worktree)
        try f.repo.write("src/c.txt", "new\n", in: worktree)
        let fix = try await FixCommit.make(
            paths: ["a.txt", "src/c.txt"], message: "fix: use the new name", head: f.head,
            pr: f.pr, git: f.git)
        let changed = try await f.output(
            ["diff", "--name-only", f.head.hex, fix.hex], in: f.repo.clone)
        #expect(changed.split(separator: "\n") == ["a.txt", "src/c.txt"])
        let parent = try await f.output(["rev-parse", "\(fix.hex)^"], in: f.repo.clone)
        #expect(parent == f.head.hex)
        let subject = try await f.output(["log", "-1", "--format=%s", fix.hex], in: f.repo.clone)
        #expect(subject == "fix: use the new name")
        let again = try await FixCommit.make(
            paths: ["a.txt", "src/c.txt"], message: "fix: use the new name", head: f.head,
            pr: f.pr, git: f.git)
        #expect(again == fix)
    }

    // A listed workflow file stops the commit before git add: no commit, and the round posts
    // nothing. The outbox goes and its item waits in held.
    @Test func aRefusedFileStopsTheCommitAndPostsNothing() async throws {
        let repo = try await PushTestRepo.make()
        defer { repo.remove() }
        let path = ".github/workflows/ci.yml"
        try repo.repo.write(path, "on: push\n", in: repo.repo.worktree)
        await #expect(throws: FixCommitFailure.refused(.workflow)) {
            _ = try await FixCommit.make(
                paths: [path], message: "fix: the workflow", head: repo.head, pr: repo.pr,
                git: repo.git)
        }
        let f = try await WritesFixture(repo: repo) {
            WritesData.github(head: $0, threads: [WritesData.thread("PRRT_1")])
        }
        let item = try ReviewData.node("PRRT_1")
        await f.save(
            f.outbox(
                [Posts.commit([path]), Posts.push(), try Posts.reply("PRRT_1", nil),
                    try Posts.resolve("PRRT_1"), Posts.rerequest()]))
        let outbox = try #require(f.state?.outbox)
        await #expect(throws: RoundFailure.commitRefused(.workflow)) {
            try await f.writes.run(outbox, for: f.pr)
        }
        #expect(f.written.isEmpty)
        #expect(f.state?.outbox == nil && f.state?.held == [item])
        let now = try await repo.output(["rev-parse", "HEAD"], in: repo.repo.worktree)
        #expect(now == repo.head.hex)
        #expect(repo.runner.pushes.isEmpty)
        await f.end()
    }

    // The session turns a listed file into a link after CommitFileCheck and before git add. git
    // records the link, so the check of the made commit refuses it: nothing is pushed or posted,
    // the worktree goes back to the head, the outbox goes and its item waits in held.
    @Test func aFileThatBecomesALinkBeforeGitAddIsRefused() async throws {
        let worktree = Mutex<String?>(nil)
        let repo = try await PushTestRepo.make { args in
            guard args.contains("add"), args.contains("-A"), let root = worktree.withLock({ $0 })
            else { return }
            let file = root + "/a.txt"
            try? FileManager.default.removeItem(atPath: file)
            try? FileManager.default.createSymbolicLink(
                atPath: file, withDestinationPath: "../../outside.txt")
        }
        defer { repo.remove() }
        worktree.withLock { $0 = repo.repo.worktree }
        try repo.repo.write("a.txt", "fixed\n", in: repo.repo.worktree)
        let f = try await WritesFixture(repo: repo) {
            WritesData.github(head: $0, threads: [WritesData.thread("PRRT_1")])
        }
        let item = try ReviewData.node("PRRT_1")
        await f.save(
            f.outbox(
                [Posts.commit(["a.txt"]), Posts.push(), try Posts.reply("PRRT_1", nil),
                    try Posts.resolve("PRRT_1"), Posts.rerequest()]))
        await #expect(throws: RoundFailure.commitRefused(.link)) {
            try await f.writes.run(try #require(f.state?.outbox), for: f.pr)
        }
        #expect(f.written.isEmpty && repo.runner.pushes.isEmpty)
        #expect(f.state?.outbox == nil && f.state?.held == [item])
        let now = try await repo.output(["rev-parse", "HEAD"], in: repo.repo.worktree)
        #expect(now == repo.head.hex)
        #expect(try await repo.branch() == repo.head)
        await f.end()
    }

    // The session makes a listed file larger than 1 MiB after CommitFileCheck and before git
    // add: the check of the made commit refuses it.
    @Test func aFileThatGrowsBeforeGitAddIsRefused() async throws {
        let worktree = Mutex<String?>(nil)
        let repo = try await PushTestRepo.make { args in
            guard args.contains("add"), args.contains("-A"), let root = worktree.withLock({ $0 })
            else { return }
            let large = Data(repeating: 0x61, count: CommitFileRule.maxFileBytes + 1)
            try? large.write(to: URL(filePath: root + "/a.txt"))
        }
        defer { repo.remove() }
        worktree.withLock { $0 = repo.repo.worktree }
        try repo.repo.write("a.txt", "fixed\n", in: repo.repo.worktree)
        await #expect(throws: FixCommitFailure.refused(.tooLarge)) {
            _ = try await FixCommit.make(
                paths: ["a.txt"], message: "fix: the review comments", head: repo.head,
                pr: repo.pr, git: repo.git)
        }
    }

    // A commit that a resume finds again gets the same check: a commit of an earlier run on the
    // head, with the same subject, that holds a link is refused.
    @Test func aFoundCommitWithALinkIsRefused() async throws {
        let f = try await PushTestRepo.make()
        defer { f.remove() }
        let worktree = f.repo.worktree
        try FileManager.default.removeItem(atPath: worktree + "/a.txt")
        try FileManager.default.createSymbolicLink(
            atPath: worktree + "/a.txt", withDestinationPath: "../../outside.txt")
        try await f.output(["add", "-A"], in: worktree)
        try await f.output(["commit", "-q", "-m", "fix: the review comments"], in: worktree)
        await #expect(throws: FixCommitFailure.refused(.link)) {
            _ = try await FixCommit.make(
                paths: ["a.txt"], message: "fix: the review comments", head: f.head, pr: f.pr,
                git: f.git)
        }
    }

    // Bifrost quits while git makes the fix commit: the outbox keeps the commit as sending, the
    // worktree keeps the fix, and the Event log gets no line. The next start makes the commit,
    // pushes it and posts the reply.
    @Test func aQuitDuringTheFixCommitKeepsTheRound() async throws {
        let quit = Mutex<Task<Void, Never>?>(nil)
        let repo = try await PushTestRepo.make { args in
            guard args.contains("commit"), args.contains("--no-gpg-sign") else { return }
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
        #expect(kept.posts.map(\.state) == [.sending, .todo, .todo, .todo])
        #expect(f.state?.round?.phase == .posting && f.state?.lastError == nil)
        #expect(f.lines.values.isEmpty && f.written.isEmpty && repo.runner.pushes.isEmpty)
        let text = try String(contentsOfFile: repo.repo.worktree + "/a.txt", encoding: .utf8)
        #expect(text == "fixed\n")

        let restarted = RoundWrites(
            store: f.store, github: GitHubClient(access: f.github), repos: f.repos,
            clock: GapClock(), now: { Rows.now }, viewer: { WritesData.viewer },
            eventLine: { _ in })
        await restarted.resume(f.pr)
        let fix = try await repo.branch()
        #expect(fix != repo.head)
        #expect(
            f.written == [
                .replyToThread(thread: item, body: "Fixed by \(fix.short)"), .resolveThread(item),
            ])
        #expect(f.state?.round == nil && f.state?.outbox == nil && f.state?.handled[item] != nil)
        await f.end()
    }

    // A repository that asks git to sign each commit still gets a fix commit with no signature:
    // a key can ask for a passphrase, and a round never waits for a person.
    @Test func theCommitIsNotSigned() async throws {
        let f = try await PushTestRepo.make()
        defer { f.remove() }
        try await f.output(["config", "commit.gpgSign", "true"], in: f.repo.clone)
        try await f.output(["config", "gpg.program", "/usr/bin/false"], in: f.repo.clone)
        try f.repo.write("a.txt", "fixed\n", in: f.repo.worktree)
        let fix = try await FixCommit.make(
            paths: ["a.txt"], message: "fix: no signature", head: f.head, pr: f.pr, git: f.git)
        let raw = try await f.output(["cat-file", "commit", fix.hex], in: f.repo.clone)
        #expect(!raw.contains("gpgsig"))
        #expect(CommitObject(raw + "\n")?.signed == false)
        let commits = f.runner.all.filter { $0.contains("commit") && $0.contains("-m") }
        #expect(commits.count == 1 && commits.allSatisfy { $0.contains("--no-gpg-sign") })
    }
}
