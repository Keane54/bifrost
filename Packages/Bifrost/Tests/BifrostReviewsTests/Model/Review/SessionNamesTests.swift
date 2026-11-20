// The names of the PR sessions (docs/behaviour/reviews.md, "PR sessions").
import BifrostSessions
import BifrostTestSupport
import Testing

@testable import BifrostReviews

@Suite("the names of the PR sessions", .testTimeLimit)
struct SessionNamesTests {
    // <repo>-<number>-<kind>; a name in use gives <owner>-<repo>-<number>-<kind>.
    @Test func aClashAddsTheOwner() throws {
        let pr = try ReviewData.pr("Owner-A/Repo-A#7")
        #expect(
            SessionNames.name(pr, .review, clash: false, testPrefix: false) == "Repo-A-7-review")
        #expect(
            SessionNames.name(pr, .request, clash: true, testPrefix: false)
                == "Owner-A-Repo-A-7-request")
        #expect(
            SessionNames.free(pr, .review, inUse: ["Repo-A-7-review"], testPrefix: false)
                == "Owner-A-Repo-A-7-review")
        #expect(
            SessionNames.free(pr, .review, inUse: ["other"], testPrefix: false)
                == "Repo-A-7-review")
    }

    // The rounds on a PR of the user share its one request session, so a conflict round and a
    // CI round get the name of the request session, never a name of their own.
    @Test func eachKindOnAPROfTheUserGetsTheRequestName() throws {
        let pr = try ReviewData.pr("Owner-A/Repo-A#7")
        for kind in [PRSessionKind.request, .conflict, .ci] {
            #expect(
                SessionNames.name(pr, kind, clash: false, testPrefix: true)
                    == "bifrost-test-Repo-A-7-request")
            #expect(
                SessionNames.free(pr, kind, inUse: ["Repo-A-7-request"], testPrefix: false)
                    == "Owner-A-Repo-A-7-request")
        }
    }

    // A test home starts each name with bifrost-test-, so a test acts only on its own sessions.
    // A long repository name is cut, so the name fits the limit of a session name.
    @Test func aTestNameStartsWithBifrostTest() throws {
        let pr = try ReviewData.pr("Owner-A/Repo-A#7")
        #expect(
            SessionNames.name(pr, .review, clash: false, testPrefix: true)
                == "bifrost-test-Repo-A-7-review")
        let long = try ReviewData.pr("o/" + String(repeating: "r", count: 100) + "#1234")
        for clash in [false, true] {
            let name = SessionNames.name(long, .request, clash: clash, testPrefix: true)
            #expect(name.hasPrefix("bifrost-test-"))
            #expect(name.hasSuffix("-1234-request"))
            #expect(name.count == NewSessionSpec.maxName)
        }
    }
}
