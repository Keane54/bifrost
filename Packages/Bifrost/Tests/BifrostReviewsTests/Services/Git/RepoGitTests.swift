// The git runner of Reviews (docs/behaviour/reviews.md, "Running git"). The first suite uses a
// recording runner to show the argv, the env, the folder and the limits of each run. The second
// suite runs the real git in GitTestRepo and shows that a session cannot change the repository of
// a command.
import BifrostFoundation
import BifrostTestSupport
import Foundation
import Testing

@testable import BifrostReviews

private let head = "f7698d38614ba22b41f996fab73124361d2fe389"

private func commit() throws -> CommitID { try #require(CommitID(head)) }
private func pr() throws -> PRKey { try #require(PRKey(text: "Owner-A/Repo-A#7")) }

// A layout in a temporary folder with the worktree of PR 7 and the admin folder that names it,
// with no real git. gitdir: the text of the gitdir file of the admin folder, or nil for none.
private struct FakeLayout {
    let folder: TemporaryFolder
    let layout: ReviewsLayout

    init(gitdir: (String) -> String? = { "\($0)/.git" }) throws {
        folder = try TemporaryFolder()
        layout = ReviewsLayout(
            folder: URL(filePath: folder.realPath + "/reviews", directoryHint: .isDirectory))
        let pr = try #require(PRKey(text: "Owner-A/Repo-A#7"))
        let fm = FileManager.default
        let worktree = GitPlace.worktree(pr, layout)
        let admin = GitPlace.adminFolder(pr, layout)
        try fm.createDirectory(atPath: worktree, withIntermediateDirectories: true)
        try fm.createDirectory(atPath: admin, withIntermediateDirectories: true)
        if let text = gitdir(worktree) {
            try "\(text)\n".write(toFile: admin + "/gitdir", atomically: false, encoding: .utf8)
        }
    }
}

private func git(_ runner: FakeRunner, layout: ReviewsLayout, environment: [String: String] = [:])
    -> RepoGit
{
    RepoGit(
        path: "/usr/bin/git", environment: environment, layout: layout,
        identity: CommitIdentity(name: "Test", email: "test@example.invalid"), runner: runner)
}

@Suite("the git runner of Reviews", .testTimeLimit)
struct RepoGitTests {
    @Test func eachCommandGetsTheSafeConfig() async throws {
        #expect(
            RepoGit.config == [
                "-c", "core.hooksPath=/dev/null", "-c", "core.fsmonitor=false", "-c",
                "core.quotePath=false", "-c", "credential.helper=", "-c",
                "credential.helper=!gh auth git-credential", "-c", "advice.detachedHead=false",
                "-c", "core.symlinks=false", "-c", "submodule.recurse=false",
            ])
        #expect(
            RepoGit.networkConfig == [
                "-c", "core.askPass=", "-c", "protocol.ssh.allow=never", "-c",
                "protocol.allow=never", "-c", "protocol.https.allow=always",
            ])
        let fake = try FakeLayout()
        defer { fake.folder.remove() }
        let layout = fake.layout
        let repo = try pr().repo
        let clone = layout.clone(repo).path(percentEncoded: false).dropLast()
        let worktree = GitPlace.worktree(try pr(), layout)
        let newClone = layout.reposRoot.appending(path: "new")
        let branch = try #require(BranchName("fix"))
        let pinned = ["--git-dir=\(clone)/.git/worktrees/7", "--work-tree=\(worktree)"]
        let runs: [(GitCommand, GitPlace, [String], String)] = [
            (.status, .worktree(try pr()), pinned, worktree),
            (.resetHard(try commit()), .worktree(try pr()), pinned, worktree),
            (.commit(message: "Fix"), .worktree(try pr()), pinned, worktree),
            (.push(GitPush(commit: try commit(), branch: branch)), .clone(repo),
             ["--git-dir=\(clone)/.git"], String(clone)),
            (.clone(try #require(URL(string: "https://github.com/o/r.git"))), .newClone(newClone),
             [], newClone.path(percentEncoded: false)),
            (.worktreeAdd(layout.worktree(repo, number: 8), try commit()), .clone(repo),
             ["--git-dir=\(clone)/.git"], String(clone)),
        ]
        let runner = FakeRunner(ExecResult(.exited(0)))
        for (command, place, _, _) in runs {
            _ = await git(runner, layout: layout).run(command, in: place)
        }
        // The commit first lists the index and the head of the worktree for a submodule
        // (RepoGit.holdsSubmodule), with the same items and pin.
        let listings = runner.commands.filter {
            $0.arguments.contains("ls-files") || $0.arguments.contains("ls-tree")
        }
        #expect(listings.map { Array($0.arguments.suffix(5)) } == [
            ["--literal-pathspecs", "ls-files", "--stage", "-z", "--"],
            ["ls-tree", "-r", "-z", "--full-tree", "HEAD"],
        ])
        #expect(listings.allSatisfy { $0.arguments.contains("--work-tree=\(worktree)") })
        let commands = runner.commands.filter { !listings.contains($0) }
        #expect(commands.count == runs.count)
        let identity = ["-c", "user.name=Test", "-c", "user.email=test@example.invalid"]
        for (run, (command, _, pin, folder)) in zip(commands, runs) {
            #expect(run.executable == "/usr/bin/git")
            // The test home items come first, so the safe items after them always win. Only the
            // pin that Bifrost computes and the fixed command come after the safe items.
            #expect(
                run.arguments
                    == identity + RepoGit.config + RepoGit.networkConfig + pin + command.arguments)
            #expect(run.directory == folder)
            #expect(run.outputLimit == 16 * 1_048_576)
            // A SIGTERM lets git remove its lock files, SIGKILL follows after 1 s, and a cancel
            // ends only when git ended.
            #expect(run.killSignal == .terminate)
            #expect(run.terminateGrace == RepoGit.stopGrace)
            #expect(run.waitsForEnd)
            #expect(run.input == nil)
        }
        // The clone and the checkout of a worktree download files, so they get the long limit.
        #expect(
            commands.map(\.timeout) == [
                .seconds(120), .seconds(120), .seconds(120), .seconds(120), .seconds(900),
                .seconds(900),
            ])
        #expect(RepoGit.timeout == .seconds(120) && RepoGit.cloneTimeout == .seconds(900))
    }

    @Test func aTestHomeCanAllowLocalRemotesAndNothingElse() throws {
        let layout = ReviewsLayout(folder: URL(filePath: "/nonexistent-bifrost-test/reviews"))
        let runner = FakeRunner(ExecResult(.exited(0)))
        let local = RepoGit(
            path: "git", environment: [:], layout: layout, localRemotesForTestHome: true,
            runner: runner)
        let args = local.arguments(for: .worktreePrune, in: .clone(try pr().repo))
        #expect(args.prefix(2) == ["-c", "protocol.file.allow=always"])
        #expect(Array(args.dropFirst(2).prefix(RepoGit.config.count)) == RepoGit.config)
        let app = RepoGit(path: "git", environment: [:], layout: layout, runner: runner)
        let appArgs = app.arguments(for: .worktreePrune, in: .clone(try pr().repo))
        #expect(!appArgs.contains { $0.hasPrefix("protocol.file") })
        #expect(appArgs.prefix(RepoGit.config.count) == RepoGit.config[...])
        // An identity is one closed value: no control or hidden character, no "<" or ">", no
        // white space at an end.
        let refused = [
            ("", "a@b"), ("a", ""), ("a\nb", "a@b"), ("a", "a@b\u{0}"), ("<a>", "a@b"),
            (" a", "a@b"), ("a\u{202E}", "a@b"), (String(repeating: "a", count: 201), "a@b"),
        ]
        for (name, email) in refused {
            #expect(CommitIdentity(name: name, email: email) == nil, "\(name.debugDescription)")
        }
        #expect(CommitIdentity(name: "Ann Example", email: "ann@example.invalid") != nil)
    }

    @Test func theEnvironmentKeepsOnlyTheTwoGitVariables() async throws {
        let fake = try FakeLayout()
        defer { fake.folder.remove() }
        let runner = FakeRunner(ExecResult(.exited(0)))
        let environment = [
            "PATH": "/opt/homebrew/bin:/usr/bin", "HOME": "/Users/someone",
            "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1", "GIT_DIR": "/elsewhere",
            "GIT_WORK_TREE": "/elsewhere", "GIT_INDEX_FILE": "/x", "GIT_SSH_COMMAND": "evil",
            "GIT_ASKPASS": "/x", "GIT_CONFIG_COUNT": "1", "GIT_CONFIG_KEY_0": "core.hooksPath",
            "GIT_CONFIG_PARAMETERS": "'core.hooksPath'='x'", "GIT_CONFIG": "/x",
            "GIT_OBJECT_DIRECTORY": "/x", "GIT_ALTERNATE_OBJECT_DIRECTORIES": "/x",
            "GIT_EXEC_PATH": "/x", "GIT_CEILING_DIRECTORIES": "/", "GIT_NAMESPACE": "x",
            "GIT_TRACE": "1", "GIT_TERMINAL_PROMPT": "1", "SSH_AUTH_SOCK": "/tmp/agent",
        ]
        _ = await git(runner, layout: fake.layout, environment: environment)
            .run(.status, in: .worktree(try pr()))
        #expect(
            runner.commands.first?.environment == [
                "PATH": "/opt/homebrew/bin:/usr/bin", "HOME": "/Users/someone",
                "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1",
                "SSH_AUTH_SOCK": "/tmp/agent", "GIT_TERMINAL_PROMPT": "0",
                "GIT_LFS_SKIP_SMUDGE": "1", "GCM_INTERACTIVE": "never",
            ])
    }

    // git add with no path adds each change of the worktree, a work tree command in the clone
    // folder could reach the worktrees and the input folders, and the clone command makes a
    // repository only in a new folder. A refused command never starts.
    @Test func aRefusedCommandRunsNoGit() async throws {
        let fake = try FakeLayout()
        defer { fake.folder.remove() }
        let runner = FakeRunner(ExecResult(.exited(0)))
        let git = git(runner, layout: fake.layout)
        let repo = try pr().repo
        let result = await git.run(.add([]), in: .worktree(try pr()))
        #expect(result.end == .notStarted)
        #expect(!result.stderr.isEmpty)
        _ = await git.run(.add([".claude/settings.json"]), in: .worktree(try pr()))
        _ = await git.run(.commitTree(tree: "-x", parents: [], message: "M"), in: .clone(repo))
        for command in [GitCommand.status, .clean, .resetHard(try commit()), .add(["a"])] {
            #expect(await git.run(command, in: .clone(repo)).end == .notStarted)
        }
        let url = try #require(URL(string: "https://github.com/o/r.git"))
        #expect(await git.run(.clone(url), in: .clone(repo)).end == .notStarted)
        #expect(await git.run(.clone(url), in: .worktree(try pr())).end == .notStarted)
        let newClone = GitPlace.newClone(fake.layout.reposRoot)
        #expect(await git.run(.status, in: newClone).end == .notStarted)
        #expect(await git.run(.revParse("HEAD"), in: newClone).end == .notStarted)
        #expect(runner.commands.isEmpty)
    }

    // A worktree whose index or head holds a submodule gets no add and no commit; a listing that
    // fails or does not read refuses too. The other commands still run.
    @Test func anAddOrACommitInARepositoryWithASubmoduleRunsNoGit() async throws {
        let fake = try FakeLayout()
        defer { fake.folder.remove() }
        let index = ExecResult(.exited(0), stdout: "100644 \(head) 0\ta.txt\0")
        let tree = ExecResult(.exited(0), stdout: "100644 blob \(head)\ta.txt\0")
        let linkInIndex = ExecResult(.exited(0), stdout: "160000 \(head) 0\tsub\0")
        let linkInTree = ExecResult(.exited(0), stdout: "160000 commit \(head)\tsub\0")
        let cases: [(String, ExecResult, ExecResult, Bool)] = [
            ("no submodule", index, tree, true), ("in the index", linkInIndex, tree, false),
            ("in the head", index, linkInTree, false),
            ("a failed listing", ExecResult(.exited(128), stderr: "fatal"), tree, false),
            ("an unread listing", ExecResult(.exited(0), stdout: "odd"), tree, false),
        ]
        for (name, listing, headTree, commits) in cases {
            let runner = FakeRunner { command in
                if command.arguments.contains("ls-files") { return listing }
                if command.arguments.contains("ls-tree") { return headTree }
                return ExecResult(.exited(0))
            }
            let git = git(runner, layout: fake.layout)
            let committed = await git.run(.commit(message: "Fix"), in: .worktree(try pr()))
            let added = await git.run(.add(["a.txt"]), in: .worktree(try pr()))
            #expect((committed.end == .exited(0)) == commits, "\(name)")
            #expect((added.end == .exited(0)) == commits, "\(name)")
            let writes = runner.commands.filter {
                $0.arguments.contains("commit") || $0.arguments.contains("add")
            }
            #expect(writes.count == (commits ? 2 : 0), "\(name)")
            if !commits { #expect(committed.stderr.contains("submodule"), "\(name)") }
            #expect(await git.run(.status, in: .worktree(try pr())).end == .exited(0), "\(name)")
        }
    }

    // The admin folder of the worktree in the clone must name the worktree of the PR, so a
    // worktree folder that git did not make for this clone runs no git.
    @Test func aWorktreeThatIsNotPartOfItsCloneRunsNoGit() async throws {
        let cases: [(String, (String) -> String?, Bool)] = [
            ("absolute", { "\($0)/.git" }, true),
            // git writes a path relative to the admin folder with worktree.useRelativePaths.
            ("relative", { _ in "../../../.bifrost-worktrees/7/.git" }, true),
            ("no file", { _ in nil }, false), ("empty", { _ in "" }, false),
            ("elsewhere", { _ in "/elsewhere/7/.git" }, false),
            ("not .git", { "\($0)/.git/x" }, false), ("another", { "\($0)/../8/.git" }, false),
        ]
        for (name, gitdir, runs) in cases {
            let fake = try FakeLayout(gitdir: gitdir)
            defer { fake.folder.remove() }
            let runner = FakeRunner(ExecResult(.exited(0)))
            let result = await git(runner, layout: fake.layout)
                .run(.status, in: .worktree(try pr()))
            #expect(runner.commands.count == (runs ? 1 : 0), "\(name)")
            #expect((result.end == .exited(0)) == runs, "\(name)")
        }
        // A missing admin folder runs no git either.
        let fake = try FakeLayout()
        defer { fake.folder.remove() }
        try FileManager.default.removeItem(atPath: GitPlace.adminFolder(try pr(), fake.layout))
        let runner = FakeRunner(ExecResult(.exited(0)))
        _ = await git(runner, layout: fake.layout).run(.status, in: .worktree(try pr()))
        #expect(runner.commands.isEmpty)
    }
}

// The real git: each command is pinned to the repository that Bifrost made, whatever the session
// writes in its worktree.
@Suite("the repository pin of the git runner", .testTimeLimit)
struct RepoGitPinTests {
    // A session rewrites the .git file of its worktree: it names a git folder of the session,
    // whose config sets core.worktree to a checkout of the user and a filter that runs a program.
    // status, reset and clean still act on the worktree of the PR, with the clone's own index.
    @Test func aRewrittenGitFileCannotChangeTheRepository() async throws {
        let repo = try await GitTestRepo.make()
        defer { repo.folder.remove() }
        let mine = repo.root + "/my-checkout"
        let marker = repo.root + "/the-filter-ran"
        try repo.write("keep.txt", "mine\n", in: mine)
        let evil = repo.worktree + "/x"
        try FileManager.default.createDirectory(atPath: evil, withIntermediateDirectories: true)
        try await repo.setup(["init", "-q"], in: evil)
        try await repo.setup(["config", "core.worktree", mine], in: evil)
        try await repo.setup(["config", "filter.evil.clean", "touch \(marker)"], in: evil)
        try await repo.setup(["config", "filter.evil.smudge", "touch \(marker)"], in: evil)
        try await repo.setup(["config", "filter.evil.required", "true"], in: evil)
        try repo.write(".gitattributes", "* filter=evil\n", in: repo.worktree)
        try repo.write(".git", "gitdir: \(evil)/.git\n", in: repo.worktree)
        try repo.write("a.txt", "changed\n", in: repo.worktree)
        try repo.write("new.txt", "new\n", in: repo.worktree)

        let status = await repo.git.run(.status, in: .worktree(repo.pr))
        #expect(status.succeeded, "\(status.stderr)")
        let entries = Set(status.stdout.split(separator: "\0").map(String.init))
        #expect(entries.contains(" M a.txt"))
        #expect(entries.contains("?? new.txt"))
        #expect(!status.stdout.contains("keep.txt"))

        #expect(await repo.git.run(.resetHard(repo.head), in: .worktree(repo.pr)).succeeded)
        #expect(await repo.git.run(.clean, in: .worktree(repo.pr)).succeeded)
        let text = try String(contentsOfFile: repo.worktree + "/a.txt", encoding: .utf8)
        #expect(text == "one\n")
        #expect(!repo.exists(repo.worktree + "/new.txt"))
        #expect(!repo.exists(repo.worktree + "/.gitattributes"))
        // The checkout of the user is as it was, and no filter ran.
        #expect(try String(contentsOfFile: mine + "/keep.txt", encoding: .utf8) == "mine\n")
        #expect(!repo.exists(marker))
    }

    // With no .git file, git would search the folders above and find the clone, whose work tree
    // holds the worktrees and the input folders. The pin keeps each command in the worktree.
    @Test func aMissingGitFileDoesNotSearchTheFoldersAbove() async throws {
        let repo = try await GitTestRepo.make()
        defer { repo.folder.remove() }
        try FileManager.default.removeItem(atPath: repo.worktree + "/.git")
        try repo.write("new.txt", "new\n", in: repo.worktree)
        let input = repo.layout.inputFolder(repo.pr.repo, number: 7).path(percentEncoded: false)
        try repo.write("input.json", "{}", in: input)

        let status = await repo.git.run(.status, in: .worktree(repo.pr))
        #expect(status.succeeded, "\(status.stderr)")
        #expect(status.stdout == "?? new.txt\0")
        #expect(await repo.git.run(.clean, in: .worktree(repo.pr)).succeeded)
        #expect(!repo.exists(repo.worktree + "/new.txt"))
        #expect(repo.exists(input + "/input.json"))
        #expect(repo.exists(repo.worktree + "/a.txt"))
    }

    // The head of the PR has a submodule, and the session makes its folder a repository whose
    // own config has a filter that runs a program, with a changed file. A git status that looks
    // into the submodule, or a commit with nothing staged, would run the program. Bifrost's
    // commands ignore the submodule or never run, and the file check refuses the commit.
    @Test func aSubmoduleFolderCannotRunAProgram() async throws {
        let repo = try await GitTestRepo.make(gitlink: "sub")
        defer { repo.folder.remove() }
        let sub = repo.worktree + "/sub"
        let marker = repo.root + "/the-filter-ran"
        try await repo.setup(["init", "-q"], in: sub)
        try repo.write("f", "x\n", in: sub)
        try await repo.setup(["add", "f"], in: sub)
        try await repo.setup(["commit", "-q", "-m", "s"], in: sub)
        try await repo.setup(["config", "filter.evil.clean", "touch \(marker); cat"], in: sub)
        try repo.write(".gitattributes", "* filter=evil\n", in: sub)
        // A change of the same size with a new time: git must read the file, through the filter.
        try repo.write("f", "y\n", in: sub)
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(10)], ofItemAtPath: sub + "/f")
        let place = GitPlace.worktree(repo.pr)

        let status = await repo.git.run(.status, in: place)
        #expect(status.succeeded, "\(status.stderr)")
        #expect(!repo.exists(marker))
        let committed = await repo.git.run(.commit(message: "Fix"), in: place)
        #expect(committed.end == .notStarted)
        #expect(await repo.git.run(.add(["a.txt"]), in: place).end == .notStarted)
        #expect(await repo.git.run(.diff(repo.head, repo.head), in: .clone(repo.pr.repo)).succeeded)
        #expect(await repo.git.holdsSubmodule(repo.pr) == true)
        let refusal = await CommitFileCheck.check(["a.txt"], in: repo.pr, git: repo.git)
        #expect(refusal == .repositoryWithSubmodule)
        #expect(!repo.exists(marker))

        // The guard is what stops it: a plain git status with the same pin runs the program.
        try await repo.setup(
            [
                "--git-dir=\(GitPlace.adminFolder(repo.pr, repo.layout))",
                "--work-tree=\(repo.worktree)", "status", "--porcelain",
            ], in: repo.worktree)
        #expect(repo.exists(marker))
        try FileManager.default.removeItem(atPath: marker)
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(20)], ofItemAtPath: sub + "/f")

        // The reset and the clean of a round do not go into the submodule either.
        #expect(await repo.git.run(.resetHard(repo.head), in: place).succeeded)
        #expect(await repo.git.run(.clean, in: place).succeeded)
        #expect(await repo.git.run(.status, in: place).succeeded)
        #expect(!repo.exists(marker))
    }

    // Only https reaches a remote; a local folder needs the item of a test home.
    @Test func aLocalRemoteNeedsTheTestHomeItem() async throws {
        let repo = try await GitTestRepo.make()
        defer { repo.folder.remove() }
        let app = RepoGit(
            path: "/usr/bin/git", environment: repo.env, layout: repo.layout,
            runner: ProcessRunner())
        let folder = repo.layout.reposRoot.appending(path: "other")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let result = await app.run(.clone(URL(filePath: repo.source)), in: .newClone(folder))
        #expect(!result.succeeded)
        #expect(result.stderr.contains("not allowed"), "\(result.stderr)")
    }
}
