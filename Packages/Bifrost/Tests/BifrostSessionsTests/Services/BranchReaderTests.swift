import BifrostTestSupport
import Foundation
import Testing

@testable import BifrostFoundation
@testable import BifrostSessions

// The branch reader on a memory file system, on the real file system in a temp folder, and the
// commands of the registry system dependencies. docs/behaviour/registry.md has the rules.

private func gitArgs(_ cwd: String) -> [String] {
    ["-C", cwd, "rev-parse", "--abbrev-ref", "HEAD"]
}
private func fromGit() -> FakeRunner { FakeRunner(ExecResult(.exited(0), stdout: "from-git\n")) }

// A folder whose .git file holds no gitdir, so the branch reader asks git.
private func strangeRepo(_ cwd: String) -> MemoryFileSystem {
    MemoryFileSystem(files: ["\(cwd)/.git": "nonsense\n"], folders: [cwd])
}

@Suite("the branch of a folder", .testTimeLimit)
struct GitBranchTests {
    @Test("the branch of git is trimmed or missing")
    func trims() async {
        let runner = FakeRunner(ExecResult(.exited(0), stdout: "main\n"))
        let reader = BranchReader(runner: runner, fileSystem: strangeRepo("/p"))
        #expect(await reader.read("/p") == "main")
        #expect(
            runner.calls == [
                FakeRunner.Call(file: "git", args: gitArgs("/p"), timeout: .seconds(2))
            ])
        let failed = FakeRunner(ExecResult(.exited(128), stderr: "fatal"))
        #expect(await BranchReader(runner: failed, fileSystem: strangeRepo("/p")).read("/p") == nil)
    }

    // git runs with the env of the claude runs (the login env), so it is the git of the login
    // PATH.
    @Test func gitGetsTheLoginEnv() async {
        let runner = FakeRunner(ExecResult(.exited(0), stdout: "main\n"))
        let env = ["PATH": "/login/bin:/usr/bin"]
        let reader = BranchReader(runner: runner, fileSystem: strangeRepo("/p"), environment: env)
        #expect(await reader.read("/p") == "main")
        #expect(runner.commands.first?.environment == env)
    }

    // A relative folder has no branch: no file read and no git.
    @Test func aRelativeFolderHasNoBranch() async {
        let runner = FakeRunner(ExecResult(.exited(0), stdout: "main\n"))
        let fs = strangeRepo("p")
        #expect(await BranchReader(runner: runner, fileSystem: fs).read("p") == nil)
        #expect(runner.calls.isEmpty)
        #expect(fs.reads.isEmpty)
    }

    @Test("no git runs in the reviews folder where a PR session can write")
    func skipsReviews() async {
        let runner = FakeRunner(ExecResult(.exited(0), stdout: "main\n"))
        let root = "/h/.bifrost/reviews/repos"
        let folders = [root, "\(root)/acme/api", "\(root)/acme/api/.bifrost-worktrees/9"]
        for cwd in folders {
            let reader = BranchReader(
                runner: runner, fileSystem: strangeRepo(cwd), skipRoots: [root])
            #expect(await reader.read(cwd) == nil)
        }
        #expect(runner.calls.isEmpty)
        // A folder next to the reviews folder is a normal folder.
        for cwd in ["/h/.bifrost/reviews/repos-old", "/p"] {
            let reader = BranchReader(
                runner: runner, fileSystem: strangeRepo(cwd), skipRoots: [root])
            #expect(await reader.read(cwd) == "main")
        }
        #expect(runner.calls.count == 2)
    }

    // The check also compares the real paths, through the file system of the reader: the
    // session reports the real path, and the settings give the path through a link, or the
    // other way round.
    @Test("the check of the reviews folder also compares the real paths")
    func realPathsThroughTheFileSystem() async {
        let runner = FakeRunner(ExecResult(.exited(0), stdout: "main\n"))
        let root = "/real/repos"
        let fs = MemoryFileSystem(
            files: ["\(root)/acme/api/.git": "nonsense\n"], folders: ["\(root)/acme/api"],
            links: ["/link": root])
        let viaLink = BranchReader(runner: runner, fileSystem: fs, skipRoots: ["/link"])
        #expect(await viaLink.read("\(root)/acme/api") == nil)
        let viaReal = BranchReader(runner: runner, fileSystem: fs, skipRoots: [root])
        #expect(await viaReal.read("/link/acme/api") == nil)
        #expect(runner.calls.isEmpty)
    }

    // A .git file outside the reviews folder can point into it through a link. The reader then
    // reads no HEAD file there and runs no git.
    @Test func aGitFileThatPointsIntoTheReviewsFolderThroughALinkReadsNothing() async {
        let runner = FakeRunner(ExecResult(.exited(0), stdout: "main\n"))
        let root = "/real/repos"
        let fs = MemoryFileSystem(
            files: [
                "/w/.git": "gitdir: /link/acme/.git/worktrees/w\n",
                "\(root)/acme/.git/worktrees/w/HEAD": "ref: refs/heads/pr\n",
            ], folders: ["/w"], links: ["/link": root])
        let reader = BranchReader(runner: runner, fileSystem: fs, skipRoots: [root])
        #expect(await reader.read("/w") == nil)
        #expect(runner.calls.isEmpty)
        #expect(!fs.reads.contains("\(root)/acme/.git/worktrees/w/HEAD"))
    }

    // The real file system follows links: the reviews folder through a real link, and a .git
    // link to a folder.
    @Test("the real file system follows the links")
    func realLinks() async throws {
        let made = try TemporaryFolder()
        defer { made.remove() }
        let fs = LocalBranchFileSystem()
        let dir = try #require(await fs.realPath(made.path))
        let root = "\(dir)/repos"
        try FileManager.default.createDirectory(
            atPath: "\(root)/acme/api", withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: "\(dir)/link", withDestinationPath: root)
        let runner = FakeRunner(ExecResult(.exited(0), stdout: "main\n"))
        let viaLink = BranchReader(runner: runner, skipRoots: ["\(dir)/link"])
        #expect(await viaLink.read("\(root)/acme/api") == nil)
        let viaReal = BranchReader(runner: runner, skipRoots: [root])
        #expect(await viaReal.read("\(dir)/link/acme/api") == nil)
        #expect(runner.calls.isEmpty)
        // A repo whose .git is a link to a folder: its own branch, not the branch of a parent.
        let repo = "\(dir)/repo"
        try FileManager.default.createDirectory(
            atPath: "\(dir)/store/.git", withIntermediateDirectories: true)
        try "ref: refs/heads/linked\n".write(
            toFile: "\(dir)/store/.git/HEAD", atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(atPath: repo, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            atPath: "\(repo)/.git", withDestinationPath: "\(dir)/store/.git")
        #expect(await BranchReader(runner: runner).read(repo) == "linked")
        #expect(runner.calls.isEmpty)
    }
}

@Suite("branch reader", .testTimeLimit)
struct BranchReaderTests {
    @Test("a missing folder gives no branch and the walk does not go up to a parent repo")
    func missingFolder() async {
        let fs = MemoryFileSystem(
            files: ["/r/.git/HEAD": "ref: refs/heads/main\n"], folders: ["/r/.git"])
        let reader = BranchReader(
            runner: FakeRunner(ExecResult(.exited(128), stderr: "fatal")), fileSystem: fs)
        #expect(await reader.read("/r/.claude/worktrees/fix-a") == nil)
    }

    @Test
    func repoAndSubfolder() async {
        let fs = MemoryFileSystem(
            files: ["/r/.git/HEAD": "ref: refs/heads/main\n"], folders: ["/r/.git", "/r/a/b"])
        let runner = fromGit()
        let reader = BranchReader(runner: runner, fileSystem: fs)
        #expect(await reader.read("/r") == "main")
        #expect(await reader.read("/r/a/b") == "main")
        #expect(runner.calls.isEmpty)
    }

    @Test("a worktree with a relative gitdir is read")
    func relativeGitdir() async {
        let fs = MemoryFileSystem(
            files: [
                "/r/.git/worktrees/w/HEAD": "ref: refs/heads/wt\n",
                "/w/.git": "gitdir: ../r/.git/worktrees/w\n",
            ],
            folders: ["/w/sub"])
        let runner = fromGit()
        let reader = BranchReader(runner: runner, fileSystem: fs)
        #expect(await reader.read("/w") == "wt")
        #expect(await reader.read("/w/sub") == "wt")
        #expect(runner.calls.isEmpty)
    }

    @Test("a worktree with an absolute gitdir is read")
    func absoluteGitdir() async {
        let fs = MemoryFileSystem(
            files: [
                "/r/.git/worktrees/w/HEAD": "ref: refs/heads/a",
                "/w/.git": "gitdir: /r/.git/worktrees/w\n",
            ],
            folders: [])
        #expect(await BranchReader(runner: fromGit(), fileSystem: fs).read("/w") == "a")
    }

    @Test
    func cacheByMtime() async {
        let fs = MemoryFileSystem(
            files: ["/r/.git/HEAD": "ref: refs/heads/one\n"], folders: ["/r/.git"],
            mtimes: ["/r/.git/HEAD": 10])
        let reader = BranchReader(runner: fromGit(), fileSystem: fs)
        #expect(await reader.read("/r") == "one")
        #expect(await reader.read("/r") == "one")
        #expect(fs.reads == ["/r/.git/HEAD"])
        fs.set("/r/.git/HEAD", text: "ref: refs/heads/two\n", mtime: 20)
        #expect(await reader.read("/r") == "two")
        #expect(fs.reads.count == 2)
    }

    @Test("a detached head shows HEAD")
    func detached() async {
        let fs = MemoryFileSystem(
            files: ["/r/.git/HEAD": String(repeating: "c", count: 40) + "\n"], folders: ["/r/.git"])
        let runner = fromGit()
        #expect(await BranchReader(runner: runner, fileSystem: fs).read("/r") == "HEAD")
        #expect(runner.calls.isEmpty)
    }

    @Test("a branch with no commit yet shows its name")
    func unborn() async {
        let fs = MemoryFileSystem(
            files: ["/r/.git/HEAD": "ref: refs/heads/unborn\n"], folders: ["/r/.git"])
        #expect(await BranchReader(runner: fromGit(), fileSystem: fs).read("/r") == "unborn")
    }

    @Test("a branch named like a tag shows its plain name")
    func tagLike() async {
        let fs = MemoryFileSystem(
            files: ["/r/.git/HEAD": "ref: refs/heads/v1\n"], folders: ["/r/.git"])
        #expect(await BranchReader(runner: fromGit(), fileSystem: fs).read("/r") == "v1")
    }

    @Test("git reads a HEAD that the reader cannot read")
    func unreadable() async {
        let fs = MemoryFileSystem(
            files: ["/r/.git/HEAD": "ref: refs/remotes/x\n"], folders: ["/r/.git"])
        let runner = fromGit()
        #expect(await BranchReader(runner: runner, fileSystem: fs).read("/r") == "from-git")
        #expect(
            runner.calls == [
                FakeRunner.Call(file: "git", args: gitArgs("/r"), timeout: .seconds(2))
            ])
    }

    @Test
    func noGitdirAndMissingHead() async {
        let runner = fromGit()
        let a = MemoryFileSystem(files: ["/r/.git": "nonsense\n"], folders: [])
        #expect(await BranchReader(runner: runner, fileSystem: a).read("/r") == "from-git")
        let b = MemoryFileSystem(files: [:], folders: ["/r/.git"])
        #expect(await BranchReader(runner: runner, fileSystem: b).read("/r") == "from-git")
        #expect(runner.calls.count == 2)
    }

    @Test("no .git up to the root gives no branch and calls no git")
    func noGit() async {
        let fs = MemoryFileSystem(files: [:], folders: ["/a/b"])
        let runner = fromGit()
        #expect(await BranchReader(runner: runner, fileSystem: fs).read("/a/b") == nil)
        #expect(runner.calls.isEmpty)
    }

    @Test
    func skipsReviewsFolder() async {
        let root = "/h/.bifrost/reviews/repos"
        let fs = MemoryFileSystem(
            files: [
                "\(root)/acme/api/.git/HEAD": "ref: refs/heads/fix\n",
                "/p/.git/HEAD": "ref: refs/heads/main\n",
            ],
            folders: ["\(root)/acme/api/.git", "\(root)/acme/api/.bifrost-worktrees/9", "/p/.git"])
        let runner = fromGit()
        let reader = BranchReader(runner: runner, fileSystem: fs, skipRoots: [root])
        for cwd in [root, "\(root)/acme/api", "\(root)/acme/api/.bifrost-worktrees/9"] {
            #expect(await reader.read(cwd) == nil)
        }
        #expect(fs.reads.isEmpty)
        #expect(runner.calls.isEmpty)
        // A folder outside the reviews folder is a normal folder.
        #expect(await reader.read("/p") == "main")
    }

    @Test
    func skipsThroughGitFile() async {
        let root = "/h/.bifrost/reviews/repos"
        let fs = MemoryFileSystem(
            files: [
                "\(root)/acme/api/.git/worktrees/w/HEAD": "ref: refs/heads/fix\n",
                "/elsewhere/.git": "gitdir: \(root)/acme/api/.git/worktrees/w\n",
            ],
            folders: ["/elsewhere"])
        let runner = fromGit()
        let reader = BranchReader(runner: runner, fileSystem: fs, skipRoots: [root])
        #expect(await reader.read("/elsewhere") == nil)
        #expect(fs.reads == ["/elsewhere/.git"])
        #expect(runner.calls.isEmpty)
    }

    @Test("the branch reader reads a real repo folder with no git process")
    func realRepo() async throws {
        let temp = try TemporaryFolder()
        defer { temp.remove() }
        let dir = temp.url
        try FileManager.default.createDirectory(
            at: dir.appendingPathComponent(".git"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: dir.appendingPathComponent("src"), withIntermediateDirectories: true)
        try "ref: refs/heads/main\n".write(
            to: dir.appendingPathComponent(".git/HEAD"), atomically: true, encoding: .utf8)
        let runner = fromGit()
        let reader = BranchReader(runner: runner)
        #expect(await reader.read(dir.appendingPathComponent("src").path) == "main")
        #expect(runner.calls.isEmpty)
    }
}

// A claude process (63362) in a shell of Warp.
private let warpTable: ProcessTable = [
    63362: ProcessEntry(ppid: 931, comm: "claude"),
    931: ProcessEntry(ppid: 866, comm: "-zsh"),
    866: ProcessEntry(ppid: 1, comm: "/Applications/Warp.app/Contents/MacOS/stable"),
]

// The commands that the dependencies of the app run.

@Suite("registry system dependencies", .testTimeLimit)
struct SystemDepsTests {
    // "claude agents --json" has the default time limit of the claude runner.
    @Test("the agents list uses a 10 s timeout")
    func agentsTimeout() async throws {
        let runner = FakeRunner(ExecResult(.exited(0), stdout: "[]\n"))
        let claude = ClaudeRunner(path: "/fake/claude", baseEnvironment: [:], runner: runner)
        let deps = RegistrySystemDeps(
            claude: claude, runner: runner, skipRoots: [], saver: .noFile)
        _ = try await deps.listActive()
        _ = try await deps.listAll()
        let active = ["agents", "--json"]
        let all = ["agents", "--json", "--all"]
        #expect(
            runner.calls == [
                FakeRunner.Call(file: "/fake/claude", args: active, timeout: .seconds(10)),
                FakeRunner.Call(file: "/fake/claude", args: all, timeout: .seconds(10)),
            ])
    }

    // The app reads the processes natively. The dependencies of the app give the terminal apps
    // of the process inspector, with one read and no program.
    @Test("the terminal apps come from the inspector and start no program")
    func readsTerminalApps() async {
        let runner = FakeRunner(ExecResult(.exited(0), stdout: ""))
        let inspector = FakeProcessInspector(table: warpTable)
        let deps = RegistrySystemDeps(
            claude: nil, runner: runner, skipRoots: [], saver: .noFile, processes: inspector)
        let warpApp = TerminalApp(name: "Warp", bundle: "/Applications/Warp.app")
        let expected = TerminalApps(apps: [63362: warpApp], noApp: [5])
        #expect(await deps.readTerminalApps([63362, 5]) == expected)
        #expect(inspector.calls == [.terminalApps([63362, 5])])
        #expect(runner.calls.isEmpty)
    }
}
