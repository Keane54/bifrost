import BifrostFoundation
import BifrostSessions
import Foundation
import Testing

@testable import BifrostReviews

// The read and the write of state.json (docs/behaviour/reviews.md, "The state"), with the forms
// of the Electron file in Fixtures/. The take-over and the store are in ReviewsStoreTests.

private let forms = [
    "state-first-release", "state-review-round", "state-request-round", "state-hidden-rows",
]

private func stored(_ data: Data) throws -> StoredReviewsState {
    try JSONDecoder().decode(StoredReviewsState.self, from: data)
}

private func json(_ data: Data) throws -> JSONValue {
    try JSONDecoder().decode(JSONValue.self, from: data)
}

// The JSON value of the saved form of a state.
private func saved(_ state: ReviewsState) throws -> JSONValue {
    try json(JSONFile.encode(state))
}

private func key(_ text: String) throws -> PRKey {
    try #require(PRKey(text: text))
}

private func node(_ text: String) throws -> NodeID {
    try #require(NodeID(text))
}

private func commit(_ character: Character) throws -> CommitID {
    try #require(CommitID(String(repeating: character, count: 40)))
}

private func time(_ milliseconds: Int) -> Date {
    Date(timeIntervalSince1970: Double(milliseconds) / 1000)
}

// True when whole holds each value of part: each field of an object, and each item of an array in
// its place. A field that whole adds (a default that the file did not have) does not count.
private func holds(_ whole: JSONValue, _ part: JSONValue) -> Bool {
    switch (whole, part) {
    case (.object(let wholeFields), .object(let partFields)):
        partFields.allSatisfy { key, value in wholeFields[key].map { holds($0, value) } ?? false }
    case (.array(let wholeItems), .array(let partItems)):
        wholeItems.count == partItems.count && zip(wholeItems, partItems).allSatisfy(holds)
    default:
        whole == part
    }
}

@Suite("the Reviews state", .timeLimit(.minutes(1)))
struct ReviewsStateTests {
    // Each form of the Electron file opens with no dropped field, its save holds each value of
    // the file, and a read of the save gives the same state.
    @Test func eachElectronFormOpensWithEveryValue() throws {
        for form in forms {
            let data = try FixtureFiles.data(form)
            let read = try stored(data)
            #expect(read.dropped == [], "\(form)")
            #expect(holds(try saved(read.state), try json(data)), "\(form)")
            #expect(try stored(JSONFile.encode(read.state)).state == read.state, "\(form)")
        }

        let first = try stored(FixtureFiles.data("state-first-release")).state
        #expect(first.turnedOnAt == time(1_794_000_000_000))
        #expect(try first.baseline == [node("PR_kwDOexample1"), node("PRRT_kwDOexample2")])
        #expect(
            try first.requests[key("owner-a/repo-a#1")]
                == RequestMark(firstSeen: time(1_794_000_000_000), baseline: true))
        #expect(try first.pauses[key("owner-a/repo-b#2")] == time(1_794_004_200_000))
        let early = try #require(first.prs[key("owner-b/repo-c#3")])
        #expect(
            try early.handled[node("PRRT_kwDOexample3")]
                == Handled(at: time(1_794_000_900_000), lastReplyAt: nil))
        #expect(try early.firstCopilotReview == node("PRR_kwDOexample5"))
        #expect(early.requestSession?.name == "repo-c-3-request")
        #expect(early.requestSession?.shortID?.text == "0b6f3c2a")
        #expect(early.handleCopilot && !early.handleOlder)
        #expect(early.round == nil && early.outbox == nil && early.held.isEmpty)
        #expect(first.posted.map(\.body) == ["Fixed by aaaaaaa"])
        #expect(first.voicePairs.map(\.final) == ["Final text"])
        #expect(first.queue.isEmpty && first.fixFrom == nil && first.autoFixConsent == nil)

        let review = try stored(FixtureFiles.data("state-review-round")).state
        let reviewing = try #require(review.prs[key("owner-a/repo-a#1")])
        let round = try #require(reviewing.round)
        #expect(round.phase == .running && round.kind == .review)
        #expect(try round.headSHA == commit("b") && round.baseSHA == commit("a"))
        #expect(round.sessionID?.text == "1c2d3e4f-5a6b-4c7d-8e9f-0a1b2c3d4e5f")
        #expect(reviewing.actedAt == time(1_794_001_900_000))
        let mark = try #require(review.prs[key("owner-a/repo-a#4")]?.recommendation)
        #expect(try mark.value == .requestChanges && mark.reviewID == node("PRR_kwDOexample7"))
        let deleted = try #require(review.prs[key("owner-a/repo-a#6")]?.recommendation)
        #expect(deleted.deleted && deleted.reviewID == nil)
        #expect(review.drafts.map(\.line) == [12])
        #expect(try review.queue.map(\.pr) == [key("owner-a/repo-a#5"), key("owner-a/repo-a#8")])
        #expect(review.queue.allSatisfy { $0.kind == .review })
        let repo = try #require(RepoName("owner-a/repo-a"))
        #expect(review.repos[repo] == RepoMark(trustNotifiedAt: time(1_794_000_300_000)))
        #expect(review.setUpAt == time(1_794_000_200_000))

        let request = try stored(FixtureFiles.data("state-request-round")).state
        let fixing = try #require(request.prs[key("owner-a/repo-b#7")])
        let outbox = try #require(fixing.outbox)
        #expect(outbox.posts.count == 8)
        #expect(try outbox.posts[1].write == .push(commit: commit("1"), signed: false))
        #expect(outbox.posts[4].state == .sending)
        #expect(
            try outbox.posts[2].write
                == .reply(
                    item: node("PRRT_kwDOexample12"), text: nil, by: commit("1"),
                    comment: node("PRRC_kwDOexample15")))
        #expect(outbox.posts[7].write == .rerequest(logins: ["reviewer-a"]))
        #expect(try fixing.round?.kind == .request && fixing.round?.fixSHA == commit("1"))
        #expect(fixing.round?.items.count == 3)
        let question = try #require(fixing.questions[node("PRRT_kwDOexample16")])
        #expect(question.kind == .thread && question.place == "src/limit.ts line 4")
        #expect(
            question.url?.absoluteString
                == "https://github.com/owner-a/repo-b/pull/7#discussion_r1")
        #expect(question.answer == nil)
        #expect(try fixing.held == [node("PRRT_kwDOexample17")])
        #expect(try fixing.askedReviewers == ["reviewer-a": commit("e")])
        #expect(fixing.checkedAt == time(1_794_002_950_000))
        let signed = try #require(request.prs[key("owner-a/repo-a#11")]?.outbox)
        #expect(signed.posts.first?.write == .push(commit: nil, signed: true))
        #expect(request.fixFrom == time(1_794_000_000_000) && request.autoFixConsent == true)

        let hidden = try stored(FixtureFiles.data("state-hidden-rows")).state
        #expect(hidden.hidden.count == 2)
        #expect(try hidden.hidden[key("owner-b/repo-d#21")] == time(1_794_006_000_000))
        #expect(hidden.autoFixConsent == nil && hidden.setUpAt == nil)
    }

    // A field of the wrong form gets its empty value and its name goes in the dropped names. The
    // other fields keep their values. An outbox with one bad write goes whole, so no part of a
    // damaged list of writes is ever sent.
    @Test func aBadFieldCostsOnlyThatField() throws {
        let data = try FixtureFiles.edited("state-first-release") { root in
            root["turnedOnAt"] = "soon"
            // A number that is too large to be a time.
            root["setUpAt"] = 1e300
            var requests = root["requests"] as? [String: Any] ?? [:]
            requests["not a key"] = ["firstSeen": 1, "baseline": false]
            root["requests"] = requests
            root["queue"] = [["key": "owner-a/repo-a#1", "kind": "other", "at": 1]]
            var prs = root["prs"] as? [String: Any] ?? [:]
            var pr = prs["owner-b/repo-c#3"] as? [String: Any] ?? [:]
            pr["firstCopilotReview"] = 5
            var handled = pr["handled"] as? [String: Any] ?? [:]
            handled["not an ID!"] = ["at": 1, "lastReplyAt": 1]
            pr["handled"] = handled
            prs["owner-b/repo-c#3"] = pr
            root["prs"] = prs
        }
        let read = try stored(data)
        #expect(
            read.dropped == [
                "prs.firstCopilotReview", "prs.handled", "queue", "requests", "setUpAt",
                "turnedOnAt",
            ])
        let state = read.state
        #expect(state.turnedOnAt == nil && state.setUpAt == nil)
        #expect(state.requests.count == 2 && state.queue.isEmpty)
        #expect(state.baseline.count == 2 && state.posted.count == 1)
        let pr = try #require(state.prs[key("owner-b/repo-c#3")])
        #expect(pr.firstCopilotReview == nil)
        #expect(pr.handled.count == 2)
        #expect(pr.requestSession?.name == "repo-c-3-request")

        let damaged = try FixtureFiles.edited("state-request-round") { root in
            var prs = root["prs"] as? [String: Any] ?? [:]
            var pr = prs["owner-a/repo-b#7"] as? [String: Any] ?? [:]
            var outbox = pr["outbox"] as? [String: Any] ?? [:]
            var posts = outbox["posts"] as? [[String: Any]] ?? []
            posts[1]["sha"] = "not a commit"
            outbox["posts"] = posts
            pr["outbox"] = outbox
            prs["owner-a/repo-b#7"] = pr
            root["prs"] = prs
        }
        let kept = try stored(damaged)
        #expect(kept.dropped == ["prs.outbox"])
        let fixing = try #require(kept.state.prs[key("owner-a/repo-b#7")])
        #expect(fixing.outbox == nil)
        #expect(fixing.round != nil && fixing.questions.count == 1 && fixing.held.count == 1)
    }

    // A top-level field that the state does not know comes back in the save, with its value.
    @Test func anUnknownFieldSurvivesASave() throws {
        let later: JSONValue = ["mode": "later", "items": [1, "two", .null]]
        let data = try FixtureFiles.edited("state-first-release") { root in
            root["laterField"] = ["mode": "later", "items": [1, "two", NSNull()]]
        }
        let read = try stored(data)
        #expect(read.dropped == [])
        #expect(read.state.unknown.values == ["laterField": later])
        let fields = try #require(try saved(read.state).object)
        #expect(fields["laterField"] == later)
        #expect(fields["version"] == 1)
    }

    // Two keys that differ only in case name one PR: the first in sorted order wins, the other
    // goes, and its field is in the dropped names. The save keeps the spelling of the winner.
    @Test func twoKeysThatDifferInCaseAreOnePR() throws {
        let text = """
            {
              "version": 1,
              "prs": {
                "owner-a/repo-b#12": { "lastError": "lower" },
                "Owner-A/Repo-B#12": { "lastError": "upper" }
              },
              "pauses": { "owner-a/repo-b#12": 2000, "Owner-A/Repo-B#12": 1000 }
            }
            """
        let read = try stored(Data(text.utf8))
        #expect(read.dropped == ["pauses", "prs"])
        let lower = try key("owner-a/repo-b#12")
        #expect(read.state.prs.count == 1)
        #expect(read.state.prs[lower]?.lastError == "upper")
        #expect(read.state.pauses == [lower: time(1000)])
        let fields = try #require(try saved(read.state).object)
        #expect(fields["prs"]?.object?.keys.sorted() == ["Owner-A/Repo-B#12"])
        #expect(fields["pauses"] == ["Owner-A/Repo-B#12": 1000])
    }

    // A file of another version reads as the empty state with its unknown fields, and its
    // version tells the store not to open it. A missing file and version 1 are current.
    @Test func anotherVersionGivesTheEmptyState() throws {
        let data = try FixtureFiles.edited("state-hidden-rows") { root in
            root["version"] = 2
            root["laterField"] = true
        }
        let read = try stored(data)
        var empty = ReviewsState()
        empty.unknown = UnknownFields(["laterField": true])
        #expect(read.state == empty)
        #expect(read.dropped.contains("hidden") && read.dropped.contains("version"))
        #expect(read.version == .later)
        #expect(try stored(Data(#"{"version": 0.5}"#.utf8)).version == .unknown)
        #expect(try stored(Data(#"{"version": "1"}"#.utf8)).version == .unknown)
        #expect(try stored(Data("{}".utf8)).version == .unknown)
        #expect(try stored(Data(#"{"version": 1.0}"#.utf8)).version == .current)
        #expect(StoredReviewsState().version == .current)
    }

    // A root that is not an object does not decode: the store treats it as a file that does not
    // parse, and keeps it aside.
    @Test func aRootThatIsNotAnObjectDoesNotDecode() {
        for text in ["[]", "null", "42", #""text""#] {
            #expect(throws: NoJSONForm.self, "\(text)") { try stored(Data(text.utf8)) }
        }
    }
}
