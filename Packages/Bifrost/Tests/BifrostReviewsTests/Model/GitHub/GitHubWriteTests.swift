// The closed set of GitHub writes (docs/behaviour/reviews.md, "Safety"). Each case builds the argv
// and the stdin of one gh call. The tests read both, so a new case or a changed text that names
// another mutation fails here.
import BifrostFoundation
import BifrostTestSupport
import Foundation
import Testing

@testable import BifrostReviews

private let head = "f7698d38614ba22b41f996fab73124361d2fe389"

// The 12 mutations that Bifrost may send.
private let allowed: Set<String> = [
    "addPullRequestReviewThread", "updatePullRequestReview", "addPullRequestReviewThreadReply",
    "resolveReviewThread", "addComment", "requestReviews", "createCommitOnBranch",
    "addPullRequestReview", "submitPullRequestReview", "updatePullRequestReviewComment",
    "deletePullRequestReviewComment", "deletePullRequestReview",
]

// The mutations that Bifrost never sends: they merge, dismiss, unresolve, close, reopen or edit a
// PR, a ref or the comment of another person.
private let never: Set<String> = [
    "mergePullRequest", "dismissPullRequestReview", "enablePullRequestAutoMerge",
    "unresolveReviewThread", "deleteIssueComment", "updateIssueComment", "minimizeComment",
    "closePullRequest", "reopenPullRequest", "updatePullRequest", "updatePullRequestBranch",
    "convertPullRequestToDraft", "markPullRequestReadyForReview", "requestReviewsByLogin",
    "createRef", "updateRef", "deleteRef",
]

private func node(_ text: String) throws -> NodeID { try #require(NodeID(text)) }
private func commit() throws -> CommitID { try #require(CommitID(head)) }
private func key() throws -> PRKey { try #require(PRKey(text: "Owner-A/Repo-A#7")) }

private func repo() throws -> RepoName { try #require(RepoName("Owner-A/Repo-A")) }

private func consent() throws -> CIConsent {
    var state = ReviewsState()
    state.consentToCIFix()
    return try #require(state.ciConsent(true))
}

private let comment = DraftComment(path: "src/a.swift", line: 12, side: .right, body: "Nit.")

private func signedCommit() throws -> SignedCommit {
    SignedCommit(
        repo: try #require(RepoName("Owner-A/Repo-A")),
        branch: try #require(BranchName("fix/thing")), expectedHead: try commit(),
        headline: "Fix the thing", body: "The body.",
        changes: [
            FileChange(path: "src/a.swift", contents: Data("let a = 1\n".utf8)),
            FileChange(path: "old.txt", contents: nil),
        ])
}

// One sample of each case.
private func samples() throws -> [GitHubWrite] {
    let click = UserClick()
    return [
        .createPendingReview(
            try key(), commit: try commit(), body: "Summary.", comments: [comment]),
        .addPendingThread(review: try node("PRR_1"), comment),
        .setPendingBody(review: try node("PRR_1"), body: "Summary."),
        .replyToThread(thread: try node("PRRT_1"), body: "Fixed by f7698d3"),
        .resolveThread(try node("PRRT_1")),
        .addPRComment(pr: try node("PR_1"), body: "> A request\n\nDone."),
        .requestReviews(pr: try node("PR_1"), users: [try node("U_1"), try node("U_2")]),
        .createSignedCommit(try signedCommit()),
        .approveCommit(pr: try node("PR_1"), commit: try commit(), click: click),
        .approveDraft(review: try node("PRR_1"), click: click),
        .editDraftBody(review: try node("PRR_1"), body: "New summary.", click: click),
        .editDraftComment(comment: try node("PRRC_1"), body: "New text.", click: click),
        .removeDraftComment(comment: try node("PRRC_1"), click: click),
        .discardDraft(review: try node("PRR_1"), click: click),
        .submitDraft(review: try node("PRR_1"), event: .comment, click: click),
        .submitDraft(review: try node("PRR_1"), event: .requestChanges, click: click),
        .rerunFailedJobs(try repo(), try #require(RunID(55)), consent: try consent()),
    ]
}

// The name of each case. The switch has no default, so a new case does not compile until it gets
// a name here and a sample above.
private func caseName(_ write: GitHubWrite) -> String {
    switch write {
    case .createPendingReview: "createPendingReview"
    case .addPendingThread: "addPendingThread"
    case .setPendingBody: "setPendingBody"
    case .replyToThread: "replyToThread"
    case .resolveThread: "resolveThread"
    case .addPRComment: "addPRComment"
    case .requestReviews: "requestReviews"
    case .createSignedCommit: "createSignedCommit"
    case .approveCommit: "approveCommit"
    case .approveDraft: "approveDraft"
    case .editDraftBody: "editDraftBody"
    case .editDraftComment: "editDraftComment"
    case .removeDraftComment: "removeDraftComment"
    case .discardDraft: "discardDraft"
    case .submitDraft: "submitDraft"
    case .rerunFailedJobs: "rerunFailedJobs"
    }
}

// The JSON on the stdin of gh.
private func stdin(_ write: GitHubWrite) throws -> [String: JSONValue] {
    try #require(try JSONDecoder().decode(JSONValue.self, from: write.input).object)
}

// The GraphQL text of a write.
private func query(_ write: GitHubWrite) throws -> String {
    try #require(try stdin(write)["query"]?.string)
}

// The variables of a write.
private func variables(_ write: GitHubWrite) throws -> [String: JSONValue] {
    try #require(try stdin(write)["variables"]?.object)
}

// The GraphQL names of a text: each run of letters, digits and "_".
private func names(_ text: String) -> [String] {
    text.split { !($0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_")) }.map(String.init)
}

@Suite("the GitHub writes", .testTimeLimit)
struct GitHubWriteTests {
    @Test func eachWriteNamesOnlyItsOwnMutation() throws {
        let writes = try samples()
        #expect(Set(writes.map(caseName)).count == 16)
        for write in writes {
            guard let mutation = write.mutation else {
                #expect(["createPendingReview", "rerunFailedJobs"].contains(caseName(write)))
                #expect(try stdin(write)["query"] == nil)
                #expect(!write.arguments.contains("graphql"))
                continue
            }
            #expect(write.arguments == ["api", "graphql", "--input", "-"])
            let words = names(try query(write))
            #expect(words.filter { $0 == "mutation" }.count == 1, "\(caseName(write))")
            let named = Set(words).intersection(allowed.union(never))
            #expect(named == [mutation], "\(caseName(write))")
        }
        #expect(Set(writes.compactMap(\.mutation)) == allowed)
    }

    @Test func onlyAConsentingStateMakesTheProof() throws {
        var state = ReviewsState()
        #expect(state.ciConsent(true) == nil)
        state.consentToCIFix()
        #expect(state.ciConsent(false) == nil)
        #expect(state.ciConsent(true) != nil)
        let write = GitHubWrite.rerunFailedJobs(
            try repo(), try #require(RunID(55)), consent: try #require(state.ciConsent(true)))
        #expect(write.mutation == nil)
        #expect(
            write.arguments == [
                "api", "--method", "POST", "repos/Owner-A/Repo-A/actions/runs/55/rerun-failed-jobs",
                "--input", "-",
            ])
        #expect(write.input == Data("{}".utf8))
    }

    @Test func noWriteMergesDismissesUnresolvesOrCloses() throws {
        for write in try samples() {
            let text = write.arguments.joined(separator: " ")
                + String(decoding: write.input, as: UTF8.self)
            let found = Set(names(text)).intersection(never.union(["DISMISS", "merge", "force"]))
            #expect(found.isEmpty, "\(caseName(write)): \(found)")
        }
    }

    @Test func thePendingReviewIsCreatedWithPostAndNoEvent() throws {
        let write = GitHubWrite.createPendingReview(
            try key(), commit: try commit(), body: "Summary.", comments: [comment])
        #expect(write.mutation == nil)
        #expect(
            write.arguments == [
                "api", "--method", "POST", "repos/Owner-A/Repo-A/pulls/7/reviews", "--input", "-",
            ])
        let body = try stdin(write)
        #expect(Set(body.keys) == ["commit_id", "body", "comments"])
        #expect(body["commit_id"] == .string(head))
        #expect(body["body"] == "Summary.")
        #expect(
            body["comments"] == [
                ["path": "src/a.swift", "line": 12, "side": "RIGHT", "body": "Nit."]
            ])
        // With no summary and no comments, the keys go, and still no event.
        let empty = GitHubWrite.createPendingReview(
            try key(), commit: try commit(), body: " ", comments: [])
        #expect(Set(try stdin(empty).keys) == ["commit_id"])
    }

    @Test func eachApprovalHasTheEventApprove() throws {
        let click = UserClick()
        let approvals: [GitHubWrite] = [
            .approveCommit(pr: try node("PR_1"), commit: try commit(), click: click),
            .approveDraft(review: try node("PRR_1"), click: click),
        ]
        for write in approvals {
            let text = try query(write)
            #expect(text.contains("event: APPROVE"))
            #expect(!text.contains("$event"))
            #expect(try variables(write)["event"] == nil)
        }
        #expect(
            try variables(approvals[0]) == ["pr": "PR_1", "commit": .string(head)])
        #expect(try variables(approvals[1]) == ["review": "PRR_1"])
    }

    @Test func eachDraftSubmitHasItsOwnEvent() throws {
        let review = try node("PRR_1")
        let events: [(DraftEvent, String)] = [
            (.comment, "COMMENT"), (.requestChanges, "REQUEST_CHANGES"),
        ]
        for (event, word) in events {
            let write = GitHubWrite.submitDraft(review: review, event: event, click: UserClick())
            #expect(write.mutation == "submitPullRequestReview")
            let text = try query(write)
            let used = Set(names(text)).intersection(["APPROVE", "COMMENT", "REQUEST_CHANGES"])
            #expect(used == [word])
            #expect(text.contains("event: \(word)"))
            #expect(try variables(write) == ["review": "PRR_1"])
        }
    }

    @Test func theSignedCommitExpectsTheHeadOfTheRound() throws {
        let write = GitHubWrite.createSignedCommit(try signedCommit())
        #expect(write.mutation == "createCommitOnBranch")
        let input = try #require(try variables(write)["input"]?.object)
        #expect(input["expectedHeadOid"] == .string(head))
        #expect(
            input["branch"] == [
                "repositoryNameWithOwner": "Owner-A/Repo-A", "branchName": "fix/thing",
            ])
        #expect(input["message"] == ["headline": "Fix the thing", "body": "The body."])
        let encoded = Data("let a = 1\n".utf8).base64EncodedString()
        #expect(
            input["fileChanges"] == [
                "additions": [["path": "src/a.swift", "contents": .string(encoded)]],
                "deletions": [["path": "old.txt"]],
            ])
    }

    // The other writes put each value in a variable, never in the text, and take the fields of
    // the GraphQL input that GitHub documents.
    @Test func eachValueGoesInAVariable() throws {
        let writes = try samples()
        #expect(
            try variables(writes[1]) == [
                "review": "PRR_1", "path": "src/a.swift", "line": 12, "side": "RIGHT",
                "body": "Nit.",
            ])
        #expect(try variables(writes[2]) == ["review": "PRR_1", "body": "Summary."])
        #expect(try variables(writes[3]) == ["thread": "PRRT_1", "body": "Fixed by f7698d3"])
        #expect(try variables(writes[4]) == ["thread": "PRRT_1"])
        #expect(try variables(writes[5]) == ["subject": "PR_1", "body": "> A request\n\nDone."])
        #expect(try variables(writes[6]) == ["pr": "PR_1", "users": ["U_1", "U_2"]])
        #expect(try query(writes[6]).contains("union: true"))
        #expect(try variables(writes[10]) == ["review": "PRR_1", "body": "New summary."])
        #expect(try variables(writes[11]) == ["comment": "PRRC_1", "body": "New text."])
        #expect(try variables(writes[12]) == ["comment": "PRRC_1"])
        #expect(try variables(writes[13]) == ["review": "PRR_1"])
    }
}
