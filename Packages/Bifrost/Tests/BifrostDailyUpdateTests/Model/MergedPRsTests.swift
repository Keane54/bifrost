import BifrostFoundation
import Foundation
import Testing

@testable import BifrostDailyUpdate

// The merged PRs of the user, from the answer of gh search prs (docs/behaviour/daily-update.md,
// "The run").

// One item of the answer of gh. closedAt is the merge time.
private func ghItem(
    number: Int = 12, title: String = "Add the refunds endpoint", body: String? = "",
    closedAt: String = "2026-11-17T16:05:09Z"
) -> String {
    let bodyText = body.map { "\"\($0)\"" } ?? "null"
    return """
        {"number":\(number),"title":"\(title)",\
        "url":"https://github.com/example/pay/pull/\(number)",\
        "repository":{"name":"pay","nameWithOwner":"example/pay"},"closedAt":"\(closedAt)",\
        "body":\(bodyText)}
        """
}

@Suite("the merged PRs")
struct MergedPRsTests {
    @Test func theSearchIsForTheMergesSinceTheTime() {
        let since = Date(timeIntervalSince1970: 1_794_873_600.75)  // 2026-11-17T00:00:00.75Z
        #expect(
            MergedPRs.args(since: since) == [
                "search", "prs", "--author=@me", "--merged-at=>=2026-11-17T00:00:00Z", "--limit",
                "100", "--json", "number,title,url,repository,closedAt,body",
            ])
    }

    // The run places the PRs: a PR whose title or description names a ticket goes with that
    // ticket. So the input keeps the whole title, the description up to its cut, and the merge
    // time.
    @Test func aPRThatNamesATicketGoesWithIt() throws {
        let longBody = String(repeating: "x", count: 2500) + " PAY-101"
        let answer = "[\(ghItem(title: "Add refunds (PAY-101)", body: "Closes PAY-101")),"
            + "\(ghItem(number: 13, body: longBody))]"
        let prs = try MergedPRs.parse(answer).get()
        #expect(prs.count == 2)
        let first = try #require(prs.first)
        #expect(first.title == "Add refunds (PAY-101)")
        #expect(first.body == "Closes PAY-101")
        #expect(first.repo == "example/pay")
        #expect(first.mergedAt == Date(timeIntervalSince1970: 1_794_931_509))
        // A long description is cut, and its end says so.
        #expect(prs[1].body.count == 2000 + MergedPRs.cutMark.count)
        #expect(prs[1].body.hasSuffix("\n[Bifrost cut this text.]"))
        // The input of the run holds the PR with the fields that the skill reads.
        let input = RunInput(
            settings: settings(), state: .empty, now: wednesday(9, 30), calendar: calendar(),
            prs: [first], tools: [])
        let json = try JSONDecoder().decode(JSONValue.self, from: JSONFile.encode(input))
        let pr = try #require(json.object?["prs"]?.array?.first?.object)
        #expect(Set(pr.keys) == ["repo", "number", "title", "url", "mergedAt", "body"])
        #expect(pr["title"] == "Add refunds (PAY-101)")
        #expect(pr["mergedAt"] == "2026-11-17T16:05:09.000Z")
    }

    @Test func aBadItemIsDropped() throws {
        let answer = "[\(ghItem(body: nil)),{\"number\":\"x\"},"
            + "\(ghItem(number: 14, closedAt: "yesterday"))]"
        let prs = try MergedPRs.parse(answer).get()
        // A PR with no description has an empty body.
        #expect(prs.map(\.number) == [12])
        #expect(prs.first?.body == "")
    }

    @Test func anAnswerThatIsNotAListFails() {
        #expect(MergedPRs.parse("{}") == .failure(.badAnswer))
        #expect(MergedPRs.parse("not JSON") == .failure(.badAnswer))
    }
}
