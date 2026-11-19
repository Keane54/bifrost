import Foundation

// The folders of Reviews, in the layout of the Electron app (the native app takes them over in
// place: docs/behaviour/import.md). Each value is a path only: no call reads a file.
package struct ReviewsLayout: Sendable, Equatable {
    // SharedClaudeState.reviewsFolder.
    package let folder: URL

    // The folders of the worktrees and of the input folders of the PRs, in each clone.
    package static let worktreesFolder = ".bifrost-worktrees"
    package static let ioFolder = ".bifrost-io"

    package init(folder: URL) {
        self.folder = folder
    }

    // <folder>/state.json
    package var stateFile: URL {
        folder.appending(path: "state.json", directoryHint: .notDirectory)
    }
    // <folder>/state.json.before-native: the safety copy of the first start of the native app.
    package var stateCopy: URL {
        folder.appending(path: "state.json.before-native", directoryHint: .notDirectory)
    }
    // <folder>/.lock
    package var lockFile: URL { folder.appending(path: ".lock", directoryHint: .notDirectory) }
    // <folder>/repos
    package var reposRoot: URL { folder.appending(path: "repos", directoryHint: .isDirectory) }

    // repos/<owner>/<name> in lower case.
    package func clone(_ repo: RepoName) -> URL {
        reposRoot.appending(path: repo.key, directoryHint: .isDirectory)
    }

    // <clone>/.bifrost-worktrees/<number>
    package func worktree(_ repo: RepoName, number: Int) -> URL {
        clone(repo).appending(path: Self.worktreesFolder, directoryHint: .isDirectory)
            .appending(path: String(number), directoryHint: .isDirectory)
    }

    // <clone>/.bifrost-io/<number>
    package func inputFolder(_ repo: RepoName, number: Int) -> URL {
        clone(repo).appending(path: Self.ioFolder, directoryHint: .isDirectory)
            .appending(path: String(number), directoryHint: .isDirectory)
    }
}
