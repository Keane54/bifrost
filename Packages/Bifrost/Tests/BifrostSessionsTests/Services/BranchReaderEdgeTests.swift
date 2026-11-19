import BifrostTestSupport
import Testing

@testable import BifrostFoundation
@testable import BifrostSessions

// The branch reader on small file trees. Each case has the files and folders of a fake file
// system, the folder to read, the branch that the reader gives and the number of git commands
// that it runs. Git answers "from-git" for the folder that it is asked about.

private struct Tree: Sendable, CustomTestStringConvertible {
    var name: String
    var files: [String: String] = [:]
    var folders: [String] = []
    var cwd: String
    var skipRoots: [String] = []
    var branch: String?
    var gitCalls = 0

    var testDescription: String { name }
}

private let hash40 = String(repeating: "c", count: 40)
private let hash64 = String(repeating: "d", count: 64)

private let trees: [Tree] = [
    Tree(
        name: "a HEAD with a branch", files: ["/r/.git/HEAD": "ref: refs/heads/main\n"],
        folders: ["/r/.git"], cwd: "/r", branch: "main"),
    Tree(
        name: "a HEAD with CRLF and spaces",
        files: ["/r/.git/HEAD": " ref: refs/heads/feat/a \r\n"], folders: ["/r/.git"],
        cwd: "/r", branch: "feat/a"),
    Tree(
        name: "a HEAD with a hash of 40 digits", files: ["/r/.git/HEAD": hash40],
        folders: ["/r/.git"], cwd: "/r", branch: "HEAD"),
    Tree(
        name: "a HEAD with a hash of 64 digits", files: ["/r/.git/HEAD": hash64 + "\n"],
        folders: ["/r/.git"], cwd: "/r", branch: "HEAD"),
    Tree(
        name: "a HEAD with strange text asks git", files: ["/r/.git/HEAD": "junk"],
        folders: ["/r/.git"], cwd: "/r", branch: "from-git", gitCalls: 1),
    Tree(
        name: "a HEAD with a remote ref asks git",
        files: ["/r/.git/HEAD": "ref: refs/remotes/origin/x\n"], folders: ["/r/.git"], cwd: "/r",
        branch: "from-git", gitCalls: 1),
    Tree(
        name: "a HEAD with a hash of 39 digits asks git",
        files: ["/r/.git/HEAD": String(repeating: "c", count: 39)], folders: ["/r/.git"],
        cwd: "/r", branch: "from-git", gitCalls: 1),
    Tree(
        name: "a .git folder with no HEAD file asks git", folders: ["/r/.git"], cwd: "/r",
        branch: "from-git", gitCalls: 1),
    Tree(
        name: "a .git file with a gitdir",
        files: [
            "/w/.git": "gitdir: /r/.git/worktrees/w\n",
            "/r/.git/worktrees/w/HEAD": "ref: refs/heads/wt\n",
        ], cwd: "/w", branch: "wt"),
    Tree(
        name: "a .git file with a relative gitdir and CRLF",
        files: [
            "/w/.git": "gitdir: ../r/.git/worktrees/w\r\n",
            "/r/.git/worktrees/w/HEAD": "ref: refs/heads/wt\n",
        ], cwd: "/w", branch: "wt"),
    Tree(
        name: "a .git file with a gitdir and no HEAD file asks git",
        files: ["/w/.git": "gitdir: /r/.git/worktrees/w\n"], cwd: "/w", branch: "from-git",
        gitCalls: 1),
    Tree(
        name: "a .git file with no text asks git", files: ["/w/.git": ""], cwd: "/w",
        branch: "from-git", gitCalls: 1),
    Tree(
        name: "a .git file with an empty gitdir path asks git",
        files: ["/w/.git": "gitdir:   \n"], cwd: "/w", branch: "from-git", gitCalls: 1),
    Tree(
        name: "a .git file with the path on the next line asks git",
        files: ["/w/.git": "gitdir:\n/r/.git/worktrees/w\n", "/r/.git/worktrees/w/HEAD": "x"],
        cwd: "/w", branch: "from-git", gitCalls: 1),
    Tree(
        name: "a .git file with other text asks git", files: ["/w/.git": "nonsense\n"], cwd: "/w",
        branch: "from-git", gitCalls: 1),
    Tree(
        name: "a subfolder uses the .git folder above it",
        files: ["/r/.git/HEAD": "ref: refs/heads/main\n"], folders: ["/r/.git", "/r/a/b"],
        cwd: "/r/a/b", branch: "main"),
    Tree(
        name: "the nearest .git wins over a .git folder above it",
        files: [
            "/r/.git/HEAD": "ref: refs/heads/main\n",
            "/r/w/.git": "gitdir: /r/.git/worktrees/w\n",
            "/r/.git/worktrees/w/HEAD": "ref: refs/heads/wt\n",
        ], folders: ["/r/.git", "/r/w/sub"], cwd: "/r/w/sub", branch: "wt"),
    Tree(name: "no .git up to the root gives no branch", folders: ["/a/b"], cwd: "/a/b"),
    Tree(name: "the root folder with no .git gives no branch", folders: ["/a"], cwd: "/"),
    Tree(
        name: "a folder that does not exist gives no branch, and no parent is used",
        files: ["/r/.git/HEAD": "ref: refs/heads/main\n"], folders: ["/r/.git"], cwd: "/r/nope"),
    Tree(
        name: "a path of a file gives no branch",
        files: [
            "/r/.git/HEAD": "ref: refs/heads/main\n", "/r/file": "x",
        ], folders: ["/r/.git"], cwd: "/r/file"),
    Tree(
        name: "a relative folder is not found in the file system",
        files: ["/r/.git/HEAD": "ref: refs/heads/main\n"], folders: ["/r/.git"], cwd: "r"),
    Tree(
        name: "a folder in a skip root gives no branch, and no file read and no git",
        files: ["/rv/repos/acme/.git/HEAD": "ref: refs/heads/fix\n"],
        folders: ["/rv/repos/acme/.git"], cwd: "/rv/repos/acme", skipRoots: ["/rv/repos"]),
    Tree(
        name: "the skip root itself gives no branch", folders: ["/rv/repos"], cwd: "/rv/repos",
        skipRoots: ["/rv/repos"]),
    Tree(
        name: "a folder next to a skip root reads its HEAD file",
        files: ["/rv/repos-old/.git/HEAD": "ref: refs/heads/main\n"],
        folders: ["/rv/repos-old/.git"], cwd: "/rv/repos-old", skipRoots: ["/rv/repos"],
        branch: "main"),
    Tree(
        name: "a .git file that points into a skip root gives no branch and no git",
        files: [
            "/w/.git": "gitdir: /rv/repos/acme/.git/worktrees/w\n",
            "/rv/repos/acme/.git/worktrees/w/HEAD": "ref: refs/heads/fix\n",
        ], cwd: "/w", skipRoots: ["/rv/repos"]),
    Tree(
        name: "a second skip root also gives no branch",
        files: ["/q/.git/HEAD": "ref: refs/heads/main\n"], folders: ["/q/.git", "/q/sub"],
        cwd: "/q/sub", skipRoots: ["/rv/repos", "/q"]),
]

@Suite("the branch reader on small file trees")
struct BranchReaderEdgeTests {
    @Test("a tree gives its branch through the git commands", arguments: trees)
    fileprivate func read(tree: Tree) async {
        let fs = MemoryFileSystem(files: tree.files, folders: tree.folders)
        let runner = FakeRunner(ExecResult(.exited(0), stdout: "from-git\n"))
        let reader = BranchReader(runner: runner, fileSystem: fs, skipRoots: tree.skipRoots)
        #expect(await reader.read(tree.cwd) == tree.branch)
        #expect(runner.calls.count == tree.gitCalls)
    }

    @Test("a failed git command gives no branch")
    func gitFails() async {
        let fs = MemoryFileSystem(files: ["/r/.git/HEAD": "junk"], folders: ["/r/.git"])
        let runner = FakeRunner(ExecResult(.exited(128), stderr: "fatal"))
        #expect(await BranchReader(runner: runner, fileSystem: fs).read("/r") == nil)
        #expect(runner.calls.count == 1)
    }

    @Test("the cache follows the time of the HEAD file for each folder", arguments: [true, false])
    func cache(changes: Bool) async {
        let fs = MemoryFileSystem(
            files: ["/r/.git/HEAD": "ref: refs/heads/one\n"], folders: ["/r/.git", "/r/a"],
            mtimes: ["/r/.git/HEAD": 5])
        let reader = BranchReader(
            runner: FakeRunner(ExecResult(.exited(0), stdout: "from-git\n")), fileSystem: fs)
        #expect(await reader.read("/r") == "one")
        #expect(await reader.read("/r/a") == "one")
        #expect(fs.reads == ["/r/.git/HEAD", "/r/.git/HEAD"])
        // A change of the text with the same time is not seen. A new time reads the file again.
        fs.set("/r/.git/HEAD", text: "ref: refs/heads/two\n", mtime: changes ? 6 : 5)
        #expect(await reader.read("/r") == (changes ? "two" : "one"))
        #expect(fs.reads.count == (changes ? 3 : 2))
    }

    @Test
    func skipWinsOverHead() async {
        let files = ["/rv/repos/a/.git/HEAD": "ref: refs/heads/fix\n"]
        let fs = MemoryFileSystem(files: files, folders: ["/rv/repos/a/.git"])
        let runner = FakeRunner(ExecResult(.exited(0), stdout: "from-git\n"))
        let plain = BranchReader(runner: runner, fileSystem: fs)
        #expect(await plain.read("/rv/repos/a") == "fix")
        let skipping = BranchReader(runner: runner, fileSystem: fs, skipRoots: ["/rv/repos"])
        #expect(await skipping.read("/rv/repos/a") == nil)
        #expect(runner.calls.isEmpty)
    }

    // A .git link outside the reviews folder that points into it: the real path of the HEAD
    // folder is in the skip root, so the reader reads no HEAD file and runs no git. With no skip
    // root, the link gives the branch.
    @Test func aDotGitLinkIntoAReviewsFolderGivesNoBranchNoGitAndNoHeadRead() async {
        let fs = MemoryFileSystem(
            files: ["/rv/repos/acme/.git/HEAD": "ref: refs/heads/fix\n"],
            folders: ["/rv/repos/acme/.git", "/w"], links: ["/w/.git": "/rv/repos/acme/.git"])
        let runner = FakeRunner(ExecResult(.exited(0), stdout: "from-git\n"))
        let skipping = BranchReader(runner: runner, fileSystem: fs, skipRoots: ["/rv/repos"])
        #expect(await skipping.read("/w") == nil)
        #expect(runner.calls.isEmpty)
        #expect(fs.reads.isEmpty)
        #expect(await BranchReader(runner: runner, fileSystem: fs).read("/w") == "fix")
    }
}
