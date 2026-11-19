import BifrostFoundation
import BifrostTestSupport
import Foundation
import Synchronization
import Testing

@testable import BifrostReviews

// The git of a push test: the real git, with a record of the arguments of each run and an
// optional step before each run (for example a push of another person between the fetch and the
// push of Bifrost).
final class RecordingGit: CommandRunner {
    private let runs = Mutex<[[String]]>([])
    private let before: @Sendable ([String]) async -> Void

    init(before: @escaping @Sendable ([String]) async -> Void = { _ in }) {
        self.before = before
    }

    func run(_ command: Command) async -> ExecResult {
        runs.withLock { $0.append(command.arguments) }
        await before(command.arguments)
        return await ProcessRunner().run(command)
    }

    // The arguments of each run, in order.
    var all: [[String]] { runs.withLock { $0 } }

    // The runs of git push and of git fetch.
    var pushes: [[String]] { all.filter(Self.isPush) }
    var fetches: [[String]] { all.filter { $0.contains("fetch") } }

    static func isPush(_ args: [String]) -> Bool {
        args.contains("push") && args.contains("--porcelain")
    }
}

// A GitTestRepo whose source has the head branch feat of PR 7 at the head, with Bifrost's git on
// a RecordingGit. The source is a local repository with main checked out, so a push to feat goes
// in as a push to GitHub would.
struct PushTestRepo {
    let repo: GitTestRepo
    let runner: RecordingGit
    let git: RepoGit

    var pr: PRKey { repo.pr }
    var head: CommitID { repo.head }
    var address: URL { URL(filePath: repo.source) }
    var target: PushTarget {
        get throws {
            PushTarget(
                branch: try #require(BranchName("feat")), base: "main", defaultBranch: "main",
                isFork: false)
        }
    }

    static func make(
        files: [String: String] = [:],
        before: @escaping @Sendable ([String]) async -> Void = { _ in }
    ) async throws -> PushTestRepo {
        let repo = try await GitTestRepo.make(files: files)
        try await repo.setup(["branch", "feat"], in: repo.source)
        let runner = RecordingGit(before: before)
        let git = RepoGit(
            path: "/usr/bin/git", environment: repo.env, layout: repo.layout,
            identity: GitTestRepo.identity, localRemotesForTestHome: true, runner: runner)
        return PushTestRepo(repo: repo, runner: runner, git: git)
    }

    func remove() { repo.folder.remove() }

    // The fix commit of the files, written in the worktree, on the head.
    func fix(_ files: [String: String]) async throws -> CommitID {
        for (path, text) in files { try repo.write(path, text, in: repo.worktree) }
        return try await FixCommit.make(
            paths: files.keys.sorted(), message: "fix: the review comments", head: head, pr: pr,
            git: git)
    }

    // A commit of another person on feat of the source, with the file. The result is the new
    // head of feat.
    @discardableResult
    func moveBranch(_ path: String, _ text: String) async throws -> CommitID {
        try await Self.moveBranch(path, text, source: repo.source, env: repo.env)
    }

    static func moveBranch(_ path: String, _ text: String, source: String, env: [String: String])
        async throws -> CommitID
    {
        try await git(["checkout", "-q", "feat"], in: source, env: env)
        let file = source + "/" + path
        try FileManager.default.createDirectory(
            atPath: (file as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try text.write(toFile: file, atomically: false, encoding: .utf8)
        try await git(["add", "-A"], in: source, env: env)
        try await git(["commit", "-q", "-m", "other"], in: source, env: env)
        try await git(["checkout", "-q", "main"], in: source, env: env)
        return try await branch(source: source, env: env)
    }

    // The head of feat in the source.
    func branch() async throws -> CommitID {
        try await Self.branch(source: repo.source, env: repo.env)
    }

    static func branch(source: String, env: [String: String]) async throws -> CommitID {
        try #require(CommitID(try await git(["rev-parse", "feat"], in: source, env: env)))
    }

    // Plain git in a folder, as a person would run it. The result is stdout with no white space
    // at its ends.
    @discardableResult
    func output(_ args: [String], in dir: String) async throws -> String {
        try await Self.git(args, in: dir, env: repo.env)
    }

    @discardableResult
    static func git(_ args: [String], in dir: String, env: [String: String]) async throws
        -> String
    {
        let identity = ["-c", "user.name=Other", "-c", "user.email=other@example.invalid"]
        let result = await ProcessRunner().run(
            Command(
                "/usr/bin/git", identity + ["-C", dir] + args, environment: env,
                timeout: .seconds(30)))
        try #require(result.succeeded, "git \(args.joined(separator: " ")): \(result.stderr)")
        return result.stdout.trimmed()
    }
}
