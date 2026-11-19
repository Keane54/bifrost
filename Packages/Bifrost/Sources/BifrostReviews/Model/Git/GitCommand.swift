// Each git command of Reviews, and nothing else (docs/behaviour/reviews.md, "Safety"). RepoGit
// runs only these cases, with the safe config items before them. The push has one form: a fast
// forward of one commit to one branch, with no force, no delete and no other ref. No command
// signs, and no command has the word "force": a worktree goes with worktreePrune after its folder
// goes. Each list of paths comes after "--", and each other text that is not an ID comes after
// --end-of-options, so a text can never read as an option. No command looks into a submodule
// folder, which a session can write: status and diff ignore the submodules, and reset does not
// go into them (RepoGit also refuses add and commit in a worktree with a submodule).
import Foundation

// The target of a push: one commit to one branch of origin.
package struct GitPush: Sendable, Equatable {
    package let commit: CommitID
    package let branch: BranchName

    package init(commit: CommitID, branch: BranchName) {
        self.commit = commit
        self.branch = branch
    }
}

package enum GitCommand: Sendable, Equatable {
    // A clone into the folder of the run, with no checkout and no blobs (a partial clone).
    case clone(URL)
    // One refspec from origin, with no tags.
    case fetch(refspec: String)
    // A detached worktree at the commit.
    case worktreeAdd(URL, CommitID)
    case worktreePrune
    case resetHard(CommitID)
    // Remove each file that git does not track, also the ignored files and the nested clones.
    case clean
    // Each change of the worktree, also each new file, one entry for each path. The ignored files
    // are not listed: git add refuses them, and an ignored folder can hold very many files. The
    // submodules are not looked at: git would run the status of a submodule in its folder, with
    // the config and the filters of that folder.
    case status
    // Add these paths to the index. A path is a literal path, never a pattern.
    case add([String])
    // Commit the index with the message, with the identity of the user. It never signs.
    case commit(message: String)
    // The tree of a merge of ours and theirs, with no worktree and no hook.
    case mergeTree(base: CommitID, ours: CommitID, theirs: CommitID)
    // A commit of a tree with these parents. It never signs.
    case commitTree(tree: String, parents: [CommitID], message: String)
    // The commit ID of a revision, for example refs/bifrost/pr/7^{commit}.
    case revParse(String)
    // The raw form of a commit: its tree, its parents and its message.
    case catFile(String)
    // The bytes of a blob as git keeps them: no filter, no change of the line ends and no other
    // attribute. RepoGit keeps the bytes of its stdout (ExecResult.stdoutBytes).
    case blob(String)
    // Each value of a config key, for example remote.origin.url.
    case configGetAll(String)
    // Each address of origin that git fetches from, or pushes to with push, after the insteadOf
    // and pushInsteadOf rules of the config. git reads only the config: nothing reaches origin.
    case remoteURLs(push: Bool)
    // The mode, the object and the stage of each path in the index. An empty list gives each
    // entry of the index.
    case lsFilesStage([String])
    // The mode, the type, the object and the path of each entry of the tree of HEAD, at each depth.
    case headTree
    // The mode, the type, the object and the path of each entry of the tree of a commit at the
    // paths, at each depth. A path is a literal path, never a pattern.
    case treeEntries(CommitID, [String])
    // The same entries with the size of each blob. git reads each blob for its size, so the
    // blobs must be in the clone (the files of a fix commit).
    case treeSizes(CommitID, [String])
    // The value of the filter attribute of each path.
    case checkAttrFilter([String])
    // The blob ID of the bytes of a file of the worktree, with no filter.
    case hashObject(String)
    // The diff from the first commit to the second one, with fixed prefixes.
    case diff(CommitID, CommitID)
    // The path of each entry that changed from the first commit to the second one, with no
    // rename (a rename gives both paths) and with each submodule entry.
    case changedPaths(CommitID, CommitID)
    case push(GitPush)
    // True (exit 0) when the first commit is an ancestor of the second one, or the same commit.
    case isAncestor(CommitID, of: CommitID)
    // The best common ancestor of two commits: the start of the full diff of a PR.
    case mergeBase(CommitID, CommitID)
    // The newest commits from the commit, each with its parents, for the lookup of the commit
    // that GitHub made for a signed fix.
    case revList(CommitID, max: Int)

    // The argv after the config items of RepoGit.
    package var arguments: [String] {
        switch self {
        case .clone(let url):
            [
                "clone", "--quiet", "--no-checkout", "--filter=blob:none", "--origin", "origin",
                "--template=", "--", url.absoluteString, ".",
            ]
        case .fetch(let refspec):
            ["fetch", "--quiet", "--no-tags", "--no-recurse-submodules", "--", "origin", refspec]
        case .worktreeAdd(let folder, let commit):
            ["worktree", "add", "--quiet", "--detach", "--", folder.plainPath, commit.hex]
        case .worktreePrune: ["worktree", "prune"]
        case .resetHard(let commit):
            ["reset", "--hard", "--quiet", "--no-recurse-submodules", commit.hex]
        case .clean: ["clean", "-ffdx", "--quiet"]
        case .status:
            [
                "--no-optional-locks", "status", "--porcelain=v1", "-z", "--untracked-files=all",
                "--no-renames", "--ignore-submodules=all",
            ]
        case .add(let paths): ["--literal-pathspecs", "add", "-A", "--"] + paths
        case .commit(let message):
            [
                "commit", "--quiet", "--no-gpg-sign", "--no-verify", "--cleanup=whitespace", "-m",
                message,
            ]
        case .mergeTree(let base, let ours, let theirs):
            [
                "merge-tree", "--write-tree", "--no-messages", "--merge-base=\(base.hex)", ours.hex,
                theirs.hex,
            ]
        case .commitTree(let tree, let parents, let message):
            ["commit-tree", "--no-gpg-sign"] + parents.flatMap { ["-p", $0.hex] }
                + ["-m", message, tree]
        case .revParse(let revision):
            ["rev-parse", "--verify", "--quiet", "--end-of-options", revision]
        case .catFile(let object): ["cat-file", "commit", "--end-of-options", object]
        case .blob(let object): ["cat-file", "blob", "--end-of-options", object]
        case .configGetAll(let key): ["config", "--get-all", "--end-of-options", key]
        case .remoteURLs(let push):
            ["remote", "get-url"] + (push ? ["--push"] : []) + ["--all", "origin"]
        case .lsFilesStage(let paths):
            ["--literal-pathspecs", "ls-files", "--stage", "-z", "--"] + paths
        case .headTree: ["ls-tree", "-r", "-z", "--full-tree", "HEAD"]
        case .treeEntries(let commit, let paths):
            ["--literal-pathspecs", "ls-tree", "-r", "-z", "--full-tree", commit.hex, "--"] + paths
        case .treeSizes(let commit, let paths):
            ["--literal-pathspecs", "ls-tree", "-r", "-z", "-l", "--full-tree", commit.hex, "--"]
                + paths
        case .checkAttrFilter(let paths):
            ["--literal-pathspecs", "check-attr", "-z", "filter", "--"] + paths
        case .hashObject(let path): ["hash-object", "--no-filters", "--", path]
        case .diff(let from, let to):
            [
                "diff", "--no-ext-diff", "--no-textconv", "--no-color", "--find-renames",
                "--ignore-submodules=all", "--src-prefix=a/", "--dst-prefix=b/", from.hex, to.hex,
                "--",
            ]
        case .changedPaths(let from, let to):
            [
                "diff", "--no-ext-diff", "--no-textconv", "--no-renames",
                "--ignore-submodules=none", "--name-only", "-z", from.hex, to.hex, "--",
            ]
        case .push(let target):
            [
                "-c", "push.gpgSign=false", "push", "--porcelain", "--no-follow-tags",
                "--recurse-submodules=no", "origin",
                "\(target.commit.hex):refs/heads/\(target.branch.text)",
            ]
        case .isAncestor(let commit, let descendant):
            ["merge-base", "--is-ancestor", commit.hex, descendant.hex]
        case .mergeBase(let first, let second): ["merge-base", first.hex, second.hex]
        case .revList(let commit, let max):
            // A count below 1 would list the whole history.
            ["rev-list", "--parents", "--max-count=\(Swift.max(max, 1))", commit.hex]
        }
    }

    // True for the commands that read or change the files of a work tree. They run only in a
    // worktree (GitPlace.worktree).
    package var needsWorkTree: Bool {
        switch self {
        case .resetHard, .clean, .status, .add, .commit, .lsFilesStage, .headTree,
            .checkAttrFilter, .hashObject:
            true
        default: false
        }
    }

    // True for the commands that always reach origin. In a partial clone, the other commands can
    // also download a file from origin, so RepoGit gives the network items to each command.
    package var usesNetwork: Bool {
        switch self {
        case .clone, .fetch, .push: true
        default: false
        }
    }

    // A command that RepoGit never runs: git add with no path (it adds each change of the
    // worktree), git add of a path that CommitFileRule refuses, and commit-tree of a tree that is
    // not an object ID (a text that starts with "-" would read as an option).
    package var isRefused: Bool {
        switch self {
        case .add(let paths):
            paths.isEmpty || paths.contains { CommitFileRule.pathRefusal($0) != nil }
        case .commitTree(let tree, _, _): !CommitID.isObjectID(tree)
        default: false
        }
    }
}
