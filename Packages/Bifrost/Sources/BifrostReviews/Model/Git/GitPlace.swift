// Where a git command of Reviews runs (docs/behaviour/reviews.md, "Running git"). RepoGit pins the
// repository of each command with --git-dir (and --work-tree in a worktree). It computes each
// path from ReviewsLayout, never from a .git file: a session can write the .git file of its
// worktree, and git would then use the repository, the work tree, the config and the filters
// that the file names. With --git-dir, git also never searches the folders above for a
// repository.
import Foundation

package enum GitPlace: Sendable, Equatable {
    // An empty folder that gets a new clone. Only the clone command runs here.
    case newClone(URL)
    // Bifrost's clone of the repository: --git-dir=<clone>/.git, in the clone folder, with no
    // work tree. A command that needs a work tree never runs here, because the clone folder also
    // holds the worktrees and the input folders.
    case clone(RepoName)
    // The worktree of the PR: --git-dir=<clone>/.git/worktrees/<number> (the admin folder of the
    // worktree) and --work-tree=<worktree>, in the worktree.
    case worktree(PRKey)

    // True when the command can run at this place.
    package func allows(_ command: GitCommand) -> Bool {
        switch (self, command) {
        case (.newClone, .clone): true
        case (.newClone, _), (_, .clone): false
        case (.clone, _): !command.needsWorkTree
        case (.worktree, _): true
        }
    }

    // The folder of the run.
    package func folder(_ layout: ReviewsLayout) -> String {
        switch self {
        case .newClone(let folder): folder.plainPath
        case .clone(let repo): layout.clone(repo).plainPath
        case .worktree(let pr): Self.worktree(pr, layout)
        }
    }

    // The global options that pin the repository. A new clone has none: git clone makes its
    // repository in the folder of the run.
    package func arguments(_ layout: ReviewsLayout) -> [String] {
        switch self {
        case .newClone: []
        case .clone(let repo): ["--git-dir=\(Self.gitFolder(repo, layout))"]
        case .worktree(let pr):
            [
                "--git-dir=\(Self.adminFolder(pr, layout))",
                "--work-tree=\(Self.worktree(pr, layout))",
            ]
        }
    }

    // <clone>/.git
    package static func gitFolder(_ repo: RepoName, _ layout: ReviewsLayout) -> String {
        layout.clone(repo).plainPath + "/.git"
    }

    // <clone>/.git/worktrees/<number>: git names the admin folder of a worktree after the last
    // part of its path (ReviewsLayout.worktree ends with the number).
    package static func adminFolder(_ pr: PRKey, _ layout: ReviewsLayout) -> String {
        gitFolder(pr.repo, layout) + "/worktrees/\(pr.number)"
    }

    // <clone>/.bifrost-worktrees/<number>
    package static func worktree(_ pr: PRKey, _ layout: ReviewsLayout) -> String {
        layout.worktree(pr.repo, number: pr.number).plainPath
    }
}

extension URL {
    // The path with no "/" at the end, so git names a worktree after its last part.
    var plainPath: String {
        let path = path(percentEncoded: false)
        return path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
    }
}
