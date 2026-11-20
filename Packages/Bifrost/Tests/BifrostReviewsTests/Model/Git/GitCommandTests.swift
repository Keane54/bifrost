// The closed set of git commands of Reviews (docs/behaviour/reviews.md, "Safety"). The push has
// one form with no force, no command signs, and a path never reads as an option.
import BifrostFoundation
import BifrostTestSupport
import Foundation
import Testing

@testable import BifrostReviews

private let head = "f7698d38614ba22b41f996fab73124361d2fe389"
private let other = String(repeating: "a", count: 40)

private func commit(_ hex: String = head) throws -> CommitID { try #require(CommitID(hex)) }
private func pr() throws -> PRKey { try #require(PRKey(text: "Owner-A/Repo-A#7")) }
private let layout = ReviewsLayout(
    folder: URL(filePath: "/Users/someone/.bifrost/reviews", directoryHint: .isDirectory))

private func push() throws -> GitPush {
    GitPush(commit: try commit(), branch: try #require(BranchName("fix/thing")))
}

// One sample of each case.
private func samples() throws -> [GitCommand] {
    let folder = URL(filePath: "/r/.bifrost-worktrees/7", directoryHint: .isDirectory)
    return [
        .clone(try #require(URL(string: "https://github.com/owner-a/repo-a.git"))),
        .fetch(refspec: "+refs/pull/7/head:refs/bifrost/pr/7"),
        .worktreeAdd(folder, try commit()), .worktreePrune, .resetHard(try commit()),
        .resetIndex(try commit()), .clean,
        .status, .add(["src/a.swift"]), .commit(message: "Fix the thing"),
        .mergeTree(base: try commit(), ours: try commit(other), theirs: try commit()),
        .mergeTreeNames(ours: try commit(other), theirs: try commit()),
        .writeTree,
        .commitTree(tree: other, parents: [try commit(), try commit(other)], message: "Merge"),
        .revParse("HEAD^{commit}"), .catFile(head), .blob(other),
        .configGetAll("remote.origin.url"), .remoteURLs(push: true),
        .treeEntries(try commit(), ["src/a.swift"]), .treeSizes(try commit(), ["src/a.swift"]),
        .lsFilesStage(["src/a.swift"]), .headTree, .checkAttrFilter(["src/a.swift"]),
        .hashObject("src/a.swift"), .diff(try commit(), try commit(other)),
        .pathDiff(try commit(), try commit(other), ["src/a.swift"]),
        .changedPaths(try commit(), try commit(other)), .push(try push()),
        .isAncestor(try commit(), of: try commit(other)), .revList(try commit(), max: 20),
        .mergeBase(try commit(), try commit(other)),
    ]
}

// The name of each case. The switch has no default, so a new case does not compile until it gets
// a name here and a sample above.
private func caseName(_ command: GitCommand) -> String {
    switch command {
    case .clone: "clone"
    case .fetch: "fetch"
    case .worktreeAdd: "worktreeAdd"
    case .worktreePrune: "worktreePrune"
    case .resetHard: "resetHard"
    case .resetIndex: "resetIndex"
    case .clean: "clean"
    case .status: "status"
    case .add: "add"
    case .commit: "commit"
    case .mergeTree: "mergeTree"
    case .mergeTreeNames: "mergeTreeNames"
    case .writeTree: "writeTree"
    case .commitTree: "commitTree"
    case .revParse: "revParse"
    case .catFile: "catFile"
    case .blob: "blob"
    case .configGetAll: "configGetAll"
    case .remoteURLs: "remoteURLs"
    case .treeEntries: "treeEntries"
    case .treeSizes: "treeSizes"
    case .lsFilesStage: "lsFilesStage"
    case .headTree: "headTree"
    case .checkAttrFilter: "checkAttrFilter"
    case .hashObject: "hashObject"
    case .diff: "diff"
    case .pathDiff: "pathDiff"
    case .changedPaths: "changedPaths"
    case .push: "push"
    case .isAncestor: "isAncestor"
    case .revList: "revList"
    case .mergeBase: "mergeBase"
    }
}

@Suite("the git commands of Reviews", .testTimeLimit)
struct GitCommandTests {
    @Test func eachCaseHasASample() throws {
        #expect(Set(try samples().map(caseName)).count == 32)
    }

    @Test func thePushHasOneFormAndNoForce() throws {
        #expect(
            GitCommand.push(try push()).arguments == [
                "-c", "push.gpgSign=false", "push", "--porcelain", "--no-follow-tags",
                "--recurse-submodules=no", "origin", "\(head):refs/heads/fix/thing",
            ])
        for command in try samples() {
            let args = command.arguments
            #expect(!args.contains { $0.lowercased().contains("force") }, "\(caseName(command))")
            #expect(!args.contains { $0.hasPrefix("--mirror") || $0.hasPrefix("--delete") })
            #expect(!args.contains("-f") && !args.contains("-d"), "\(caseName(command))")
            // Only the push command pushes.
            let pushes = args.contains("push") || args.contains("send-pack")
            #expect(pushes == (caseName(command) == "push"), "\(caseName(command))")
        }
    }

    @Test func noCommandSigns() throws {
        for command in try samples() {
            let args = command.arguments
            let signs = args.contains {
                $0 == "-S" || $0.hasPrefix("--gpg-sign") || $0.hasPrefix("--signed")
                    || $0.hasPrefix("-S") || $0.lowercased().hasSuffix("gpgsign=true")
            }
            #expect(!signs, "\(caseName(command))")
        }
        let made = GitCommand.commit(message: "Fix")
        #expect(
            made.arguments == [
                "commit", "--quiet", "--no-gpg-sign", "--no-verify", "--cleanup=whitespace", "-m",
                "Fix",
            ])
        let tree = GitCommand.commitTree(tree: other, parents: [try commit()], message: "M")
        #expect(
            tree.arguments == ["commit-tree", "--no-gpg-sign", "-p", head, "-m", "M", other])
        #expect(GitCommand.push(try push()).arguments.prefix(2) == ["-c", "push.gpgSign=false"])
    }

    // A partial clone can download a file from origin in any command (a checkout, a reset, a
    // diff, a merge), so each command gets the items that stop a prompt and ssh.
    @Test func everyCommandGetsTheNoPromptConfig() throws {
        let runner = FakeRunner(ExecResult(.exited(0)))
        let git = RepoGit(path: "git", environment: [:], layout: layout, runner: runner)
        #expect(
            RepoGit.networkConfig == [
                "-c", "core.askPass=", "-c", "protocol.ssh.allow=never", "-c",
                "protocol.allow=never", "-c", "protocol.https.allow=always",
            ])
        let items = RepoGit.config + RepoGit.networkConfig
        let newClone = URL(filePath: "/r/new", directoryHint: .isDirectory)
        for command in try samples() {
            let place: GitPlace =
                caseName(command) == "clone" ? .newClone(newClone) : .worktree(try pr())
            let args = git.arguments(for: command, in: place)
            #expect(Array(args.prefix(items.count)) == items, "\(caseName(command))")
            // Only the pin and the command come after the items, and neither can undo them.
            #expect(
                Array(args.dropFirst(items.count)) == place.arguments(layout) + command.arguments)
            let network = ["clone", "fetch", "push"].contains(caseName(command))
            #expect(command.usesNetwork == network, "\(caseName(command))")
        }
    }

    // Each command runs only at a place that pins its repository. A command that needs a work
    // tree runs only in a worktree, and the clone command only in a new folder.
    @Test func eachCommandRunsOnlyAtItsPlace() throws {
        let newClone = GitPlace.newClone(URL(filePath: "/r/new", directoryHint: .isDirectory))
        let clone = GitPlace.clone(try pr().repo)
        let worktree = GitPlace.worktree(try pr())
        let workTree: Set = [
            "resetHard", "resetIndex", "clean", "status", "add", "commit", "writeTree",
            "lsFilesStage", "headTree", "checkAttrFilter", "hashObject",
        ]
        for command in try samples() {
            let name = caseName(command)
            #expect(command.needsWorkTree == workTree.contains(name), "\(name)")
            #expect(newClone.allows(command) == (name == "clone"), "\(name)")
            #expect(clone.allows(command) == (name != "clone" && !workTree.contains(name)))
            #expect(worktree.allows(command) == (name != "clone"), "\(name)")
        }
        let root = "/Users/someone/.bifrost/reviews/repos/owner-a/repo-a"
        #expect(newClone.arguments(layout).isEmpty)
        #expect(newClone.folder(layout) == "/r/new")
        #expect(clone.arguments(layout) == ["--git-dir=\(root)/.git"])
        #expect(clone.folder(layout) == root)
        #expect(
            worktree.arguments(layout) == [
                "--git-dir=\(root)/.git/worktrees/7", "--work-tree=\(root)/.bifrost-worktrees/7",
            ])
        #expect(worktree.folder(layout) == "\(root)/.bifrost-worktrees/7")
    }

    @Test func aPathLikeAFlagIsNeverAdded() throws {
        #expect(
            GitCommand.add(["-A"]).arguments == ["--literal-pathspecs", "add", "-A", "--", "-A"])
        #expect(CommitFileRule.pathRefusal("-A") == .outside)
        #expect(
            GitCommand.lsFilesStage(["-x"]).arguments == [
                "--literal-pathspecs", "ls-files", "--stage", "-z", "--", "-x",
            ])
        #expect(
            GitCommand.checkAttrFilter(["-x"]).arguments == [
                "--literal-pathspecs", "check-attr", "-z", "filter", "--", "-x",
            ])
        #expect(
            GitCommand.hashObject("-x").arguments == ["hash-object", "--no-filters", "--", "-x"])
        // A text that is not a path ends the options first.
        #expect(
            GitCommand.revParse("-x").arguments == [
                "rev-parse", "--verify", "--quiet", "--end-of-options", "-x",
            ])
        #expect(
            GitCommand.catFile("-x").arguments == [
                "cat-file", "commit", "--end-of-options", "-x",
            ])
        #expect(
            GitCommand.configGetAll("-x").arguments == [
                "config", "--get-all", "--end-of-options", "-x",
            ])
        #expect(
            GitCommand.fetch(refspec: "-x").arguments == [
                "fetch", "--quiet", "--no-tags", "--no-recurse-submodules", "--", "origin", "-x",
            ])
        let folder = URL(filePath: "/r/-x", directoryHint: .isDirectory)
        #expect(
            GitCommand.worktreeAdd(folder, try commit()).arguments == [
                "worktree", "add", "--quiet", "--detach", "--", "/r/-x", head,
            ])
    }

    // git add with no path adds each change of the worktree, and a path that the rule refuses
    // never goes to git. commit-tree takes only an object ID as its tree.
    @Test func aCommandThatCouldReachOtherFilesIsRefused() throws {
        #expect(GitCommand.add([]).isRefused)
        let refused = ["-A", ".github/workflows/ci.yml", ".claude/x", ".git/config", "../x"]
        for path in refused + [".gitmodules"] {
            #expect(GitCommand.add(["ok.txt", path]).isRefused, "\(path)")
        }
        #expect(!GitCommand.add(["ok.txt", "src/a.swift"]).isRefused)
        #expect(GitCommand.commitTree(tree: "-x", parents: [], message: "M").isRefused)
        #expect(GitCommand.commitTree(tree: "HEAD", parents: [], message: "M").isRefused)
        #expect(!GitCommand.commitTree(tree: other, parents: [], message: "M").isRefused)
        for command in try samples() {
            #expect(!command.isRefused, "\(caseName(command))")
        }
    }

    // A session can write the folder of a submodule, so no command looks into one: status and
    // diff ignore the submodules, and the commands that could go into them say no.
    @Test func noCommandLooksIntoASubmodule() throws {
        let forms: [String: String] = [
            "status": "--ignore-submodules=all", "diff": "--ignore-submodules=all",
            "pathDiff": "--ignore-submodules=all",
            "resetHard": "--no-recurse-submodules", "resetIndex": "--no-recurse-submodules",
            "fetch": "--no-recurse-submodules",
            "push": "--recurse-submodules=no",
        ]
        for command in try samples() {
            guard let flag = forms[caseName(command)] else { continue }
            #expect(command.arguments.contains(flag), "\(caseName(command))")
        }
        #expect(RepoGit.config.contains("submodule.recurse=false"))
    }

    @Test func theAncestorAndRevListFormsAreExact() throws {
        #expect(
            GitCommand.isAncestor(try commit(), of: try commit(other)).arguments == [
                "merge-base", "--is-ancestor", head, other,
            ])
        #expect(
            GitCommand.mergeBase(try commit(), try commit(other)).arguments == [
                "merge-base", head, other,
            ])
        #expect(
            GitCommand.revList(try commit(), max: 20).arguments == [
                "rev-list", "--parents", "--max-count=20", head,
            ])
        // A count below 1 never lists the whole history.
        #expect(
            GitCommand.revList(try commit(), max: -1).arguments == [
                "rev-list", "--parents", "--max-count=1", head,
            ])
    }

    // The checks of a push target read the addresses of origin from the config only, and the
    // signed push reads the entries of a commit at its literal paths.
    @Test func theRemoteAndTreeFormsAreExact() throws {
        #expect(
            GitCommand.remoteURLs(push: false).arguments == [
                "remote", "get-url", "--all", "origin",
            ])
        #expect(
            GitCommand.remoteURLs(push: true).arguments == [
                "remote", "get-url", "--push", "--all", "origin",
            ])
        #expect(
            GitCommand.treeEntries(try commit(), ["-a", "src/*.swift"]).arguments == [
                "--literal-pathspecs", "ls-tree", "-r", "-z", "--full-tree", head, "--", "-a",
                "src/*.swift",
            ])
        #expect(
            GitCommand.treeSizes(try commit(), ["-a"]).arguments == [
                "--literal-pathspecs", "ls-tree", "-r", "-z", "-l", "--full-tree", head, "--", "-a",
            ])
        #expect(!GitCommand.remoteURLs(push: true).usesNetwork)
        #expect(!GitCommand.treeEntries(try commit(), []).needsWorkTree)
        #expect(!GitCommand.treeSizes(try commit(), []).needsWorkTree)
    }

    // The signed push reads the bytes of a blob as git keeps them, and the check of a fix commit
    // lists the changed paths of two commits. Neither needs a work tree. The list of the paths
    // has each submodule entry: it compares two trees, so git reads no folder of a submodule.
    @Test func theBlobAndChangedPathFormsAreExact() throws {
        #expect(GitCommand.blob(other).arguments == ["cat-file", "blob", "--end-of-options", other])
        #expect(
            GitCommand.changedPaths(try commit(), try commit(other)).arguments == [
                "diff", "--no-ext-diff", "--no-textconv", "--no-renames",
                "--ignore-submodules=none", "--name-only", "-z", head, other, "--",
            ])
        #expect(!GitCommand.blob(other).needsWorkTree && !GitCommand.blob(other).usesNetwork)
        #expect(!GitCommand.changedPaths(try commit(), try commit(other)).needsWorkTree)
    }

    @Test func theOtherFormsAreExact() throws {
        #expect(
            GitCommand.clone(try #require(URL(string: "https://github.com/o/r.git"))).arguments == [
                "clone", "--quiet", "--no-checkout", "--filter=blob:none", "--origin", "origin",
                "--template=", "--", "https://github.com/o/r.git", ".",
            ])
        #expect(GitCommand.worktreePrune.arguments == ["worktree", "prune"])
        #expect(
            GitCommand.resetHard(try commit()).arguments == [
                "reset", "--hard", "--quiet", "--no-recurse-submodules", head, "--",
            ])
        #expect(
            GitCommand.resetIndex(try commit()).arguments == [
                "reset", "--mixed", "--quiet", "--no-recurse-submodules", head, "--",
            ])
        #expect(GitCommand.headTree.arguments == ["ls-tree", "-r", "-z", "--full-tree", "HEAD"])
        #expect(GitCommand.clean.arguments == ["clean", "-ffdx", "--quiet"])
        #expect(
            GitCommand.status.arguments == [
                "--no-optional-locks", "status", "--porcelain=v1", "-z", "--untracked-files=all",
                "--no-renames", "--ignore-submodules=all",
            ])
        #expect(
            GitCommand.mergeTree(base: try commit(), ours: try commit(other), theirs: try commit())
                .arguments == [
                    "merge-tree", "--write-tree", "--no-messages", "--merge-base=\(head)", other,
                    head,
                ])
        #expect(
            GitCommand.diff(try commit(), try commit(other)).arguments == [
                "diff", "--no-ext-diff", "--no-textconv", "--no-color", "--find-renames",
                "--ignore-submodules=all", "--src-prefix=a/", "--dst-prefix=b/", head, other,
                "--",
            ])
    }

    // A conflict round reads only the names of the conflicted files, each with a NUL after it,
    // and no message of git. git finds each merge base itself, as git merge does. The command
    // reads trees only, so it needs no work tree.
    @Test func theMergeTreeNamesCommandListsOnlyNames() throws {
        let command = GitCommand.mergeTreeNames(ours: try commit(other), theirs: try commit())
        #expect(
            command.arguments == [
                "merge-tree", "--write-tree", "--name-only", "-z", "--no-messages", other, head,
            ])
        #expect(!command.needsWorkTree && !command.usesNetwork && !command.isRefused)
    }

    // write-tree reads the index of the worktree, so it runs only in a worktree.
    @Test func writeTreeNeedsAWorkTree() throws {
        #expect(GitCommand.writeTree.arguments == ["write-tree"])
        #expect(GitCommand.writeTree.needsWorkTree && !GitCommand.writeTree.usesNetwork)
        #expect(!GitPlace.clone(try pr().repo).allows(.writeTree))
        #expect(GitPlace.worktree(try pr()).allows(.writeTree))
    }

    // The diff of some paths has the flags of the full diff, and each path comes after "--" as a
    // literal path: a path like a flag or a pattern is only a path.
    @Test func aPathDiffTakesLiteralPaths() throws {
        let command = GitCommand.pathDiff(try commit(), try commit(other), ["-a", "src/*.swift"])
        #expect(
            command.arguments == [
                "--literal-pathspecs", "diff", "--no-ext-diff", "--no-textconv", "--no-color",
                "--find-renames", "--ignore-submodules=all", "--src-prefix=a/", "--dst-prefix=b/",
                head, other, "--", "-a", "src/*.swift",
            ])
        #expect(!command.needsWorkTree && !command.usesNetwork && !command.isRefused)
    }
}
