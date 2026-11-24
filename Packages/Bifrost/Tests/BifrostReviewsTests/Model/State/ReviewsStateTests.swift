import BifrostFoundation
import BifrostSessions
import BifrostTestSupport
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

private func job(_ id: Int) throws -> JobID {
    try #require(JobID(id))
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

@Suite("the Reviews state", .testTimeLimit)
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

    // The wait of a notice for CI is a field of Bifrost only. The file has it only while it is
    // true, so a mark with no wait keeps the form of the Electron app, and a read gives it back.
    @Test func aNoticeThatWaitsForCIIsSavedOnlyWhileItWaits() throws {
        let at = time(1_794_000_000_000)
        let plain = RequestMark(firstSeen: at, baseline: false)
        let waits = RequestMark(firstSeen: at, baseline: false, noticeWaitsForCI: true)
        #expect(plain.stored == ["firstSeen": .time(at), "baseline": false])
        #expect(
            waits.stored == ["firstSeen": .time(at), "baseline": false, "noticeWaitsForCI": true])
        var state = ReviewsState()
        state.requests[try key("owner-a/repo-a#1")] = waits
        state.requests[try key("owner-a/repo-a#2")] = plain
        let read = try stored(JSONFile.encode(state))
        #expect(read.dropped == [] && read.state == state)
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

    // The session of a PR keeps the profile of its start flags and the count of its rounds. A
    // session of an older file has no profile and no rounds.
    @Test func aSessionRefKeepsItsProfileAndRounds() throws {
        let id: SessionID = "1c2d3e4f-5a6b-4c7d-8e9f-0a1b2c3d4e5f"
        let ref = SessionRef(
            sessionID: id, name: "repo-b-7-request", shortID: ShortID("1c2d3e4f"),
            profile: String(repeating: "ab", count: 32), rounds: 3)
        var dropped = DroppedFields()
        #expect(SessionRef(stored: ref.stored, dropped: &dropped) == ref)
        #expect(ref.stored.object?["rounds"] == 3)
        #expect(ref.stored.object?["profile"] == .string(String(repeating: "ab", count: 32)))
        #expect(dropped.sorted.isEmpty)

        let old: JSONValue = [
            "sessionId": "1c2d3e4f-5a6b-4c7d-8e9f-0a1b2c3d4e5f", "name": "repo-b-7-request",
            "shortId": "1c2d3e4f",
        ]
        let read = try #require(SessionRef(stored: old, dropped: &dropped))
        #expect(read.rounds == 0 && read.profile == nil)
        #expect(dropped.sorted.isEmpty)

        let bad: JSONValue = [
            "sessionId": "1c2d3e4f-5a6b-4c7d-8e9f-0a1b2c3d4e5f", "name": "repo-b-7-request",
            "rounds": -1, "profile": 5,
        ]
        let kept = try #require(SessionRef(stored: bad, dropped: &dropped))
        #expect(kept.rounds == 0 && kept.profile == nil)
        #expect(dropped.sorted == ["prs.session.profile", "prs.session.rounds"])
    }

    // The reason keeps the count of the files and only the first five names, so a big folder
    // never makes the file big. The count and the names survive a save and a read.
    @Test func theReasonKeepsFiveNamesAndTheCount() throws {
        let paths = (0..<5000).map { "big/file-\($0).txt" }
        var prState = PRState()
        prState.waiting = WaitsForYou(reason: "Your change is still here.", files: paths)
        #expect(prState.waiting?.files == Array(paths.prefix(5)))
        #expect(prState.waiting?.fileCount == 5000)
        #expect(prState.stored.object?["waitsForYouFiles"]?.array?.count == 5)
        var dropped = DroppedFields()
        let read = PRState(stored: prState.stored, dropped: &dropped)
        #expect(read == prState && read.waiting?.fileCount == 5000 && dropped.sorted.isEmpty)
        // A short list stores no count of its own.
        prState.waiting?.files = ["a.txt", "b.txt"]
        #expect(prState.waiting?.fileCount == 2)
        #expect(prState.stored.object?["waitsForYouFileCount"] == nil)
    }

    // The outbox of an own request keeps its mark, and the reason that the work waits for the
    // user stays. An older file has neither: the outbox is a round's, and there is no reason. An
    // own mark that is not a flag drops the whole outbox.
    @Test func anOwnOutboxAndTheReasonForTheUserStay() throws {
        let head = try #require(CommitID(String(repeating: "a", count: 40)))
        var prState = PRState()
        prState.outbox = Outbox(
            headSHA: head, mergeBase: head, startedAt: Date(timeIntervalSince1970: 1_800_000_000),
            seen: [:],
            posts: [
                OutboxPost(
                    id: "commit", state: .todo,
                    write: .commit(paths: ["a.txt"], message: "fix: it", commit: nil)),
                OutboxPost(id: "push", state: .todo, write: .push(commit: nil, signed: false)),
            ],
            own: true)
        prState.waiting = WaitsForYou(reason: "Your change is still here.", files: ["a.txt"])
        var dropped = DroppedFields()
        let read = PRState(stored: prState.stored, dropped: &dropped)
        #expect(read == prState && dropped.sorted.isEmpty)
        #expect(prState.stored.object?["outbox"]?.object?["own"] == true)
        #expect(prState.stored.object?["waitsForYouFiles"] == ["a.txt"])

        var older = prState
        older.outbox?.own = false
        older.waiting = nil
        #expect(older.stored.object?["outbox"]?.object?["own"] == nil)
        #expect(older.stored.object?["waitsForYou"] == nil)
        #expect(older.stored.object?["waitsForYouFiles"] == nil)
        #expect(PRState(stored: older.stored, dropped: &dropped) == older)

        guard case .object(var fields) = prState.stored,
            case .object(var outbox)? = fields["outbox"]
        else {
            Issue.record("The stored state has no outbox object.")
            return
        }
        outbox["own"] = "yes"
        fields["outbox"] = .object(outbox)
        #expect(PRState(stored: .object(fields), dropped: &dropped).outbox == nil)
    }

    // The consents of merge conflicts and of failing CI save under their names and read back,
    // also a refusal (false) and no consent (null). Only a recorded consent with its setting on
    // lets the work start, and a consent changes no other field, also not the start of new work.
    // A bad value costs only its field.
    @Test func theConsentsRoundTripAndGateTheWork() throws {
        var state = ReviewsState()
        #expect(state.conflictConsent == nil && state.ciConsent == nil)
        #expect(!state.allowsConflictFix(true) && !state.allowsCIFix(true))
        state.consentToConflictFix()
        #expect(state.conflictConsent == true && state.ciConsent == nil)
        #expect(state.allowsConflictFix(true) && !state.allowsConflictFix(false))
        #expect(!state.allowsCIFix(true))
        state.consentToCIFix()
        #expect(state.ciConsent == true && state.allowsCIFix(true) && !state.allowsCIFix(false))
        #expect(state.fixFrom == nil && state.autoFixConsent == nil)
        let fields = try #require(try saved(state).object)
        #expect(fields["conflictConsent"] == true && fields["ciConsent"] == true)
        let read = try stored(JSONFile.encode(state))
        #expect(read.dropped == [] && read.state == state)

        state.conflictConsent = false
        state.ciConsent = nil
        #expect(!state.allowsConflictFix(true) && !state.allowsCIFix(true))
        let other = try #require(try saved(state).object)
        #expect(other["conflictConsent"] == false && other["ciConsent"] == .null)
        #expect(try stored(JSONFile.encode(state)).state == state)

        let text = #"{"version": 1, "conflictConsent": "yes", "ciConsent": true}"#
        let bad = try stored(Data(text.utf8))
        #expect(bad.dropped == ["conflictConsent"])
        #expect(bad.state.conflictConsent == nil && bad.state.ciConsent == true)
    }

    // A CI consent (the proof that a re-run of failed jobs needs) comes only from a state with
    // the setting on and the consent recorded. A refusal, no consent or the conflict consent
    // gives none.
    @Test func aCIConsentNeedsTheSettingAndTheConsent() {
        var state = ReviewsState()
        #expect(state.ciConsent(true) == nil && state.ciConsent(false) == nil)
        state.ciConsent = false
        #expect(state.ciConsent(true) == nil)
        state.consentToConflictFix()
        #expect(state.ciConsent(true) == nil)
        state.consentToCIFix()
        #expect(state.ciConsent(true) != nil && state.ciConsent(false) == nil)
    }

    // The conflict mark, the CI mark with its question, a Resolve now click and the merge start
    // of a round save under their names and read back. A save writes only the fields that have a
    // value, so the file of an older release reads with no mark and no click. A round and a queue
    // entry of each kind read back, and a round of an unknown kind goes.
    @Test func theMarksRoundTripAndAnUnknownKindDropsItsRound() throws {
        let at = time(1_794_000_000_000)
        let reason = "Claude couldn't resolve these conflicts: the two sides disagree."
        var prState = PRState()
        prState.conflict = ConflictMark(
            head: try commit("a"), base: try commit("b"), at: at, outcome: .failed(reason))
        let question = CIQuestion(
            text: "Is the test of the parser flaky?", head: try commit("c"),
            jobs: ["build", "test"], at: at, byClaude: true, answer: "Run it again.")
        prState.ci = CIMark(
            chain: [try commit("c"), try commit("d")], fixes: 2, retries: 1,
            handledHead: try commit("d"), handled: [try job(101), try job(135_562_930_272)],
            retrying: try commit("d"), question: question, userHandles: try commit("e"))
        prState.resolveNow = true
        prState.round = ActiveRound(
            phase: .running, startedAt: at, at: at, headSHA: try commit("a"),
            baseSHA: try commit("b"), kind: .conflict, token: "t1", startSHA: try commit("f"))
        var dropped = DroppedFields()
        #expect(PRState(stored: prState.stored, dropped: &dropped) == prState)
        #expect(dropped.sorted.isEmpty)
        let fields = try #require(prState.stored.object)
        #expect(fields["resolveNow"] == true)
        #expect(
            fields["conflict"]
                == [
                    "head": .string(try commit("a").hex), "base": .string(try commit("b").hex),
                    "at": 1_794_000_000_000, "outcome": "failed", "reason": .string(reason),
                ])
        let ci = try #require(fields["ci"]?.object)
        #expect(
            ci.keys.sorted() == [
                "chain", "fixes", "handled", "handledHead", "question", "retries", "retrying",
                "userHandles",
            ])
        #expect(ci["handled"] == [101, 135_562_930_272] && ci["fixes"] == 2)
        #expect(
            ci["question"]?.object?.keys.sorted() == [
                "answer", "at", "byClaude", "head", "jobs", "text",
            ])
        #expect(fields["round"]?.object?["kind"] == "conflict")
        #expect(fields["round"]?.object?["startSha"] == .string(try commit("f").hex))

        for outcome in [ConflictOutcome.working, .pushed(try commit("9"))] {
            prState.conflict?.outcome = outcome
            #expect(PRState(stored: prState.stored, dropped: &dropped).conflict?.outcome == outcome)
        }
        let merge = prState.stored.object?["conflict"]?.object
        let mergeHex = try commit("9").hex
        #expect(merge?["outcome"] == "pushed" && merge?["merge"] == .string(mergeHex))
        #expect(merge?["reason"] == nil)

        // The empty values write nothing.
        let empty = try #require(PRState().stored.object)
        #expect(empty["conflict"] == nil && empty["ci"] == nil && empty["resolveNow"] == nil)
        #expect(CIMark(chain: []).stored == [:])
        let bare = CIQuestion(
            text: "Why?", head: try commit("c"), jobs: [], at: at, byClaude: false)
        #expect(bare.stored.object?.keys.sorted() == ["at", "head", "text"])
        let plain = ActiveRound(phase: .running, startedAt: at, at: at, kind: .ci)
        #expect(plain.stored.object?["startSha"] == nil)
        let older = try stored(FixtureFiles.data("state-request-round")).state
        let fixing = try #require(older.prs[key("owner-a/repo-b#7")])
        #expect(fixing.conflict == nil && fixing.ci == nil && !fixing.resolveNow)
        #expect(fixing.round?.startSHA == nil)

        // The chain keeps its newest commits, and a question its first names of jobs.
        let commits = try "0123456789".map { try commit($0) }
        var chain = CIMark(chain: commits)
        #expect(chain.chain == Array(commits.suffix(8)))
        chain.chain.append(try commit("a"))
        #expect(chain.chain == Array(commits.suffix(7)) + [try commit("a")])
        var names = CIQuestion(
            text: "Why?", head: try commit("c"), jobs: (1...7).map { "job \($0)" }, at: at,
            byClaude: false)
        #expect(names.jobs == (1...5).map { "job \($0)" })
        names.jobs.append("job 8")
        #expect(names.jobs.count == 5)

        // Each kind reads back, also in the queue, and an unknown kind drops its round.
        #expect(PRSessionKind.allCases.filter(\.isMine) == [.request, .conflict, .ci])
        for kind in PRSessionKind.allCases {
            let round = ActiveRound(phase: .preparing, startedAt: at, at: at, kind: kind)
            #expect(ActiveRound(stored: round.stored, dropped: &dropped) == round)
            let entry = QueueEntry(pr: try key("owner-a/repo-b#7"), kind: kind, at: at)
            #expect(QueueEntry(stored: entry.stored, dropped: &dropped) == entry)
        }
        #expect(dropped.sorted.isEmpty)
        guard case .object(var unknown) = prState.stored,
            case .object(var round)? = unknown["round"]
        else {
            Issue.record("The stored state has no round object.")
            return
        }
        round["kind"] = "rebase"
        unknown["round"] = .object(round)
        let read = PRState(stored: .object(unknown), dropped: &dropped)
        #expect(read.round == nil && read.conflict == prState.conflict && read.ci == prState.ci)
        #expect(dropped.sorted == ["prs.round"])
    }

    // A record of a PR that drops a field, or that is not an object, puts its conflict mark in
    // doubt, and so does a list of PRs that loses a record. A record that reads in full does not,
    // and the file never keeps the doubt.
    @Test func aRecordThatDoesNotReadInFullPutsItsMarkInDoubt() throws {
        var dropped = DroppedFields()
        var good = PRState()
        good.lastError = "A reason."
        good.conflict = ConflictMark(
            head: try commit("a"), base: try commit("b"), at: time(1000), outcome: .working)
        let clean = PRState(stored: good.stored, dropped: &dropped)
        #expect(clean == good && !clean.markInDoubt && dropped.sorted.isEmpty)
        guard case .object(var fields) = good.stored else {
            Issue.record("The stored state is not an object.")
            return
        }
        fields["conflict"] = ["base": .string(try commit("b").hex), "outcome": "working"]
        let lost = PRState(stored: .object(fields), dropped: &dropped)
        #expect(lost.markInDoubt && lost.conflict == nil && lost.lastError == "A reason.")
        #expect(dropped.sorted == ["prs.conflict"])
        #expect(lost.stored.object?["markInDoubt"] == true)
        #expect(PRState(stored: "not a record", dropped: &dropped).markInDoubt)

        let text = #"{"version": 1, "prs": {"owner-a/repo-b#12": {"lastError": "A"}, "no": {}}}"#
        let state = try stored(Data(text.utf8)).state
        let record = try key("owner-a/repo-b#12")
        #expect(state.marksInDoubt && state.prs[record]?.markInDoubt == false)
        #expect(try stored(Data(#"{"version": 1, "prs": 5}"#.utf8)).state.marksInDoubt)
        #expect(try !stored(Data(#"{"version": 1, "prs": {}}"#.utf8)).state.marksInDoubt)
        #expect(try saved(state).object?["marksInDoubt"] == true)
        #expect(try saved(stored(Data(#"{"version": 1, "prs": {}}"#.utf8)).state)
            .object?["marksInDoubt"] == nil)
    }

    // An explicit null in the conflict or CI field is a mark that something damaged, because
    // Bifrost never writes null there. The doubt survives a save and a read before the first poll.
    @Test func aNullMarkIsInDoubtAndTheDoubtSurvivesASave() throws {
        for field in ["conflict", "ci"] {
            var dropped = DroppedFields()
            let read = PRState(stored: .object([field: .null]), dropped: &dropped)
            #expect(read.markInDoubt && dropped.sorted == ["prs.\(field)"], "\(field)")
        }
        var dropped = DroppedFields()
        var doubt = PRState()
        doubt.markInDoubt = true
        let again = PRState(stored: doubt.stored, dropped: &dropped)
        #expect(again.markInDoubt && dropped.sorted.isEmpty)
        var settled = doubt
        settled.markInDoubt = false
        #expect(settled.stored.object?["markInDoubt"] == nil)
        #expect(!PRState(stored: settled.stored, dropped: &dropped).markInDoubt)
    }

    // A CI mark that Bifrost can't read in full has no fix and no re-run left: a bad count, the
    // loss of any other field, or a value that is not an object makes both counts their limits.
    // A chain with a bad commit reads as no chain. The good fields stay, and the save of the read
    // reads back with nothing dropped. A missing count is 0.
    @Test func aCIMarkThatDoesNotReadInFullHasNoTriesLeft() throws {
        let at = time(1_794_000_000_000)
        let good = CIMark(
            chain: [try commit("c")], fixes: 1, handledHead: try commit("c"),
            handled: [try job(101)], retrying: try commit("c"),
            question: CIQuestion(
                text: "Is it flaky?", head: try commit("c"), jobs: ["test"], at: at,
                byClaude: true),
            userHandles: try commit("d"))
        let fields = try #require(good.stored.object)
        func read(_ value: JSONValue) -> (mark: CIMark?, dropped: [String]) {
            var dropped = DroppedFields()
            let mark = CIMark(stored: value, dropped: &dropped)
            return (mark, dropped.sorted)
        }
        #expect(read(.object(fields)).mark == good && read(.object(fields)).dropped.isEmpty)
        let counts = read(["chain": [.string(try commit("c").hex)]])
        #expect(counts.mark?.fixes == 0 && counts.mark?.retries == 0)

        let longText = String(repeating: "x", count: Question.maxText + 1)
        let longAnswer = String(repeating: "y", count: Question.maxAnswer + 1)
        // A good question with a text one unit over the limit: only the limit refuses it.
        var longQuestion = try #require(fields["question"]?.object)
        longQuestion["text"] = .string(longText)
        let damage: [(String, JSONValue, String)] = [
            ("fixes", -1, "prs.ci.fixes"), ("fixes", "2", "prs.ci.fixes"),
            ("fixes", 1.5, "prs.ci.fixes"), ("retries", "one", "prs.ci.retries"),
            ("handledHead", "not a commit", "prs.ci.handledHead"),
            ("handled", [101, "two"], "prs.ci.handled"),
            ("retrying", 5, "prs.ci.retrying"), ("userHandles", false, "prs.ci.userHandles"),
            ("chain", [.string(try commit("c").hex), "bad"], "prs.ci.chain"),
            ("question", .object(longQuestion), "prs.ci.question"),
        ]
        for (key, value, name) in damage {
            var broken = fields
            broken[key] = value
            let (mark, names) = read(.object(broken))
            #expect(mark?.fixes == CIRule.maxFixes && mark?.retries == CIRule.maxRetries, "\(key)")
            #expect(names == [name], "\(key)")
            #expect(mark?.userHandles == (key == "userHandles" ? nil : good.userHandles), "\(key)")
        }
        var partial = fields
        partial["handled"] = [101, "two"]
        #expect(read(.object(partial)).mark?.handled == [try job(101)])
        partial["chain"] = [.string(try commit("c").hex), "bad"]
        #expect(read(.object(partial)).mark?.chain == [])

        var questions = fields
        var answered = try #require(fields["question"]?.object)
        for answer in [JSONValue.string(longAnswer), 5] {
            answered["answer"] = answer
            questions["question"] = .object(answered)
            let (mark, names) = read(.object(questions))
            #expect(mark?.question == nil && mark?.fixes == CIRule.maxFixes)
            #expect(names == ["prs.ci.question"])
        }
        answered["text"] = .string(String(repeating: "x", count: Question.maxText))
        answered["answer"] = .string(String(repeating: "y", count: Question.maxAnswer))
        questions["question"] = .object(answered)
        #expect(read(.object(questions)).mark?.question?.answer?.count == Question.maxAnswer)
        #expect(read(.object(questions)).dropped.isEmpty)

        for value: JSONValue in [5, "ci", [1]] {
            let (mark, names) = read(value)
            #expect(mark == CIMark(chain: [], fixes: CIRule.maxFixes, retries: CIRule.maxRetries))
            #expect(names == ["prs.ci"])
        }
        var broken = fields
        broken["fixes"] = -1
        let spent = try #require(read(.object(broken)).mark)
        let again = read(spent.stored)
        #expect(again.mark == spent && again.dropped.isEmpty)
    }

    // A good save never writes a field of a CI mark with no chain. So a mark with no chain and
    // with any other field is damaged: its counts read as their limits, and no new chain starts
    // from 0. A mark with no field, or with only null fields, is an empty mark.
    @Test func aCIMarkWithNoChainButOtherFieldsIsDamaged() throws {
        func read(_ value: JSONValue) -> (mark: CIMark?, dropped: [String]) {
            var dropped = DroppedFields()
            let mark = CIMark(stored: value, dropped: &dropped)
            return (mark, dropped.sorted)
        }
        let damaged: [JSONValue] = [
            ["fixes": 1, "handled": [101]], ["userHandles": .string(try commit("d").hex)],
            ["chain": [], "retries": 1], ["chain": .null, "handled": [101]],
        ]
        for value in damaged {
            let (mark, names) = read(value)
            #expect(mark?.chain == [], "\(value)")
            #expect(mark?.fixes == CIRule.maxFixes && mark?.retries == CIRule.maxRetries)
            #expect(names == ["prs.ci.chain"], "\(value)")
        }
        #expect(read(["fixes": 1, "handled": [101]]).mark?.handled == [try job(101)])
        for value: JSONValue in [[:], ["chain": .null, "fixes": .null]] {
            let (mark, names) = read(value)
            #expect(mark == CIMark(chain: []) && names.isEmpty, "\(value)")
        }
        // The save of a mark that is not an object has spent counts and no chain, so it reads
        // back as damaged again.
        let spent = try #require(read(5).mark)
        let again = read(spent.stored)
        #expect(again.mark == spent && again.dropped == ["prs.ci.chain"])
    }

    // A conflict mark that Bifrost can't read in full keeps the pair that it tried, so no
    // automatic round tries that pair again: an unknown outcome, a pushed outcome with no merge
    // commit and a failed outcome with no reason read as a failure with no reason, and a bad time
    // reads as the distant past. Only a mark with no head or no base goes.
    @Test func aConflictMarkThatDoesNotReadInFullKeepsItsPair() throws {
        let head = try commit("a")
        let base = try commit("b")
        let fields: [String: JSONValue] = [
            "head": .string(head.hex), "base": .string(base.hex), "at": 1_794_000_000_000,
            "outcome": "failed", "reason": "It failed.",
        ]
        func read(_ change: (inout [String: JSONValue]) -> Void) -> (ConflictMark?, [String]) {
            var object = fields
            change(&object)
            var dropped = DroppedFields()
            let mark = ConflictMark(stored: .object(object), dropped: &dropped)
            return (mark, dropped.sorted)
        }
        let outcomes: [(String, (inout [String: JSONValue]) -> Void)] = [
            ("unknown", { $0["outcome"] = "rebased" }), ("missing", { $0["outcome"] = nil }),
            ("not a text", { $0["outcome"] = 3 }),
            ("no merge", { $0["outcome"] = "pushed" }),
            ("bad merge", {
                $0["outcome"] = "pushed"
                $0["merge"] = "abc"
            }),
            ("no reason", { $0["reason"] = nil }), ("bad reason", { $0["reason"] = 7 }),
        ]
        for (name, change) in outcomes {
            let (mark, dropped) = read(change)
            #expect(mark?.head == head && mark?.base == base, "\(name)")
            #expect(mark?.outcome == .failed(""), "\(name)")
            #expect(dropped == ["prs.conflict.outcome"], "\(name)")
        }
        let times: [(inout [String: JSONValue]) -> Void] = [
            { $0["at"] = "soon" }, { $0["at"] = nil },
        ]
        for change in times {
            let (mark, dropped) = read(change)
            #expect(mark?.at == .distantPast && mark?.outcome == .failed("It failed."))
            #expect(dropped == ["prs.conflict.at"])
        }
        #expect(read { $0["head"] = "bad" }.0 == nil)
        #expect(read { $0["base"] = nil }.0 == nil)
        let (kept, _) = read { $0["outcome"] = "rebased" }
        let mark = try #require(kept)
        var dropped = DroppedFields()
        #expect(ConflictMark(stored: mark.stored, dropped: &dropped) == mark)
        #expect(dropped.sorted.isEmpty)
        let state = PRState(stored: ["conflict": ["head": "bad"]], dropped: &dropped)
        #expect(state.conflict == nil && dropped.sorted == ["prs.conflict"])
    }

    // A CI question cuts a text or an answer over its limit at a whole character, so the file
    // reads back.
    @Test func aCIQuestionCutsATooLongText() throws {
        let at = time(1_794_000_000_000)
        let text = String(repeating: "x", count: Question.maxText - 1) + "\u{1F600}"
        var question = CIQuestion(
            text: text, head: try commit("c"), jobs: [], at: at, byClaude: false,
            answer: String(repeating: "y", count: Question.maxAnswer + 5))
        #expect(question.text == String(repeating: "x", count: Question.maxText - 1))
        #expect(question.answer?.utf16.count == Question.maxAnswer)
        question.text = String(repeating: "z", count: Question.maxText + 9)
        question.answer = String(repeating: "w", count: Question.maxAnswer + 1)
        #expect(question.text.utf16.count == Question.maxText)
        #expect(question.answer?.utf16.count == Question.maxAnswer)
        var dropped = DroppedFields()
        #expect(CIQuestion(stored: question.stored, dropped: &dropped) == question)
        #expect(dropped.sorted.isEmpty)
    }

    // A root that is not an object does not decode: the store treats it as a file that does not
    // parse, and keeps it aside.
    @Test func aRootThatIsNotAnObjectDoesNotDecode() {
        for text in ["[]", "null", "42", #""text""#] {
            #expect(throws: NoJSONForm.self, "\(text)") { try stored(Data(text.utf8)) }
        }
    }
}
