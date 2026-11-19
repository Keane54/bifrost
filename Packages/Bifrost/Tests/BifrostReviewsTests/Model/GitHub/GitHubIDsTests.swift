// The IDs of the safety surface (docs/behaviour/reviews.md, "Safety"): the PR key, the commit ID,
// the branch name and the node ID. Each init refuses each text that could change the target of a
// write.
import BifrostTestSupport
import Foundation
import Testing

@testable import BifrostReviews

private let head = "f7698d38614ba22b41f996fab73124361d2fe389"

@Suite("the GitHub IDs", .testTimeLimit)
struct GitHubIDsTests {
    @Test func onlyAGitHubPullRequestAddressGivesAKey() throws {
        let key = try #require(PRKey(url: "https://github.com/Owner-A/Repo.B/pull/42"))
        #expect(key.repo == RepoName("owner-a/repo.b"))
        #expect(key.number == 42)
        #expect(key.text == "Owner-A/Repo.B#42")
        #expect(key.webURL.absoluteString == "https://github.com/Owner-A/Repo.B/pull/42")
        let refused = [
            "http://github.com/o/r/pull/1", "https://gitlab.com/o/r/pull/1",
            "https://www.github.com/o/r/pull/1", "https://GitHub.com/o/r/pull/1",
            "https://github.com/o/r/pull/1/files", "https://github.com/o/r/fork/pull/1",
            "https://github.com/o/pull/1", "https://github.com/o/r/pull/1?tab=files",
            "https://github.com/o/r/pull/1#discussion", "https://github.com/o/r/pull/1/",
            "https://github.com/o/r/pull/0", "https://github.com/o/r/pull/01",
            "https://github.com/o/r/pull/-1", "https://github.com/o/r/pull/+1",
            "https://github.com/o/r/pull/12345678901", "https://github.com/o/r/issues/1",
            "https://github.com/o/../pull/1", "https://github.com/-o/r/pull/1",
            "https://user@github.com/o/r/pull/1", "https://github.com:443/o/r/pull/1",
            "https://github.com/o%2Fx/r/pull/1", " https://github.com/o/r/pull/1", "",
        ]
        for url in refused {
            #expect(PRKey(url: url) == nil, "\(url.debugDescription)")
        }
    }

    @Test func aPRKeyKeepsGitHubsCaseAndComparesWithNoCase() throws {
        let upper = try #require(PRKey(text: "Owner-A/Repo-A#7"))
        let lower = try #require(PRKey(text: "owner-a/repo-a#7"))
        #expect(upper.text == "Owner-A/Repo-A#7")
        #expect(lower.text == "owner-a/repo-a#7")
        #expect(upper == lower)
        #expect(Set([upper, lower]).count == 1)
        #expect(!(upper < lower) && !(lower < upper))
        let other = try #require(PRKey(text: "owner-a/repo-a#8"))
        #expect(upper < other)
        #expect(try #require(PRKey(text: "A/b#9")) < other)
        for text in ["o/r", "o/r#", "o/r#0", "o/r#x", "o#1", "o/r/x#1", "o/r#1#2", "o/r# 1"] {
            #expect(PRKey(text: text) == nil, "\(text.debugDescription)")
        }
    }

    @Test func aPRKeyCodesAsItsStateKeyText() throws {
        let key = try #require(PRKey(text: "Owner-A/Repo-A#7"))
        let data = try JSONEncoder().encode([key])
        #expect(String(decoding: data, as: UTF8.self) == #"["Owner-A\/Repo-A#7"]"#)
        #expect(try JSONDecoder().decode([PRKey].self, from: data) == [key])
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode([PRKey].self, from: Data(#"["o/r#0"]"#.utf8))
        }
    }

    @Test func aRepoNameCodesAsOwnerSlashName() throws {
        let name = try #require(RepoName("Owner-A/Repo.B"))
        let data = try JSONEncoder().encode([name])
        #expect(String(decoding: data, as: UTF8.self) == #"["Owner-A\/Repo.B"]"#)
        let decoded = try JSONDecoder().decode([RepoName].self, from: data)
        #expect(decoded.first?.description == "Owner-A/Repo.B")
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode([RepoName].self, from: Data(#"["a/b/c"]"#.utf8))
        }
    }

    @Test func aCommitIDIsFullLowerCaseHex() throws {
        let commit = try #require(CommitID(head))
        #expect(commit.hex == head)
        #expect(commit.short == "f7698d3")
        #expect(CommitID(String(repeating: "a", count: 64)) != nil)
        let refused = [
            "", "f7698d3", head.uppercased(), String(head.dropLast()), head + "a",
            String(repeating: "g", count: 40), "-" + String(head.dropFirst()),
            String(repeating: "a", count: 63), " " + String(head.dropFirst()),
            String(repeating: "\u{0661}", count: 40),
        ]
        for hex in refused {
            #expect(CommitID(hex) == nil, "\(hex.debugDescription)")
        }
        let data = try JSONEncoder().encode([commit])
        #expect(String(decoding: data, as: UTF8.self) == "[\"\(head)\"]")
        #expect(try JSONDecoder().decode([CommitID].self, from: data) == [commit])
    }

    @Test func aBranchLikeAFlagARefspecOrARangeIsRefused() throws {
        let refused = [
            "", "-f", "--force", "+main", ":main", "a..b", "main@{1}", "@{-1}", "HEAD", "@", "a b",
            "a\u{1}b", "a\u{7F}b", "a\tb", "x:y", "a~b", "a^b", "a?b", "a*b", "a[b", "a\\b",
            "a.lock", "a.lock/b", "a/.b", ".a", "a/", "/a", "a//b", "a.",
        ]
        for text in refused {
            #expect(BranchName(text) == nil, "\(text.debugDescription)")
        }
        for text in ["main", "feature/x", "fix-1.2", "a@b", "a+b", "head", "HEAD/x", "é"] {
            #expect(BranchName(text)?.text == text, "\(text.debugDescription)")
        }
    }

    @Test func aNodeIDHasTheFormOfAGitHubNodeID() {
        for text in ["PRRT_kwDOexample1", "MDExOlB1bGxSZXF1ZXN0MQ==", "PR_kw-DO_1"] {
            #expect(NodeID(text)?.text == text)
        }
        let refused = ["", "a b", "a=b", "a===", "a/b", "a\"b", String(repeating: "a", count: 101)]
        for text in refused {
            #expect(NodeID(text) == nil, "\(text.debugDescription)")
        }
    }
}
