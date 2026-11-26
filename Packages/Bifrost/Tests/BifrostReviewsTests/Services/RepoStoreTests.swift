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
            path: self.holding?.path ?? testGit, environment: env, layout: layout,
            identity: GitTestRepo.identity, localRemotesForTestHome: true, runner: runner)
        let sources = root + "/sources"
        address = { URL(filePath: "\(sources)/\($0.key).git", directoryHint: .isDirectory) }
        store = RepoStore(layout: layout, git: git, cloneAddress: address, clock: clock, log: log)
    }

    // The work and sources folders of a set-up that many tests share, made once per test process.
    // The first test to ask for a key runs make on a fixture of its own and keeps an image of
    // those two folders and make's result, and every test then gets a fresh copy of the image in
    // its own root, along with that result. The set-up's ten or so git runs cost about a second
    // a test in the sandbox, so this way only the first test pays for them. The config of a bare
    // source names the work repository it was cloned from, so the copy names its own instead.
    func shared<Value: Sendable>(
        _ key: String, make: @escaping @MainActor (RepoFixture) async throws -> Value
    ) async throws -> Value {
        let made: SharedSetup
        if let task = sharedSetups[key] {
            made = try await task.value
        } else {
            let task = Task { @MainActor () throws -> SharedSetup in
                let template = try RepoFixture()
                defer { template.folder.remove() }
                let value = try await make(template)
                let image = try FolderImage(of: template.root, folders: ["work", "sources"])
                return SharedSetup(root: template.root, image: image, value: value)
            }
            sharedSetups[key] = task
            do {
                made = try await task.value
            } catch {
                sharedSetups[key] = nil
                throw error
            }
        }
        let (old, new) = (Data(made.root.utf8), Data(root.utf8))
        try made.image.editing { path, data in
            path.hasSuffix(".git/config") ? data.replacing(old, with: new) : nil
        }.write(to: root)
        return try #require(made.value as? Value)
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
            Command(testGit, ["-C", work, "rev-parse", "HEAD"], environment: env,
                timeout: .seconds(30)))
        return try #require(CommitID(head.stdout.trimmed()))
    }

    // A new commit of the files on the last commit of the source of the repository, at
    // refs/pull/<number>/head of the source. The result is the commit.
    func pullHead(_ repo: RepoName, number: Int, files: [String: String]) async throws
        -> CommitID
    {
        let work = root + "/work/" + repo.key
        for (path, text) in files {
            try text.write(toFile: work + "/" + path, atomically: false, encoding: .utf8)
        }
        try await setup(["add", "-A"], in: work)
        try await setup(["commit", "-q", "-m", "next"], in: work)
        try await setup(
            [
                "push", "-q", root + "/sources/" + repo.key + ".git",
                "HEAD:refs/pull/\(number)/head",
            ],
            in: work)
        let head = await gitOutput(["rev-parse", "HEAD"], in: work)
        return try #require(CommitID(head))
    }

    // A git command of the set-up, with plain git, as the user would run it.
    func setup(_ args: [String], in dir: String) async throws {
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
            Command(testGit, ["-C", dir] + args, environment: env, timeout: .seconds(30))
        ).stdout.trimmed()
    }

    // The inode number of the item at the path (not of the item that a link names).
    func inode(_ path: String) -> Int {
        let attributes = try? FileManager.default.attributesOfItem(atPath: path)
        return (attributes?[.systemFileNumber] as? Int) ?? -1
    }

    // True when a folder (not a link) is at the path.
    func isFolder(_ path: String) -> Bool {
        let attributes = try? FileManager.default.attributesOfItem(atPath: path)
        return attributes?[.type] as? FileAttributeType == .typeDirectory
    }
}

// A set-up of RepoFixture.shared: the root it was made in, the image of its work and sources
// folders and the result of its make.
private struct SharedSetup: Sendable {
    var root: String
    var image: FolderImage
    var value: any Sendable
}

// The set-ups that the tests of this process share, by key. A set-up that fails is dropped, so
// the next test makes it again.
@MainActor private var sharedSetups: [String: Task<SharedSetup, any Error>] = [:]

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

// A runner of the real git that does not run git clean, and gives exit code 0 for it.
private final class NoCleanRunner: CommandRunner {
    private let inner = ProcessRunner()

    func run(_ command: Command) async -> ExecResult {
        if command.arguments.contains("clean") { return ExecResult(.exited(0)) }
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

    // The safety net of the worktree: a change counts as a change of a person until Bifrost
    // knows it, from the end of the turn of a round (markLeftovers) or a reset. A later write to
    // a known file, and a new file, count again. With no worktree in its place there is none.
    @Test func unknownChangesAreTheChangesThatNoRoundMade() async throws {
        let f = try RepoFixture()
        defer { f.folder.remove() }
        let name = try repo("owner-a/repo-a")
        let head = try await f.source(name, files: ["a.txt": "one\n", "b.txt": "two\n"])
        try await f.store.ensureClone(name)
        let pr = try #require(PRKey(text: "owner-a/repo-a#7"))
        #expect(await f.store.unknownChanges(pr) == [])
        let path = try await f.store.prepareWorktree(pr, head: head).path(percentEncoded: false)
        #expect(await f.store.unknownChanges(pr) == [])
        try "changed\n".write(toFile: path + "a.txt", atomically: false, encoding: .utf8)
        try FileManager.default.removeItem(atPath: path + "b.txt")
        #expect(await f.store.unknownChanges(pr) == ["a.txt", "b.txt"])
        // The turn of a round ends: its changes are known.
        await f.store.markLeftovers(pr)
        #expect(await f.store.unknownChanges(pr) == [])
        // A person changes the file again, and adds a file.
        try "person, later\n".write(toFile: path + "a.txt", atomically: false, encoding: .utf8)
        try "new\n".write(toFile: path + "c.txt", atomically: false, encoding: .utf8)
        #expect(await f.store.unknownChanges(pr) == ["a.txt", "c.txt"])
        // A reset makes the worktree as Bifrost knows it.
        await f.store.resetWorktree(pr)
        #expect(await f.store.unknownChanges(pr) == [])
    }

    // A reset after a round runs only when the worktree has no change that no round made: a
    // change of a person keeps the whole worktree, and with only known changes the reset runs.
    @Test func resetIfKnownKeepsTheChangesOfAPerson() async throws {
        let f = try RepoFixture()
        defer { f.folder.remove() }
        let name = try repo("owner-a/repo-a")
        let head = try await f.source(name, files: ["a.txt": "one\n"])
        try await f.store.ensureClone(name)
        let pr = try #require(PRKey(text: "owner-a/repo-a#7"))
        let path = try await f.store.prepareWorktree(pr, head: head).path(percentEncoded: false)
        try "round\n".write(toFile: path + "a.txt", atomically: false, encoding: .utf8)
        await f.store.markLeftovers(pr)
        try "person\n".write(toFile: path + "b.txt", atomically: false, encoding: .utf8)
        #expect(await f.store.resetIfKnown(pr) == false)
        #expect(await f.store.changedPaths(pr) == ["a.txt", "b.txt"])
        try FileManager.default.removeItem(atPath: path + "b.txt")
        #expect(await f.store.resetIfKnown(pr))
        #expect(await f.store.changedPaths(pr) == [])
    }

    // A commit that did not reach GitHub goes back to changes: HEAD and the index go to the
    // head, and the files of the commit stay. A worktree at the head stays as it is.
    @Test func uncommitKeepsTheFilesOfTheCommit() async throws {
        let f = try RepoFixture()
        defer { f.folder.remove() }
        let name = try repo("owner-a/repo-a")
        let head = try await f.source(name, files: ["a.txt": "one\n"])
        try await f.store.ensureClone(name)
        let pr = try #require(PRKey(text: "owner-a/repo-a#7"))
        let path = try await f.store.prepareWorktree(pr, head: head).path(percentEncoded: false)
        try "own\n".write(toFile: path + "a.txt", atomically: false, encoding: .utf8)
        try "new\n".write(toFile: path + "c.txt", atomically: false, encoding: .utf8)
        #expect(await f.git.run(.add(["a.txt", "c.txt"]), in: .worktree(pr)).succeeded)
        #expect(await f.git.run(.commit(message: "own: change"), in: .worktree(pr)).succeeded)
        let made = try #require(await f.store.worktreeHead(pr))
        #expect(made != head)
        #expect(await f.store.changedPaths(pr) == [])
        await f.store.uncommit(pr, to: head)
        #expect(await f.store.worktreeHead(pr) == head)
        #expect(await f.store.changedPaths(pr) == ["a.txt", "c.txt"])
        #expect(try String(contentsOfFile: path + "a.txt", encoding: .utf8) == "own\n")
        await f.store.uncommit(pr, to: head)
        #expect(await f.store.worktreeHead(pr) == head)
        #expect(await f.store.changedPaths(pr) == ["a.txt", "c.txt"])
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

    // The round folder of a PR is made with mode 0700 and stays from round to round: each call
    // keeps the folder itself and removes each item in it, also a hidden file and a folder. So
    // the result of the last round is gone at the start of the next round.
    @Test func theRoundFolderStaysAndLosesTheFilesOfTheLastRound() async throws {
        let f = try RepoFixture()
        defer { f.folder.remove() }
        let pr = try #require(PRKey(text: "owner-a/repo-a#7"))
        let folder = try await f.store.roundFolder(pr)
        let path = folder.path(percentEncoded: false)
        #expect(path.hasSuffix("/repos/owner-a/repo-a/.bifrost-io/7/"))
        #expect(f.mode(path) == 0o700)
        #expect(try FileManager.default.contentsOfDirectory(atPath: path).isEmpty)
        let last = RoundFiles(folder: folder, token: "0f8a2c1e-5b7d-4c3a-9e21-6d4b8f0a1c2e")
        try "{}".write(to: last.result, atomically: false, encoding: .utf8)
        try "x".write(toFile: path + ".hidden", atomically: false, encoding: .utf8)
        try FileManager.default.createDirectory(
            atPath: path + "logs", withIntermediateDirectories: true)
        try "x".write(toFile: path + "logs/log.txt", atomically: false, encoding: .utf8)
        #expect(await f.store.readResult(at: last.result, limit: 10) == .data(Data("{}".utf8)))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
        let inode = f.inode(path)
        #expect(try await f.store.roundFolder(pr) == folder)
        #expect(f.inode(path) == inode)
        #expect(f.mode(path) == 0o700)
        #expect(try FileManager.default.contentsOfDirectory(atPath: path).isEmpty)
        #expect(await f.store.readResult(at: last.result, limit: 10) == .missing)
    }

    // A link in the round folder goes, not the file or the folder that it names. A link at the
    // place of the round folder goes too, and a new folder takes its place.
    @Test func aLinkInTheRoundFolderGoesAsALink() async throws {
        let f = try RepoFixture()
        defer { f.folder.remove() }
        let pr = try #require(PRKey(text: "owner-a/repo-a#7"))
        let outside = f.root + "/outside"
        try FileManager.default.createDirectory(atPath: outside, withIntermediateDirectories: true)
        try "keep".write(toFile: outside + "/keep.txt", atomically: false, encoding: .utf8)
        let outsideMode = f.mode(outside)
        let path = try await f.store.roundFolder(pr).path(percentEncoded: false)
        try FileManager.default.createSymbolicLink(
            atPath: path + "result-0f8a2c1e5b7d.json", withDestinationPath: outside + "/keep.txt")
        try FileManager.default.createSymbolicLink(
            atPath: path + "dir", withDestinationPath: outside)
        _ = try await f.store.roundFolder(pr)
        #expect(try FileManager.default.contentsOfDirectory(atPath: path).isEmpty)
        #expect(f.exists(outside + "/keep.txt"))
        // A link at the place of the round folder.
        let plain = String(path.dropLast())
        try FileManager.default.removeItem(atPath: plain)
        try FileManager.default.createSymbolicLink(atPath: plain, withDestinationPath: outside)
        _ = try await f.store.roundFolder(pr)
        #expect(f.isFolder(plain))
        #expect(f.mode(plain) == 0o700)
        #expect(try FileManager.default.contentsOfDirectory(atPath: plain).isEmpty)
        #expect(f.exists(outside + "/keep.txt"))
        #expect(f.mode(outside) == outsideMode)
    }

    // A worktree of the PR that is in its place stays for the next round: the same folder moves
    // to the new head, a file that the last round added goes, and its .git file is written again.
    @Test func placeWorktreeKeepsTheFolderAndMovesItToTheNewHead() async throws {
        let f = try RepoFixture()
        defer { f.folder.remove() }
        let name = try repo("owner-a/repo-a")
        let first = try await f.source(name, files: ["a.txt": "one\n"])
        let second = try await f.pullHead(name, number: 7, files: ["a.txt": "two\n"])
        try await f.store.ensureClone(name)
        let pr = try #require(PRKey(text: "owner-a/repo-a#7"))
        let fetched = try await f.store.fetchPR(pr, base: try #require(BranchName("main")))
        #expect(fetched.head == second)
        // With no worktree, the place makes it.
        let made = try await f.store.placeWorktree(pr, head: first)
        #expect(made == .made(f.layout.worktree(name, number: 7)) && !made.isKept)
        let path = made.url.path(percentEncoded: false)
        let gitFile = try String(contentsOfFile: path + ".git", encoding: .utf8)
        let inode = f.inode(path)
        try "new\n".write(toFile: path + "new.txt", atomically: false, encoding: .utf8)
        try "gitdir: /tmp/elsewhere\n".write(
            toFile: path + ".git", atomically: false, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
        let kept = try await f.store.placeWorktree(pr, head: second)
        #expect(kept == .kept(made.url) && kept.isKept && kept.url == made.url)
        #expect(f.inode(path) == inode)
        #expect(await f.gitOutput(["rev-parse", "HEAD"], in: path) == second.hex)
        #expect(try String(contentsOfFile: path + "a.txt", encoding: .utf8) == "two\n")
        #expect(!f.exists(path + "new.txt"))
        #expect(try String(contentsOfFile: path + ".git", encoding: .utf8) == gitFile)
        #expect(f.mode(path) == 0o700)
        // Only a worktree that was there and that placeWorktree made again gets a log line.
        #expect(!f.log.values.contains(.worktreeMadeAgain(pr)))
    }

    // A kept worktree needs a reset that worked. With a lock file in its admin folder, git can't
    // reset it: at the same head the change of the last round would stay, and at a new head
    // HEAD would not move. Each time, placeWorktree makes the worktree again and logs it.
    @Test func placeWorktreeMakesTheWorktreeAgainWhenTheResetFails() async throws {
        let f = try RepoFixture()
        defer { f.folder.remove() }
        let name = try repo("owner-a/repo-a")
        let first = try await f.source(name, files: ["a.txt": "one\n"])
        let second = try await f.pullHead(name, number: 7, files: ["a.txt": "two\n"])
        try await f.store.ensureClone(name)
        let pr = try #require(PRKey(text: "owner-a/repo-a#7"))
        _ = try await f.store.fetchPR(pr, base: try #require(BranchName("main")))
        let worktree = try await f.store.placeWorktree(pr, head: first).url
        let path = worktree.path(percentEncoded: false)
        let lock = GitPlace.adminFolder(pr, f.layout) + "/index.lock"
        try "changed\n".write(toFile: path + "a.txt", atomically: false, encoding: .utf8)
        try "".write(toFile: lock, atomically: false, encoding: .utf8)
        #expect(try await f.store.placeWorktree(pr, head: first) == .made(worktree))
        #expect(try String(contentsOfFile: path + "a.txt", encoding: .utf8) == "one\n")
        #expect(!f.exists(lock))
        #expect(f.log.values.filter { $0 == .worktreeMadeAgain(pr) }.count == 1)
        try "".write(toFile: lock, atomically: false, encoding: .utf8)
        #expect(try await f.store.placeWorktree(pr, head: second) == .made(worktree))
        #expect(await f.gitOutput(["rev-parse", "HEAD"], in: path) == second.hex)
        #expect(try String(contentsOfFile: path + "a.txt", encoding: .utf8) == "two\n")
        #expect(f.log.values.filter { $0 == .worktreeMadeAgain(pr) }.count == 2)
    }

    // A discard whose reset fails (a lock file in the admin folder) cleans nothing: the changed
    // file, the new file and the ignored file of the person all stay. With the lock gone, the
    // same discard resets and cleans.
    @Test func aFailedResetNeverCleansTheFilesOfThePerson() async throws {
        let f = try RepoFixture()
        defer { f.folder.remove() }
        let name = try repo("owner-a/repo-a")
        let head = try await f.source(name, files: ["a.txt": "one\n", ".gitignore": "*.log\n"])
        try await f.store.ensureClone(name)
        let pr = try #require(PRKey(text: "owner-a/repo-a#7"))
        let path = try await f.store.prepareWorktree(pr, head: head).path(percentEncoded: false)
        try "changed\n".write(toFile: path + "a.txt", atomically: false, encoding: .utf8)
        try "new\n".write(toFile: path + "new.txt", atomically: false, encoding: .utf8)
        try "log\n".write(toFile: path + "d.log", atomically: false, encoding: .utf8)
        let lock = GitPlace.adminFolder(pr, f.layout) + "/index.lock"
        try "".write(toFile: lock, atomically: false, encoding: .utf8)
        #expect(await f.store.discard(pr, to: head) == false)
        #expect(try String(contentsOfFile: path + "a.txt", encoding: .utf8) == "changed\n")
        #expect(f.exists(path + "new.txt") && f.exists(path + "d.log"))
        try FileManager.default.removeItem(atPath: lock)
        #expect(await f.store.discard(pr, to: head))
        #expect(!f.exists(path + "new.txt") && !f.exists(path + "d.log"))
        #expect(try String(contentsOfFile: path + "a.txt", encoding: .utf8) == "one\n")
    }

    // A folder at the place of the worktree that does not belong to the clone (its admin folder
    // is damaged) is never deleted: it moves aside with its files, the log names its new path,
    // and the worktree is made again at the head.
    @Test func aFolderThatIsNotTheClonesMovesAsideWithItsFiles() async throws {
        let f = try RepoFixture()
        defer { f.folder.remove() }
        let name = try repo("owner-a/repo-a")
        let head = try await f.source(name, files: ["a.txt": "one\n"])
        try await f.store.ensureClone(name)
        let pr = try #require(PRKey(text: "owner-a/repo-a#7"))
        let worktree = try await f.store.prepareWorktree(pr, head: head)
        let path = worktree.path(percentEncoded: false)
        try "work\n".write(toFile: path + "mine.txt", atomically: false, encoding: .utf8)
        try FileManager.default.removeItem(atPath: GitPlace.adminFolder(pr, f.layout) + "/gitdir")
        #expect(!f.git.belongsToClone(pr))
        #expect(try await f.store.placeWorktree(pr, head: head) == .made(worktree))
        #expect(!f.exists(path + "mine.txt") && f.git.belongsToClone(pr))
        let parent = (String(path.dropLast()) as NSString).deletingLastPathComponent
        let aside = try FileManager.default.contentsOfDirectory(atPath: parent)
            .filter { $0.contains("~kept-") }
        let kept = try #require(aside.first)
        #expect(aside.count == 1)
        let full = parent + "/" + kept
        #expect(try String(contentsOfFile: full + "/mine.txt", encoding: .utf8) == "work\n")
        #expect(f.log.values.contains(.worktreeKeptAside(pr, path: full)))
    }

    // The commit of a PR that reached the clone only through refs/bifrost/pr/<number> (a pull
    // head, no branch) is on GitHub. A commit of the copy is not, and a missing ref is a doubt.
    @Test func theCopyHoldsACommitThatGitHubLacksOnlyWithALocalCommit() async throws {
        let f = try RepoFixture()
        defer { f.folder.remove() }
        let name = try repo("owner-a/repo-a")
        try await f.source(name, files: ["a.txt": "one\n"])
        try await f.store.ensureClone(name)
        let head = try await f.pullHead(name, number: 7, files: ["a.txt": "two\n"])
        let pr = try #require(PRKey(text: "owner-a/repo-a#7"))
        // The fetch of the PR gives refs/bifrost/pr/7, and no remote branch holds the head.
        let fetched = try await f.store.fetchPR(pr, base: try #require(BranchName("main")))
        #expect(fetched.head == head)
        let path = try await f.store.prepareWorktree(pr, head: head).path(percentEncoded: false)
        #expect(await f.store.hasUnpublishedCommit(pr) == false)
        try "local\n".write(toFile: path + "b.txt", atomically: false, encoding: .utf8)
        try await f.setup(["add", "-A"], in: path)
        try await f.setup(["commit", "-q", "-m", "local"], in: path)
        #expect(await f.store.hasUnpublishedCommit(pr))
        try await f.setup(["reset", "-q", "--hard", head.hex], in: path)
        #expect(await f.store.hasUnpublishedCommit(pr) == false)
        try await f.setup(["update-ref", "-d", "refs/bifrost/pr/7"], in: f.clone(name))
        #expect(await f.store.hasUnpublishedCommit(pr))
    }

    // The drop of a PR (removePR) follows the same rule: a folder that is not the clone's moves
    // aside with its files, and a worktree of the clone goes.
    @Test func theDropOfAPRKeepsAFolderThatIsNotTheClones() async throws {
        let f = try RepoFixture()
        defer { f.folder.remove() }
        let name = try repo("owner-a/repo-a")
        let head = try await f.source(name, files: ["a.txt": "one\n"])
        try await f.store.ensureClone(name)
        let pr = try #require(PRKey(text: "owner-a/repo-a#7"))
        let path = try await f.store.prepareWorktree(pr, head: head).path(percentEncoded: false)
        try "work\n".write(toFile: path + "mine.txt", atomically: false, encoding: .utf8)
        try FileManager.default.removeItem(atPath: GitPlace.adminFolder(pr, f.layout) + "/gitdir")
        await f.store.removePR(pr)
        let parent = (String(path.dropLast()) as NSString).deletingLastPathComponent
        let aside = try FileManager.default.contentsOfDirectory(atPath: parent)
            .filter { $0.contains("~kept-") }
        let kept = try #require(aside.first)
        #expect(!f.exists(path) && aside.count == 1)
        #expect(
            try String(contentsOfFile: parent + "/" + kept + "/mine.txt", encoding: .utf8)
                == "work\n")
        #expect(f.log.values.contains(.worktreeKeptAside(pr, path: parent + "/" + kept)))
        // A worktree of the clone goes, with no folder kept.
        let again = try await f.store.prepareWorktree(pr, head: head).path(percentEncoded: false)
        await f.store.removePR(pr)
        #expect(!f.exists(again))
        #expect(
            try FileManager.default.contentsOfDirectory(atPath: parent)
                .filter { $0.contains("~kept-") }.count == 1)
    }

    // A file that the clean left (git status lists it as not tracked) is never kept: the
    // worktree is made again. Here git clean does not run, so only that check finds the file.
    @Test func placeWorktreeMakesTheWorktreeAgainWhenTheCleanLeavesAFile() async throws {
        let f = try RepoFixture(runner: NoCleanRunner())
        defer { f.folder.remove() }
        let name = try repo("owner-a/repo-a")
        let head = try await f.source(name, files: ["a.txt": "one\n"])
        try await f.store.ensureClone(name)
        let pr = try #require(PRKey(text: "owner-a/repo-a#7"))
        let worktree = try await f.store.placeWorktree(pr, head: head).url
        let path = worktree.path(percentEncoded: false)
        try FileManager.default.createDirectory(
            atPath: path + "left", withIntermediateDirectories: true)
        try "old\n".write(toFile: path + "left/old.txt", atomically: false, encoding: .utf8)
        #expect(try await f.store.placeWorktree(pr, head: head) == .made(worktree))
        #expect(!f.exists(path + "left"))
        #expect(f.log.values.contains(.worktreeMadeAgain(pr)))
        // With no file left, the worktree stays.
        #expect(try await f.store.placeWorktree(pr, head: head) == .kept(worktree))
    }

    // A worktree that is not the clone's is made again at the head: one whose admin folder names
    // another folder, and a link at the place of the worktree, also when the link names the
    // worktree of the clone. The link goes, not the folder that it names.
    @Test func placeWorktreeMakesTheWorktreeAgainWhenItIsNotTheClones() async throws {
        let f = try RepoFixture()
        defer { f.folder.remove() }
        let name = try repo("owner-a/repo-a")
        let head = try await f.source(name, files: ["a.txt": "one\n"])
        try await f.store.ensureClone(name)
        let pr = try #require(PRKey(text: "owner-a/repo-a#7"))
        let worktree = try await f.store.prepareWorktree(pr, head: head)
        let path = worktree.path(percentEncoded: false)
        try "new\n".write(toFile: path + "new.txt", atomically: false, encoding: .utf8)
        try "\(f.root)/elsewhere/.git\n".write(
            toFile: GitPlace.adminFolder(pr, f.layout) + "/gitdir", atomically: false,
            encoding: .utf8)
        #expect(try await f.store.placeWorktree(pr, head: head) == .made(worktree))
        #expect(!f.exists(path + "new.txt"))
        #expect(await f.gitOutput(["rev-parse", "HEAD"], in: path) == head.hex)
        #expect(f.git.belongsToClone(pr))
        // The worktree moves out, and a link at its place names it. git still finds the
        // worktree through the link, but placeWorktree does not keep a link.
        let plain = String(path.dropLast())
        let outside = f.root + "/outside"
        try FileManager.default.moveItem(atPath: plain, toPath: outside)
        try FileManager.default.createSymbolicLink(atPath: plain, withDestinationPath: outside)
        #expect(f.git.belongsToClone(pr))
        #expect(try await f.store.placeWorktree(pr, head: head) == .made(worktree))
        #expect(f.isFolder(plain))
        #expect(f.exists(outside + "/a.txt"))
        #expect(await f.gitOutput(["rev-parse", "HEAD"], in: path) == head.hex)
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

    // The device is not in the compare of two stamps: a volume can get another number after a
    // reboot. Another inode, size or time is a change.
    @Test func aStampWithAnotherDeviceIsTheSameStamp() throws {
        func stamp(device: Int = 16_777_234, inode: Int = 5, size: Int = 10) throws -> PathStamp {
            let list: [JSONValue] = [
                .int(1), .int(33_188), .int(device), .int(inode), .int(size), .int(100), .int(2),
                .int(100), .int(3),
            ]
            return try #require(PathStamp(stored: .array(list)))
        }
        #expect(try stamp() == stamp(device: 99))
        #expect(try stamp() != stamp(inode: 6))
        #expect(try stamp() != stamp(size: 11))
    }
}
