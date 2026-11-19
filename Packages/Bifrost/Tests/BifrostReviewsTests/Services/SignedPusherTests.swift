// The signed push of a fix (docs/behaviour/reviews.md, "The push and the writes"): the real git on
// a local source, and a fake GitHub that plays createCommitOnBranch on the source as GitHub does:
// it refuses a branch that is not at the expected head, else it makes its own commit of the
// changes on that head.
import BifrostFoundation
import BifrostTestSupport
import Foundation
import Testing

@testable import BifrostReviews

@MainActor
@Suite("the signed push of a fix", .serialized, .timeLimit(.minutes(1)), .tags(.realProcess))
struct SignedPusherTests {
    // GitHub makes the commit on feat of the source: the changes of the write on its head.
    static func playGitHub(_ github: FakeGitHub, _ repo: PushTestRepo) {
        let (source, env) = (repo.repo.source, repo.repo.env)
        github.onWrite = { [weak github] write in
            guard case .createSignedCommit(let commit) = write else { return }
            let head = try? await PushTestRepo.branch(source: source, env: env)
            guard head == commit.expectedHead else {
                github?.answers["createCommitOnBranch"] = .failure(
                    .refused("Expected branch to point to \(commit.expectedHead.hex)"))
                return
            }
            _ = try? await PushTestRepo.git(["checkout", "-q", "feat"], in: source, env: env)
            for change in commit.changes {
                let file = URL(filePath: source + "/" + change.path)
                if let contents = change.contents {
                    try? contents.write(to: file)
                } else {
                    try? FileManager.default.removeItem(at: file)
                }
            }
            _ = try? await PushTestRepo.git(["add", "-A"], in: source, env: env)
            _ = try? await PushTestRepo.git(
                ["commit", "-q", "-m", commit.headline], in: source, env: env)
            _ = try? await PushTestRepo.git(["checkout", "-q", "main"], in: source, env: env)
            guard let made = try? await PushTestRepo.branch(source: source, env: env) else {
                return
            }
            github?.answers["createCommitOnBranch"] = .success(WritesData.signed(made))
        }
    }

    // The write expects the head of the round, so GitHub refuses a branch that moved. The result
    // is the commit that GitHub made, which is not the local fix commit. A branch that moved gets
    // no write at all.
    @Test func theSignedCommitExpectsTheRoundHead() async throws {
        let f = try await PushTestRepo.make()
        defer { f.remove() }
        let fix = try await f.fix(["a.txt": "fixed\n"])
        let github = FakeGitHub()
        Self.playGitHub(github, f)
        let result = try await SignedPusher(
            git: f.git, address: f.address, github: GitHubClient(access: github)
        ).push(fix, head: f.head, paths: ["a.txt"], pr: f.pr, to: try f.target)
        let made = try await f.branch()
        #expect(result.commit == made && made != fix)
        let expected = SignedCommit(
            repo: f.pr.repo, branch: try f.target.branch, expectedHead: f.head,
            headline: "fix: the review comments", body: "",
            changes: [FileChange(path: "a.txt", contents: Data("fixed\n".utf8))])
        #expect(result.step == .signed(expected))
        #expect(github.calls == [.write(.createSignedCommit(expected))])
        #expect(f.runner.pushes.isEmpty)

        let g = try await PushTestRepo.make()
        defer { g.remove() }
        let other = try await g.fix(["a.txt": "fixed\n"])
        let moved = try await g.moveBranch("d.txt", "theirs\n")
        let none = FakeGitHub()
        await #expect(throws: PushRefusal.moved) {
            _ = try await SignedPusher(
                git: g.git, address: g.address, github: GitHubClient(access: none)
            ).push(other, head: g.head, paths: ["a.txt"], pr: g.pr, to: try g.target)
        }
        #expect(none.calls.isEmpty)
        #expect(try await g.branch() == moved)
    }

    // A PR from a fork gets no write and runs no git.
    @Test func aForkIsRefusedBeforeAnyWrite() async throws {
        let f = try await PushTestRepo.make()
        defer { f.remove() }
        let fix = try await f.fix(["a.txt": "fixed\n"])
        let github = FakeGitHub()
        Self.playGitHub(github, f)
        var target = try f.target
        target.isFork = true
        let runs = f.runner.all.count
        await #expect(throws: PushRefusal.fork) {
            _ = try await SignedPusher(
                git: f.git, address: f.address, github: GitHubClient(access: github)
            ).push(fix, head: f.head, paths: ["a.txt"], pr: f.pr, to: target)
        }
        #expect(github.calls.isEmpty)
        #expect(f.runner.all.count == runs)
        #expect(try await f.branch() == f.head)
    }

    // Each file is under the limit of a fix commit, but their sum is over the 4 MiB that a signed
    // commit can carry: nothing goes, and nothing reaches the network.
    @Test func aSumOver4MiBIsRefused() async throws {
        let f = try await PushTestRepo.make()
        defer { f.remove() }
        let text = String(repeating: "x", count: 900_000) + "\n"
        var files: [String: String] = [:]
        for number in 1...5 { files["f\(number).txt"] = text }
        let fix = try await f.fix(files)
        let github = FakeGitHub()
        await #expect(throws: PushRefusal.tooLarge) {
            _ = try await SignedPusher(
                git: f.git, address: f.address, github: GitHubClient(access: github)
            ).push(fix, head: f.head, paths: files.keys.sorted(), pr: f.pr, to: try f.target)
        }
        #expect(github.calls.isEmpty)
        #expect(f.runner.fetches.isEmpty)
    }

    // The "Fixed by" reply of a signed fix names the commit that GitHub made, which is on the
    // branch, and not the local fix commit.
    @Test func theRepliesNameTheCommitThatGitHubMade() async throws {
        let repo = try await PushTestRepo.make()
        defer { repo.remove() }
        try repo.repo.write("a.txt", "fixed\n", in: repo.repo.worktree)
        let f = try await WritesFixture(repo: repo) {
            WritesData.github(head: $0, threads: [WritesData.thread("PRRT_1")])
        }
        Self.playGitHub(f.github, repo)
        let item = try ReviewData.node("PRRT_1")
        await f.save(
            f.outbox(
                [
                    Posts.commit(["a.txt"]), Posts.push(signed: true),
                    try Posts.reply("PRRT_1", nil), try Posts.resolve("PRRT_1"),
                    Posts.rerequest(),
                ], seen: [item: Rows.at(-120)]))
        try await f.writes.run(try #require(f.state?.outbox), for: f.pr)
        let made = try await repo.branch()
        let body = "Fixed by \(made.short)"
        #expect(f.written.count == 3)
        #expect(f.written.dropFirst().first == .replyToThread(thread: item, body: body))
        #expect(f.written.last == .resolveThread(item))
        #expect(f.state?.outbox == nil && f.state?.handled[item] != nil)
        #expect(f.store.state.posted.map(\.body) == [body])
        let fix = try await repo.output(["rev-parse", "HEAD"], in: repo.repo.worktree)
        #expect(fix != made.hex)
        await f.end()
    }

    // The bytes of each file come from the blob of the fix commit, not from the worktree. With
    // eol=crlf, the worktree file has CRLF line ends and the blob has LF, so the worktree bytes
    // never match the blob. A file that is not UTF-8 text keeps each byte.
    @Test func theFilesComeFromGitAndNotFromTheWorktree() async throws {
        let f = try await PushTestRepo.make(files: [".gitattributes": "*.txt text eol=crlf\n"])
        defer { f.remove() }
        let worktree = f.repo.worktree
        let checkedOut = try Data(contentsOf: URL(filePath: worktree + "/a.txt"))
        #expect(checkedOut == Data("one\r\n".utf8))
        let binary = Data([0x00, 0xFF, 0xFE, 0x0D, 0x0A, 0x80])
        try Data("fixed\r\n".utf8).write(to: URL(filePath: worktree + "/a.txt"))
        try binary.write(to: URL(filePath: worktree + "/b.bin"))
        let paths = ["a.txt", "b.bin"]
        let fix = try await FixCommit.make(
            paths: paths, message: "fix: line ends", head: f.head, pr: f.pr, git: f.git)
        let github = FakeGitHub()
        Self.playGitHub(github, f)
        let result = try await SignedPusher(
            git: f.git, address: f.address, github: GitHubClient(access: github)
        ).push(fix, head: f.head, paths: paths, pr: f.pr, to: try f.target)
        guard case .signed(let commit) = result.step else {
            Issue.record("The step is \(result.step), not a signed commit.")
            return
        }
        #expect(
            commit.changes == [
                FileChange(path: "a.txt", contents: Data("fixed\n".utf8)),
                FileChange(path: "b.bin", contents: binary),
            ])
        #expect(result.commit == (try await f.branch()))
    }

    // GitHub made the signed commit, but a quit cut off the run before the answer. The next run
    // finds the commit of GitHub on the branch and sends nothing again.
    @Test func aCutOffSignedCommitIsFoundAgain() async throws {
        let f = try await PushTestRepo.make()
        defer { f.remove() }
        let fix = try await f.fix(["a.txt": "fixed\n"])
        let github = FakeGitHub()
        Self.playGitHub(github, f)
        _ = try await SignedPusher(
            git: f.git, address: f.address, github: GitHubClient(access: github)
        ).push(fix, head: f.head, paths: ["a.txt"], pr: f.pr, to: try f.target)
        let made = try await f.branch()
        let none = FakeGitHub()
        let again = try await SignedPusher(
            git: f.git, address: f.address, github: GitHubClient(access: none)
        ).push(fix, head: f.head, paths: ["a.txt"], pr: f.pr, to: try f.target)
        #expect(again == PushResult(step: .nothing(made), commit: made))
        #expect(none.calls.isEmpty)
        #expect(try await f.branch() == made)
    }
}
