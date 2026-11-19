// The file system and index checks of a fix commit (docs/behaviour/reviews.md, "What a fix commit
// can hold"). Each test runs the real git, only in the clone and the worktree that GitTestRepo
// makes in a temporary folder.
import BifrostFoundation
import BifrostTestSupport
import Foundation
import Testing

@testable import BifrostReviews

extension GitTestRepo {
    fileprivate func check(_ paths: [String]) async -> CommitFileRefusal? {
        await CommitFileCheck.check(paths, in: pr, git: git)
    }

    fileprivate func write(_ path: String, _ text: String) throws {
        try write(path, text, in: worktree)
    }
}

@Suite("the file checks of a fix commit", .testTimeLimit)
struct CommitFileCheckTests {
    @Test func aLinkAHardLinkOrASubmoduleIsRefused() async throws {
        let repo = try await GitTestRepo.make()
        defer { repo.folder.remove() }
        let fm = FileManager.default
        let tree = repo.worktree
        try fm.createSymbolicLink(atPath: tree + "/link", withDestinationPath: "a.txt")
        try fm.createSymbolicLink(atPath: tree + "/out", withDestinationPath: "/etc")
        try fm.linkItem(atPath: tree + "/a.txt", toPath: tree + "/hard.txt")
        try repo.write("real/b.txt", "b\n")
        try fm.createSymbolicLink(atPath: tree + "/dir", withDestinationPath: "real")
        #expect(await repo.check(["link"]) == .link)
        #expect(await repo.check(["out/hosts"]) == .link)
        #expect(await repo.check(["dir/b.txt"]) == .link)
        #expect(await repo.check(["real"]) == .link)
        #expect(await repo.check(["hard.txt"]) == .hardLink)
        #expect(await repo.check(["a.txt"]) == .hardLink)

        // A link that the head holds is a plain file in the worktree (core.symlinks=false).
        let hashed = await repo.git.run(.hashObject("real/b.txt"), in: .worktree(repo.pr))
        let blob = try #require(CommitID(hashed.stdout.trimmed()), "\(hashed.stderr)")
        try await repo.setup(
            ["update-index", "--add", "--cacheinfo", "120000,\(blob.hex),was-link"], in: tree)
        try repo.write("was-link", "real/b.txt")
        #expect(await repo.check(["was-link"]) == .link)

        // A submodule in the index: no file of the worktree can go in a commit any more.
        let other = String(repeating: "b", count: 40)
        try await repo.setup(
            ["update-index", "--add", "--cacheinfo", "160000,\(other),sub"], in: tree)
        try fm.createDirectory(atPath: tree + "/sub", withIntermediateDirectories: true)
        #expect(await repo.check(["sub"]) == .repositoryWithSubmodule)
        #expect(await repo.check(["real/b.txt"]) == .repositoryWithSubmodule)
    }

    // A submodule in the head of the PR: the commit is refused before any file check.
    @Test func aRepositoryWithASubmoduleGetsNoCommit() async throws {
        let repo = try await GitTestRepo.make(gitlink: "sub")
        defer { repo.folder.remove() }
        try repo.write("a.txt", "changed\n")
        #expect(await repo.check(["a.txt"]) == .repositoryWithSubmodule)
        #expect(await repo.check([]) == nil)
    }

    @Test func aFileOver1MiBIsRefused() async throws {
        let repo = try await GitTestRepo.make()
        defer { repo.folder.remove() }
        try repo.write("exact.bin", String(repeating: "x", count: CommitFileRule.maxFileBytes))
        try repo.write("big.bin", String(repeating: "x", count: CommitFileRule.maxFileBytes + 1))
        #expect(await repo.check(["exact.bin"]) == nil)
        #expect(await repo.check(["exact.bin", "big.bin"]) == .tooLarge)
    }

    @Test func aFileWithAFilterAttributeIsRefused() async throws {
        let repo = try await GitTestRepo.make()
        defer { repo.folder.remove() }
        try repo.write(".gitattributes", "*.lfs filter=lfs\n*.off -filter\n")
        try repo.write("data.lfs", "x\n")
        try repo.write("data.off", "x\n")
        #expect(await repo.check(["data.lfs"]) == .filter)
        #expect(await repo.check(["data.off", "a.txt"]) == nil)
        #expect(await repo.check(["a.txt", "data.lfs"]) == .filter)
    }

    @Test func aPlainFileIsAccepted() async throws {
        let repo = try await GitTestRepo.make()
        defer { repo.folder.remove() }
        try repo.write("src/new file.swift", "let a = 1\n")
        try FileManager.default.removeItem(atPath: repo.worktree + "/a.txt")
        try repo.write("b.txt", "b\n")
        // A delete of a tracked file, a new file in a new folder and a name with a space.
        #expect(await repo.check(["a.txt", "src/new file.swift", "b.txt"]) == nil)
        #expect(await repo.check([]) == nil)
    }

    // A path that names a folder would let git add -A add or delete each file below it, also a
    // workflow or a .claude file. A path that is gone must be one entry of the index.
    @Test func aGoneFolderOrAPathThatIsNoEntryIsRefused() async throws {
        let repo = try await GitTestRepo.make(files: [
            ".github/workflows/ci.yml": "on: push\n", "src/.claude/settings.json": "{}\n",
            "src/b.txt": "b\n",
        ])
        defer { repo.folder.remove() }
        let fm = FileManager.default
        try fm.removeItem(atPath: repo.worktree + "/.github")
        try fm.removeItem(atPath: repo.worktree + "/src")
        #expect(await repo.check([".github"]) == .link)
        #expect(await repo.check(["src"]) == .link)
        #expect(await repo.check([".github", "src"]) == .link)
        #expect(await repo.check(["a.txt", "src"]) == .link)
        #expect(await repo.check(["never-there.txt"]) == .unchanged)
        // The delete of one file is one entry of the index.
        #expect(await repo.check(["src/b.txt"]) == nil)
    }

    // The path rule runs before git, so a refused path runs no git.
    @Test func thePathRuleComesFirst() async throws {
        let repo = try await GitTestRepo.make()
        defer { repo.folder.remove() }
        let runner = FakeRunner(ExecResult(.exited(0)))
        let git = RepoGit(path: "git", environment: [:], layout: repo.layout, runner: runner)
        let paths = ["ok.txt", ".github/workflows/ci.yml"]
        #expect(await CommitFileCheck.check(paths, in: repo.pr, git: git) == .workflow)
        #expect(runner.commands.isEmpty)
    }

    // A git that fails gives no answer, so the check refuses.
    @Test func aFailedGitRefusesTheFiles() async throws {
        let repo = try await GitTestRepo.make()
        defer { repo.folder.remove() }
        let runner = FakeRunner(ExecResult(.exited(128), stderr: "fatal"))
        let git = RepoGit(path: "git", environment: [:], layout: repo.layout, runner: runner)
        #expect(await CommitFileCheck.check(["a.txt"], in: repo.pr, git: git) == .unchecked)
        #expect(runner.commands.count == 1)
    }
}
