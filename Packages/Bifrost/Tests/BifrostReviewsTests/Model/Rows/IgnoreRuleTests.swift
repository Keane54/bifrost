import Foundation
import Testing

@testable import BifrostReviews

// The ignore list of Reviews (docs/behaviour/reviews.md, "The rows"): owner/repo or owner/*.

private typealias R = Rows

private func entries(_ texts: String...) throws -> [IgnoreEntry] {
    try texts.map { try #require(IgnoreEntry($0)) }
}

@Suite("the ignore list", .timeLimit(.minutes(1)))
struct IgnoreRuleTests {
    @Test func anIgnoredRepoShowsNoRow() throws {
        var state = R.turnedOn()
        let toReview = [
            try R.pull("Owner-A/Repo-A#1"), try R.pull("owner-a/repo-b#2"),
            try R.pull("owner-b/repo-d#3"),
        ]
        let mine = [try R.pull("owner-b/Repo-C#4"), try R.pull("owner-c/repo-d#5")]
        let answer = R.answer(toReview: toReview, mine: mine)
        state.recordPoll(answer, now: R.now)
        var config = ReviewsConfig()
        config.ignore = try entries("owner-a/*", "OWNER-B/repo-c")
        #expect(try R.toReview(answer, state, config).map(\.id) == [R.key("owner-b/repo-d#3")])
        #expect(try R.mine(answer, state, config).map(\.id) == [R.key("owner-c/repo-d#5")])

        #expect(try IgnoreRule.matches(entries("owner-a/*"), #require(RepoName("OWNER-A/x"))))
        #expect(try !IgnoreRule.matches(entries("owner-a/x"), #require(RepoName("owner-a/xy"))))
        #expect(try !IgnoreRule.matches(entries("owner-a/*"), #require(RepoName("owner-ab/x"))))
        #expect(try !IgnoreRule.matches([], #require(RepoName("owner-a/x"))))
    }

    @Test func anEntryKeepsItsCleanForm() {
        #expect(IgnoreEntry(" Acme/API ")?.text == "acme/api")
        #expect(IgnoreEntry("ACME/*")?.text == "acme/*")
        #expect(IgnoreEntry("\tteam/tools\n")?.text == "team/tools")
        #expect(IgnoreEntry(String(repeating: "a", count: 39) + "/r") != nil)
        #expect(IgnoreEntry("o/" + String(repeating: "r", count: 100)) != nil)
        #expect(IgnoreEntry("acme/API") == IgnoreEntry("acme/api"))
        for bad in [
            "bad", "a/b/c", "-acme/x", "acme/", "/x", "*/x", "ac me/x", "acme/x y",
            String(repeating: "a", count: 40) + "/r", "o/" + String(repeating: "r", count: 101),
            "o/**", "a.b/x", "\u{E9}/x", "a/\nb", "",
        ] {
            #expect(IgnoreEntry(bad) == nil, "\(bad)")
        }
    }

    @Test func theIgnoreRuleRefusesABadEntryWithItsReason() throws {
        #expect(IgnoreRule.refusal("owner-a/repo-a") == nil)
        #expect(IgnoreRule.refusal("owner-a") == "Use owner/repo or owner/*.")
        #expect(IgnoreRule.refusal("owner-a/repo/x") == "Use owner/repo or owner/*.")
        let list = try entries("owner-a/repo-a")
        #expect(
            IgnoreRule.refusal(" OWNER-A/Repo-A", list: list)
                == "That repository is already in the list.")
        let full = try (0..<50).map { try #require(IgnoreEntry("owner-a/r\($0)")) }
        #expect(IgnoreRule.refusal("owner-b/*", list: full) == "You can keep up to 50 entries.")
        #expect(IgnoreRule.refusal("owner-b/*", list: Array(full.prefix(49))) == nil)
    }
}
