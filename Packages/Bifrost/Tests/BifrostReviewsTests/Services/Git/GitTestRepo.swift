import BifrostFoundation
import BifrostTestSupport
import Foundation
import Testing

@testable import BifrostReviews

// A source repository, Bifrost's clone of it and the worktree of PR 7, in the layout of Reviews,
// made with the real git in a new temporary folder. RepoGit makes the clone and the worktree, as
// the app does. HOME is the temporary folder, and git reads no config of the user and no config
// of the system. The source is a local folder, so RepoGit allows local remotes.
struct GitTestRepo {
    static let identity = CommitIdentity(name: "Test", email: "test@example.invalid")

    let folder: TemporaryFolder
    // The real path of the temporary folder.
    let root: String
    let layout: ReviewsLayout
    let pr: PRKey
    let env: [String: String]
    let git: RepoGit
    // The commit of the source, and the head of the worktree.
    let head: CommitID

    var source: String { root + "/source" }
    var clone: String { layout.clone(pr.repo).path(percentEncoded: false) }
    var worktree: String { GitPlace.worktree(pr, layout) }

    // files: more files of the first commit of the source, by path, besides a.txt. gitlink: the
    // path of a submodule entry (mode 160000) of that commit, with its .gitmodules, or nil.
    static func make(files: [String: String] = [:], gitlink: String? = nil) async throws
        -> GitTestRepo
    {
        let folder = try TemporaryFolder()
        do {
            return try await make(in: folder, files: files, gitlink: gitlink)
        } catch {
            folder.remove()
            throw error
        }
    }

    private static func make(
        in folder: TemporaryFolder, files: [String: String], gitlink: String?
    ) async throws -> GitTestRepo {
        let root = folder.realPath
        let env = [
            "PATH": "/usr/bin:/bin", "HOME": root, "GIT_CONFIG_NOSYSTEM": "1",
            "GIT_CONFIG_GLOBAL": "/dev/null",
        ]
        let layout = ReviewsLayout(
            folder: URL(filePath: root + "/reviews", directoryHint: .isDirectory))
        let pr = try #require(PRKey(text: "Owner-A/Repo-A#7"))
        let git = RepoGit(
            path: testGit, environment: env, layout: layout, identity: identity,
            localRemotesForTestHome: true, runner: ProcessRunner())
        let source = root + "/source"
        let fm = FileManager.default
        try fm.createDirectory(atPath: source, withIntermediateDirectories: true)
        try await setup(["init", "-q"], in: source, env: env)
        var all = files.merging(["a.txt": "one\n"], uniquingKeysWith: { $1 })
        if let gitlink {
            // ignore = none: the .gitmodules of a PR can choose this value for its submodule.
            all[".gitmodules"] =
                "[submodule \"\(gitlink)\"]\n\tpath = \(gitlink)\n"
                + "\turl = https://example.invalid/sub.git\n\tignore = none\n"
        }
        for (path, text) in all {
            let file = source + "/" + path
            try fm.createDirectory(
                atPath: (file as NSString).deletingLastPathComponent,
                withIntermediateDirectories: true)
            try text.write(toFile: file, atomically: false, encoding: .utf8)
        }
        try await setup(["add", "-A"], in: source, env: env)
        if let gitlink {
            let commit = String(repeating: "1", count: 40)
            try await setup(
                ["update-index", "--add", "--cacheinfo", "160000,\(commit),\(gitlink)"],
                in: source, env: env)
        }
        try await setup(["commit", "-q", "-m", "one"], in: source, env: env)

        let clone = layout.clone(pr.repo)
        try fm.createDirectory(at: clone, withIntermediateDirectories: true)
        let cloned = await git.run(.clone(URL(filePath: source)), in: .newClone(clone))
        try #require(cloned.succeeded, "clone: \(cloned.stderr)")
        let parsed = await git.run(.revParse("HEAD^{commit}"), in: .clone(pr.repo))
        let head = try #require(CommitID(parsed.stdout.trimmed()), "rev-parse: \(parsed.stderr)")
        let added = await git.run(
            .worktreeAdd(layout.worktree(pr.repo, number: pr.number), head), in: .clone(pr.repo))
        try #require(added.succeeded, "worktree add: \(added.stderr)")
        return GitTestRepo(
            folder: folder, root: root, layout: layout, pr: pr, env: env, git: git, head: head)
    }

    // A git command for the set-up of a test, with the env and the identity of the tests. It
    // runs plain git, not RepoGit, as a session or the user would.
    func setup(_ args: [String], in dir: String) async throws {
        try await Self.setup(args, in: dir, env: env)
    }

    private static func setup(_ args: [String], in dir: String, env: [String: String])
        async throws
    {
        let identity = [
            "-c", "user.name=Test", "-c", "user.email=test@example.invalid", "-c",
            "init.defaultBranch=main",
        ]
        let result = await ProcessRunner().run(
            Command(
                testGit, identity + ["-C", dir] + args, environment: env,
                timeout: .seconds(30)))
        try #require(result.succeeded, "git \(args.joined(separator: " ")): \(result.stderr)")
    }

    // Write a text file below a folder, with the folders above it.
    func write(_ path: String, _ text: String, in dir: String) throws {
        let file = dir + "/" + path
        try FileManager.default.createDirectory(
            atPath: (file as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try text.write(toFile: file, atomically: false, encoding: .utf8)
    }

    func exists(_ path: String) -> Bool { FileManager.default.fileExists(atPath: path) }
}
