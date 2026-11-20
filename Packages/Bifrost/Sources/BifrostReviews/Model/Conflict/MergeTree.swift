// The merge of the base branch into the head of a PR of the user, for a conflict round
// (docs/behaviour/reviews.md, "Merging the base branch"). git merge-tree makes the merge in the
// clone, with no worktree and no hook, and lists each path that has a conflict
// (GitCommand.mergeTreeNames). MergeTreeOutput reads that output. MergeStart keeps the merge with
// its conflict markers, which Claude resolves.
import Foundation

// The output of git merge-tree --write-tree --name-only -z: the object ID of the tree of the
// merge, then the path of each file that has a conflict, each with a NUL after it. In the tree, a
// file that has a conflict holds the conflict markers.
package struct MergeTreeOutput: Sendable, Equatable {
    package var tree: String
    // The paths that have a conflict, sorted, each one time. Empty for a clean merge.
    package var conflicted: [String]

    package init(tree: String, conflicted: [String]) {
        self.tree = tree
        self.conflicted = conflicted
    }

    // The output for the exit code of git: 0 is a clean merge, and 1 is a merge with conflicts.
    // nil for a first field that is not an object ID, a clean merge that lists a path, a merge
    // with conflicts that lists no path, and each other exit code.
    package static func parse(_ stdout: String, exit: Int32) -> MergeTreeOutput? {
        let fields = stdout.split(separator: "\0", omittingEmptySubsequences: false)
        guard let first = fields.first, CommitID.isObjectID(String(first)) else { return nil }
        let paths = Set(fields.dropFirst().filter { !$0.isEmpty }.map(String.init)).sorted()
        switch exit {
        case 0 where paths.isEmpty: return MergeTreeOutput(tree: String(first), conflicted: [])
        case 1 where !paths.isEmpty:
            return MergeTreeOutput(tree: String(first), conflicted: paths)
        default: return nil
        }
    }
}

// The start of a conflict round (ConflictMerge.start): the commit of the merge with the conflict
// markers ("auto"), whose parents are the head and the base, and the paths that have a conflict.
// Claude resolves the conflicts in the worktree at auto.
package struct MergeStart: Sendable, Equatable {
    // The most conflicted files of a round. A merge with more never goes to Claude.
    package static let maxFiles = 50

    package var auto: CommitID
    package var conflicted: [String]

    package init(auto: CommitID, conflicted: [String]) {
        self.auto = auto
        self.conflicted = conflicted
    }
}
