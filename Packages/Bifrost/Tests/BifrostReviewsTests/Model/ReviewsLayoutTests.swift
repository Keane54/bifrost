import Foundation
import Testing

@testable import BifrostReviews

// The folders of Reviews and the names of the repositories that they are made from.

private let folder = URL(fileURLWithPath: "/Users/someone/.bifrost/reviews", isDirectory: true)

private func repo(_ text: String) throws -> RepoName {
    try #require(RepoName(text))
}

@Suite("reviews layout", .timeLimit(.minutes(1)))
struct ReviewsLayoutTests {
    @Test func theCloneIsInLowerCase() throws {
        let layout = ReviewsLayout(folder: folder)
        let name = try repo("Owner-A/Repo.B")
        #expect(layout.clone(name).path == "/Users/someone/.bifrost/reviews/repos/owner-a/repo.b")
        #expect(name.key == "owner-a/repo.b")
        #expect(name.description == "Owner-A/Repo.B")
    }

    @Test func aNameThatCouldLeaveTheFolderIsRefused() {
        let refused = [
            ".", "..", "a/b", "-x", "", String(repeating: "a", count: 101), "é", "a\u{0}b", "a b",
        ]
        for part in refused {
            #expect(RepoName(owner: part, name: "ok") == nil, "owner \(part.debugDescription)")
            #expect(RepoName(owner: "ok", name: part) == nil, "name \(part.debugDescription)")
        }
        #expect(RepoName("owner") == nil)
        #expect(RepoName("a/b/c") == nil)
        #expect(RepoName("a/") == nil)
        #expect(RepoName(owner: String(repeating: "a", count: 100), name: "a.b_c-d") != nil)
        #expect(RepoName(owner: "a-", name: "...") != nil)
    }

    @Test func theWorktreeAndTheInputFolderAreBelowTheClone() throws {
        let layout = ReviewsLayout(folder: folder)
        let name = try repo("Owner-A/Repo-A")
        let clone = layout.clone(name).path
        #expect(layout.worktree(name, number: 7).path == "\(clone)/.bifrost-worktrees/7")
        #expect(layout.inputFolder(name, number: 7).path == "\(clone)/.bifrost-io/7")
    }

    @Test func theStateFileTheCopyAndTheLockAreInTheReviewsFolder() {
        let layout = ReviewsLayout(folder: folder)
        #expect(layout.stateFile.path == "\(folder.path)/state.json")
        #expect(layout.stateCopy.path == "\(folder.path)/state.json.before-native")
        #expect(layout.lockFile.path == "\(folder.path)/.lock")
        #expect(layout.reposRoot.path == "\(folder.path)/repos")
    }

    @Test func namesSortByTheirKey() throws {
        #expect(try repo("B/x") > repo("a/z"))
    }

    // GitHub names have no case: two spellings are one repository, in a set and in a compare.
    @Test func twoSpellingsOfOneNameAreEqual() throws {
        let upper = try repo("Owner-A/Repo.B")
        let lower = try repo("owner-a/repo.b")
        #expect(upper == lower)
        #expect(Set([upper, lower]).count == 1)
        #expect(!(upper < lower) && !(lower < upper))
        #expect(upper.description == "Owner-A/Repo.B")
    }
}
