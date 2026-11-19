// The repo store of Reviews (docs/behaviour/reviews.md, "Clones and trust") with the real git.
// The source of each clone is a local bare repository in a temporary folder, through the clone
// address that the test gives. The app gives only GitHub addresses. HOME is the temporary folder,
// and git reads no config of the user and no config of the system.
import BifrostFoundation
import BifrostTestSupport
import Foundation
import Synchronization
import Testing

@testable import BifrostReviews

// A Reviews folder in a temporary folder, a bare source repository for each repository name, the
// git runner and the store.
@MainActor
struct RepoFixture {
    let folder: TemporaryFolder
    let root: String
    let layout: ReviewsLayout
    let env: [String: String]
    let git: RepoGit
    let clock = ManualClock()
    let log = Recorder<ReviewsLogEvent>()
    let store: RepoStore
    // The git that holds each clone, for a test of a stop during a clone, or nil. Its runner
    // runs the grace of a stop on gitClock.
    let holding: HoldingGit?
    let gitClock: ManualClock?
    let address: @Sendable (RepoName) -> URL

    // runner: the runner of git, for a test that counts the runs. holding: git holds each clone
    // until the SIGKILL of a stop (HoldingGit), with a runner on a manual clock.
    init(runner: any CommandRunner = ProcessRunner(), holding: Bool = false) throws {
        folder = try TemporaryFolder()
        self.holding = holding ? try HoldingGit(in: folder) : nil
        let gitClock = holding ? ManualClock() : nil
        self.gitClock = gitClock
        let runner = gitClock.map { ProcessRunner(clock: $0) } ?? runner
        root = folder.realPath
        env = [
            "PATH": "/usr/bin:/bin", "HOME": root, "GIT_CONFIG_NOSYSTEM": "1",
            "GIT_CONFIG_GLOBAL": "/dev/null",
        ]
        layout = ReviewsLayout(
            folder: URL(filePath: root + "/reviews", directoryHint: .isDirectory))
        git = RepoGit(
            path: self.holding?.path ?? "/usr/bin/git", environment: env, layout: layout,
            identity: GitTestRepo.identity, localRemotesForTestHome: true, runner: runner)
        let sources = root + "/sources"
        address = { URL(filePath: "\(sources)/\($0.key).git", directoryHint: .isDirectory) }
        store = RepoStore(layout: layout, git: git, cloneAddress: address, clock: clock, log: log)
    }

    // A bare source repository for the repository, with one commit of the files. The result is
    // the commit.
    @discardableResult
    func source(_ repo: RepoName, files: [String: String] = ["a.txt": "one\n"]) async throws
        -> CommitID
    {
        let work = root + "/work/" + repo.key
        let bare = root + "/sources/" + repo.key + ".git"
        let fm = FileManager.default
        try fm.createDirectory(atPath: work, withIntermediateDirectories: true)
        try await setup(["init", "-q"], in: work)
        for (path, text) in files {
            let file = work + "/" + path
            try fm.createDirectory(
                atPath: (file as NSString).deletingLastPathComponent,
                withIntermediateDirectories: true)
            try text.write(toFile: file, atomically: false, encoding: .utf8)
        }
        try await setup(["add", "-A"], in: work)
        try await setup(["commit", "-q", "-m", "one"], in: work)
        try fm.createDirectory(
            atPath: (bare as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try await setup(["clone", "-q", "--bare", work, bare], in: root)
        // A local source serves a partial clone, and the objects that a later command asks for,
        // as GitHub does.
        try await setup(["config", "uploadpack.allowFilter", "true"], in: bare)
        try await setup(["config", "uploadpack.allowAnySHA1InWant", "true"], in: bare)
        let head = await ProcessRunner().run(
            Command("/usr/bin/git", ["-C", work, "rev-parse", "HEAD"], environment: env,
                timeout: .seconds(30)))
        return try #require(CommitID(head.stdout.trimmed()))
    }

    // A git command of the set-up, with plain git, as the user would run it.
    func setup(_ args: [String], in dir: String) async throws {
        let identity = [
            "-c", "user.name=Test", "-c", "user.email=test@example.invalid", "-c",
            "init.defaultBranch=main",
        ]
        let result = await ProcessRunner().run(
            Command(
                "/usr/bin/git", identity + ["-C", dir] + args, environment: env,
                timeout: .seconds(30)))
        try #require(result.succeeded, "git \(args.joined(separator: " ")): \(result.stderr)")
    }

    func clone(_ repo: RepoName) -> String { layout.clone(repo).path(percentEncoded: false) }

    // The temporary folders of the clones of the repository (<clone>~cloning-<hex>), and the
    // folder <clone>~cloning of an earlier version.
    func temporaryFolders(_ repo: RepoName) -> [String] {
        let path = String(clone(repo).dropLast())
        let parent = (path as NSString).deletingLastPathComponent
        let name = (path as NSString).lastPathComponent
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: parent)) ?? []
        return entries.filter { $0.hasPrefix(name + "~cloning") }
    }

    // True when the clock of git sleeps to the end of the grace of a stop: the SIGTERM went, and
    // git, which ignores it, still runs.
    func graceSleeps() -> Bool {
        guard let gitClock else { return false }
        return gitClock.nextDeadline == gitClock.now.advanced(by: RepoGit.stopGrace)
    }

    // Stop the clones of the store: wait for the grace of the SIGTERM, end it (SIGKILL), and wait
    // for the end of the stop.
    func stop(_ store: RepoStore) async {
        let stopping = Task { await store.cancelClones() }
        if let gitClock {
            await waitUntil { graceSleeps() }
            gitClock.advance(by: RepoGit.stopGrace)
        }
        await stopping.value
    }

    func exists(_ path: String) -> Bool { FileManager.default.fileExists(atPath: path) }

    // The mode bits of the item at the path.
    func mode(_ path: String) -> Int {
        let attributes = try? FileManager.default.attributesOfItem(atPath: path)
        return (attributes?[.posixPermissions] as? Int) ?? -1
    }

    // The output of a plain git command in the folder.
    func gitOutput(_ args: [String], in dir: String) async -> String {
        await ProcessRunner().run(
            Command("/usr/bin/git", ["-C", dir] + args, environment: env, timeout: .seconds(30))
        ).stdout.trimmed()
    }
}

private func repo(_ text: String) throws -> RepoName { try #require(RepoName(text)) }

// A mark that a task sets when it ends.
@MainActor
private final class Done {
    var value = false
}

// A runner of the real git that counts its runs.
private final class RunCounter: CommandRunner {
    private let count = Mutex(0)
    private let inner = ProcessRunner()

    var runs: Int { count.withLock { $0 } }

    func run(_ command: Command) async -> ExecResult {
        count.withLock { $0 += 1 }
        return await inner.run(command)
    }
}

@MainActor
@Suite("the repo store of Reviews", .serialized, .testTimeLimit, .tags(.realProcess))
struct RepoStoreTests {
    // The clone is in lower case below the repos folder, with no checkout (no file of the
    // repository in the folder) and no blobs (a partial clone with the blob filter).
    @Test func aCloneHasNoCheckoutAndNoBlobs() async throws {
        let counter = RunCounter()
        let f = try RepoFixture(runner: counter)
        defer { f.folder.remove() }
        let name = try repo("Owner-A/Repo-A")
        try await f.source(name, files: ["a.txt": "one\n", "dir/b.txt": "two\n"])
        try await f.store.ensureClone(name)
        let clone = f.clone(name)
        #expect(clone.hasSuffix("/reviews/repos/owner-a/repo-a/"))
        #expect(f.exists(clone + ".git/HEAD"))
        let entries = try FileManager.default.contentsOfDirectory(atPath: clone)
        #expect(entries == [".git"])
        #expect(
            await f.gitOutput(["config", "--get", "remote.origin.partialclonefilter"], in: clone)
                == "blob:none")
        // No blob is in the clone: each object is a commit or a tree.
        let kinds = await f.gitOutput(
            ["cat-file", "--batch-all-objects", "--batch-check=%(objecttype)"], in: clone)
        #expect(Set(kinds.split(separator: "\n")) == ["commit", "tree"])
        #expect(f.mode(clone) & 0o077 == 0)
        #expect(f.temporaryFolders(name).isEmpty)
        #expect(await f.store.hasClone(name))
        // A second call finds the clone and runs no git.
        let runs = counter.runs
        try await f.store.ensureClone(name)
        #expect(counter.runs == runs)
    }

    // The worktree of a PR is detached at the head, in <clone>/.bifrost-worktrees/<number>, with
    // mode 0700, and its admin folder is the folder that RepoGit pins.
    @Test func theWorktreeIsDetachedAtTheHead() async throws {
        let f = try RepoFixture()
        defer { f.folder.remove() }
        let name = try repo("owner-a/repo-a")
        let head = try await f.source(name, files: ["a.txt": "one\n"])
        try await f.store.ensureClone(name)
        let pr = try #require(PRKey(text: "owner-a/repo-a#7"))
        let worktree = try await f.store.prepareWorktree(pr, head: head)
        let path = worktree.path(percentEncoded: false)
        #expect(path.hasSuffix("/repos/owner-a/repo-a/.bifrost-worktrees/7/"))
        #expect(
            try String(contentsOfFile: path + "a.txt", encoding: .utf8) == "one\n")
        #expect(await f.gitOutput(["rev-parse", "HEAD"], in: path) == head.hex)
        #expect(await f.gitOutput(["symbolic-ref", "-q", "HEAD"], in: path).isEmpty)
        #expect(f.exists(GitPlace.adminFolder(pr, f.layout) + "/gitdir"))
        #expect(f.mode(path) & 0o077 == 0)
        // A second prepare makes the worktree again, with the same admin folder.
        try "changed\n".write(toFile: path + "a.txt", atomically: false, encoding: .utf8)
        let again = try await f.store.prepareWorktree(pr, head: head)
        #expect(again == worktree)
        #expect(
            try String(contentsOfFile: path + "a.txt", encoding: .utf8) == "one\n")
        let status = await f.git.run(.status, in: .worktree(pr))
        #expect(status.succeeded)
    }

    // The reset after a round counts each change of the session, then removes them all: a
    // changed file, a new file, a new ignored file, a deleted file and a changed .git file.
    @Test func aResetCountsAndRemovesEachChange() async throws {
        let f = try RepoFixture()
        defer { f.folder.remove() }
        let name = try repo("owner-a/repo-a")
        let head = try await f.source(
            name, files: ["a.txt": "one\n", "b.txt": "two\n", ".gitignore": "*.log\n"])
        try await f.store.ensureClone(name)
        let pr = try #require(PRKey(text: "owner-a/repo-a#7"))
        let path = try await f.store.prepareWorktree(pr, head: head).path(percentEncoded: false)
        let gitFile = try String(contentsOfFile: path + ".git", encoding: .utf8)
        try "changed\n".write(toFile: path + "a.txt", atomically: false, encoding: .utf8)
        try "new\n".write(toFile: path + "c.txt", atomically: false, encoding: .utf8)
        try "log\n".write(toFile: path + "d.log", atomically: false, encoding: .utf8)
        try FileManager.default.removeItem(atPath: path + "b.txt")
        try "gitdir: /tmp/elsewhere\n".write(
            toFile: path + ".git", atomically: false, encoding: .utf8)
        #expect(await f.store.resetWorktree(pr) == 3)
        let entries = try FileManager.default.contentsOfDirectory(atPath: path).sorted()
        #expect(entries == [".git", ".gitignore", "a.txt", "b.txt"])
        #expect(try String(contentsOfFile: path + "a.txt", encoding: .utf8) == "one\n")
        #expect(try String(contentsOfFile: path + ".git", encoding: .utf8) == gitFile)
        #expect(await f.store.resetWorktree(pr) == 0)
        #expect(f.log.values == [.worktreeReset(pr, changes: 3), .worktreeReset(pr, changes: 0)])
    }

    // The changes of a request session for the check of its result: each changed, new (also in a
    // new folder) and deleted file by its full path in the worktree, and no ignored file.
    @Test func theChangedPathsAreEachChangeOfTheSession() async throws {
        let f = try RepoFixture()
        defer { f.folder.remove() }
        let name = try repo("owner-a/repo-a")
        let head = try await f.source(
            name, files: ["a.txt": "one\n", "b.txt": "two\n", ".gitignore": "*.log\n"])
        try await f.store.ensureClone(name)
        let pr = try #require(PRKey(text: "owner-a/repo-a#7"))
        let path = try await f.store.prepareWorktree(pr, head: head).path(percentEncoded: false)
        #expect(await f.store.changedPaths(pr) == [])
        try "changed\n".write(toFile: path + "a.txt", atomically: false, encoding: .utf8)
        try FileManager.default.createDirectory(
            atPath: path + "src/new", withIntermediateDirectories: true)
        try "new\n".write(toFile: path + "src/new/c.txt", atomically: false, encoding: .utf8)
        try "log\n".write(toFile: path + "d.log", atomically: false, encoding: .utf8)
        try FileManager.default.removeItem(atPath: path + "b.txt")
        #expect(await f.store.changedPaths(pr) == ["a.txt", "b.txt", "src/new/c.txt"])
        // A path that starts with a combining mark keeps the mark.
        let marked = "\u{301}e.txt"
        try "mark\n".write(toFile: path + marked, atomically: false, encoding: .utf8)
        let changed = try #require(await f.store.changedPaths(pr))
        #expect(changed.contains(marked) && !changed.contains("e.txt") && changed.count == 4)
    }

    // The input folder of a PR is empty with mode 0700 at each call. When the request goes, the
    // worktree and the input folder go, and git forgets the worktree. The clone stays.
    @Test func aGoneRequestRemovesItsWorktreeAndInputFolder() async throws {
        let f = try RepoFixture()
        defer { f.folder.remove() }
        let name = try repo("owner-a/repo-a")
        let head = try await f.source(name)
        try await f.store.ensureClone(name)
        let pr = try #require(PRKey(text: "owner-a/repo-a#7"))
        let worktree = try await f.store.prepareWorktree(pr, head: head).path(percentEncoded: false)
        let input = try await f.store.inputFolder(pr).path(percentEncoded: false)
        #expect(input.hasSuffix("/repos/owner-a/repo-a/.bifrost-io/7/"))
        #expect(f.mode(input) == 0o700)
        try "{}".write(toFile: input + "result.json", atomically: false, encoding: .utf8)
        #expect(try await f.store.inputFolder(pr).path(percentEncoded: false) == input)
        #expect(try FileManager.default.contentsOfDirectory(atPath: input).isEmpty)
        try "{}".write(toFile: input + "input.json", atomically: false, encoding: .utf8)
        await f.store.removePR(pr)
        #expect(!f.exists(worktree))
        #expect(!f.exists(input))
        #expect(!f.exists(GitPlace.adminFolder(pr, f.layout)))
        #expect(f.exists(f.clone(name) + ".git/HEAD"))
        // A second removal finds nothing to remove.
        await f.store.removePR(pr)
    }

    // A failed clone leaves no folder and logs one line. The repository counts as failed for 1
    // hour on the clock, and a second failure in a row logs nothing more. A clone that works
    // clears the failure.
    @Test func aFailedCloneWaitsOneHour() async throws {
        let f = try RepoFixture()
        defer { f.folder.remove() }
        let name = try repo("owner-a/missing")
        #expect(!f.store.failedRecently(name))
        await #expect(throws: RepoError.self) { try await f.store.ensureClone(name) }
        #expect(f.store.failedRecently(name))
        #expect(!f.exists(f.clone(name)))
        #expect(f.temporaryFolders(name).isEmpty)
        f.clock.advance(by: .seconds(3599))
        #expect(f.store.failedRecently(name))
        f.clock.advance(by: .seconds(1))
        #expect(!f.store.failedRecently(name))
        // A click tries at once, and a failure in a row logs no second line.
        await #expect(throws: RepoError.self) { try await f.store.ensureClone(name) }
        #expect(f.store.failedRecently(name))
        #expect(f.log.values.count == 1)
        guard case .cloneFailed(name, let error)? = f.log.values.first else {
            Issue.record("No line of the failed clone: \(f.log.values)")
            return
        }
        #expect(!error.message.isEmpty)
        try await f.source(name)
        try await f.store.ensureClone(name)
        #expect(!f.store.failedRecently(name))
    }

    // A stop of the clones ends the git of a clone that runs (SIGTERM through the process
    // runner, then SIGKILL at the end of the grace for a git that ignores SIGTERM) and returns
    // only after git ended and its temporary folder went. A stopped clone is no failure: it logs
    // nothing and needs no wait.
    @Test func aStopEndsTheCloneAndRemovesItsFolder() async throws {
        let f = try RepoFixture(holding: true)
        defer { f.folder.remove() }
        let holding = try #require(f.holding)
        let name = try repo("owner-a/repo-a")
        let cloning = Task { () -> RepoError? in
            do throws(RepoError) {
                try await f.store.ensureClone(name)
                return nil
            } catch {
                return error
            }
        }
        try #require(await waitUntil { holding.clones.count == 1 })
        let clone = try #require(holding.clones.first)
        #expect(clone.folder.hasPrefix(String(f.clone(name).dropLast()) + "~cloning-"))
        #expect(kill(clone.pid, 0) == 0)
        let gitClock = try #require(f.gitClock)
        let stopped = Done()
        let stopping = Task {
            await f.store.cancelClones()
            stopped.value = true
        }
        // The SIGTERM went, and git ignores it: the stop waits for the end of the grace.
        try #require(await waitUntil { f.graceSleeps() })
        for _ in 0..<20 { await Task.yield() }
        #expect(!stopped.value)
        #expect(kill(clone.pid, 0) == 0)
        gitClock.advance(by: RepoGit.stopGrace)
        await stopping.value
        #expect(kill(clone.pid, 0) != 0)
        #expect(!f.exists(clone.folder))
        #expect(f.temporaryFolders(name).isEmpty)
        #expect(await cloning.value == .cancelled)
        #expect(!f.store.failedRecently(name))
        #expect(f.log.values.isEmpty)
        #expect(!(await f.store.hasClone(name)))
    }

    // A new start (a second store on the same Reviews folder) clones into a new temporary folder
    // of its own, and removes the one that the earlier run left. So it never runs a second git
    // into the folder of a git that still runs.
    @Test func aNewStartNeverClonesIntoTheFolderOfAnotherGit() async throws {
        let f = try RepoFixture(holding: true)
        defer { f.folder.remove() }
        let holding = try #require(f.holding)
        let name = try repo("owner-a/repo-a")
        let first = Task { try? await f.store.ensureClone(name) }
        try #require(await waitUntil { holding.clones.count == 1 })
        let restarted = RepoStore(
            layout: f.layout, git: f.git, cloneAddress: f.address, clock: ManualClock(),
            log: Recorder<ReviewsLogEvent>())
        let second = Task { try? await restarted.ensureClone(name) }
        try #require(await waitUntil { holding.clones.count == 2 })
        let clones = holding.clones
        #expect(clones[0].folder != clones[1].folder)
        #expect(!f.exists(clones[0].folder))
        await f.stop(f.store)
        await f.stop(restarted)
        for clone in clones { #expect(kill(clone.pid, 0) != 0) }
        _ = await first.value
        _ = await second.value
        #expect(f.temporaryFolders(name).isEmpty)
    }

    // Remove all clones removes each folder below the repos folder, and nothing else of the
    // Reviews folder. The repos folder stays.
    @Test func removeAllClonesRemovesOnlyTheReposFolder() async throws {
        let f = try RepoFixture()
        defer { f.folder.remove() }
        let names = [try repo("owner-a/repo-a"), try repo("owner-b/repo-b")]
        for name in names {
            try await f.source(name)
            try await f.store.ensureClone(name)
        }
        let reviews = f.layout.folder.path(percentEncoded: false)
        try "{}".write(toFile: reviews + "state.json", atomically: false, encoding: .utf8)
        // A link in the repos folder to a folder outside it: the removal deletes the link only.
        let outside = f.root + "/outside"
        try FileManager.default.createDirectory(atPath: outside, withIntermediateDirectories: true)
        try "keep".write(toFile: outside + "/keep.txt", atomically: false, encoding: .utf8)
        let reposRoot = f.layout.reposRoot.path(percentEncoded: false)
        try FileManager.default.createSymbolicLink(
            atPath: reposRoot + "link", withDestinationPath: outside)
        try await f.store.removeAllClones()
        #expect(try FileManager.default.contentsOfDirectory(atPath: reposRoot).isEmpty)
        #expect(f.exists(reviews + "state.json"))
        #expect(f.exists(outside + "/keep.txt"))
        for name in names { #expect(!(await f.store.hasClone(name))) }
        // With no repos folder, the removal does nothing.
        try FileManager.default.removeItem(atPath: reposRoot)
        try await f.store.removeAllClones()
    }

    // A hook of the clone never runs: after the clone, a post-checkout hook in the .git/hooks
    // folder of the clone writes a marker file, and the checkout of the worktree runs no hook.
    @Test func noCommandRunsAHookOfTheRepo() async throws {
        let f = try RepoFixture()
        defer { f.folder.remove() }
        let name = try repo("owner-a/repo-a")
        let head = try await f.source(name)
        try await f.store.ensureClone(name)
        let hooks = f.clone(name) + ".git/hooks"
        let marker = f.root + "/hook-ran"
        try FileManager.default.createDirectory(atPath: hooks, withIntermediateDirectories: true)
        for hook in ["post-checkout", "reference-transaction"] {
            let file = hooks + "/" + hook
            try "#!/bin/sh\ntouch '\(marker)'\n".write(
                toFile: file, atomically: false, encoding: .utf8)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: file)
        }
        // A plain git checkout runs the hook, so the hook works.
        let control = f.root + "/control"
        try await f.setup(
            ["worktree", "add", "-q", "--detach", control, head.hex], in: f.clone(name))
        #expect(f.exists(marker))
        try FileManager.default.removeItem(atPath: marker)
        let pr = try #require(PRKey(text: "owner-a/repo-a#7"))
        _ = try await f.store.prepareWorktree(pr, head: head)
        _ = await f.store.resetWorktree(pr)
        await f.store.removePR(pr)
        #expect(!f.exists(marker))
    }
}
