// The output of git merge-tree --name-only -z for a conflict round (docs/behaviour/reviews.md,
// "Merging the base branch").
import BifrostTestSupport
import Foundation
import Testing

@testable import BifrostReviews

private let tree = "f7698d38614ba22b41f996fab73124361d2fe389"

@Suite("the output of a merge for a conflict round", .testTimeLimit)
struct MergeTreeTests {
    // Exit code 1: the paths after the tree have a conflict. They come sorted, each one time.
    @Test func aMergeWithConflictsListsEachPathOnce() {
        let output = MergeTreeOutput.parse(
            "\(tree)\0src/b.swift\0a b.txt\0src/b.swift\0", exit: 1)
        #expect(output == MergeTreeOutput(tree: tree, conflicted: ["a b.txt", "src/b.swift"]))
        // A merge with conflicts must name a file.
        #expect(MergeTreeOutput.parse("\(tree)\0", exit: 1) == nil)
    }

    // Exit code 0: a clean merge has only the tree.
    @Test func aCleanMergeHasOnlyTheTree() {
        let clean = MergeTreeOutput(tree: tree, conflicted: [])
        #expect(MergeTreeOutput.parse("\(tree)\0", exit: 0) == clean)
        #expect(MergeTreeOutput.parse(tree, exit: 0) == clean)
        #expect(MergeTreeOutput.parse("\(tree)\0a.txt\0", exit: 0) == nil)
    }

    // A first field that is not an object ID, or another exit code, is not a merge.
    @Test func aBadTreeOrExitCodeIsNoMerge() {
        let short = String(tree.dropLast()) + "\0a.txt\0"
        for text in ["", "\0a.txt\0", "HEAD\0a.txt\0", "-x\0a.txt\0", short] {
            #expect(MergeTreeOutput.parse(text, exit: 1) == nil, "\(text)")
        }
        #expect(MergeTreeOutput.parse("\(tree)\0", exit: 128) == nil)
        #expect(MergeTreeOutput.parse("\(tree)\0a.txt\0", exit: 2) == nil)
    }
}
