import BifrostTestSupport
import Foundation
import Testing

@testable import BifrostReviews

// The read of a poll answer, with the sample answers of Fixtures/.

private func decoded(_ data: Data) throws -> PollAnswer {
    try PollAnswer.decode(data).get()
}

private func pull(_ list: [PullRequest], _ number: Int) throws -> PullRequest {
    try #require(list.first { $0.key.number == number })
}

private func time(_ text: String) throws -> Date {
    try Date(text, strategy: .iso8601)
}

// A change of the newest commit of the PR with this number in a list of a poll answer.
private func editCommit(
    _ root: inout [String: Any], list: String, number: Int,
    _ change: (inout [String: Any]) -> Void
) {
    editPR(&root, list: list, number: number) { node in
        var commits = node["commits"] as? [String: Any] ?? [:]
        var items = commits["nodes"] as? [[String: Any]] ?? []
        var commit = items[0]["commit"] as? [String: Any] ?? [:]
        change(&commit)
        items[0]["commit"] = commit
        commits["nodes"] = items
        node["commits"] = commits
    }
}

// A change of the list of checks (the contexts object) of the PR with this number.
private func editContexts(
    _ root: inout [String: Any], list: String, number: Int,
    _ change: (inout [String: Any]) -> Void
) {
    editCommit(&root, list: list, number: number) { commit in
        var rollup = commit["statusCheckRollup"] as? [String: Any] ?? [:]
        var contexts = rollup["contexts"] as? [String: Any] ?? [:]
        change(&contexts)
        rollup["contexts"] = contexts
        commit["statusCheckRollup"] = rollup
    }
}

// A change of the check nodes of the PR with this number in a list of a poll answer.
private func editChecks(
    _ root: inout [String: Any], list: String, number: Int,
    _ change: (inout [Any]) -> Void
) {
    editContexts(&root, list: list, number: number) { contexts in
        var nodes = contexts["nodes"] as? [Any] ?? []
        change(&nodes)
        contexts["nodes"] = nodes
    }
}

// The node of a check run of an app, with the given IDs. A nil value is JSON null.
private func run(
    _ name: String, app: String, job: Int?, run: Int?, conclusion: String = "FAILURE"
) -> [String: Any] {
    [
        "__typename": "CheckRun", "name": name, "status": "COMPLETED", "conclusion": conclusion,
        "databaseId": job.map { $0 as Any } ?? NSNull(), "detailsUrl": NSNull(),
        "checkSuite": [
            "app": ["slug": app],
            "workflowRun": run.map { ["databaseId": $0] as Any } ?? NSNull(),
        ],
    ]
}

// The GraphQL names of a query text: its fields, arguments, types and words.
private func names(_ text: String) -> Set<String> {
    Set(
        text.split { !($0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_")) }
            .map(String.init).filter { $0.first?.isLetter == true || $0.first == "_" })
}

private let mineHead = String(repeating: "a1", count: 20)

// The faults of the searches and of the lists of a PR. poll-basic has the check fields of an
// earlier query, so a test of these lists on it compares only these faults.
private let listFaults: Set<WireFault> = [
    .toReview, .mine, .reviews, .comments, .opinions, .threads, .threadComments,
]

private func lists(_ answer: PollAnswer) -> [WireFault] {
    answer.faults.filter(listFaults.contains)
}

@Suite("the poll answer", .testTimeLimit)
struct PollAnswerTests {
    @Test func theBasicAnswerGivesBothLists() throws {
        let answer = try decoded(FixtureFiles.data("poll-basic"))
        #expect(answer.viewer == "viewer-a")
        #expect(
            answer.toReview.map(\.key.text)
                == ["owner-a/repo-b#101", "owner-a/repo-a#7", "owner-a/repo-b#102"])
        #expect(answer.mine.map(\.key.text) == ["owner-a/repo-b#90", "owner-a/repo-a#31"])
        #expect(!answer.toReviewCut && !answer.mineCut)
        #expect(answer.errors.isEmpty && answer.dropped == 0 && lists(answer).isEmpty)

        let first = try pull(answer.toReview, 101)
        #expect(first.title == "Add search box")
        #expect(first.author == "user-a")
        #expect(first.headRef == "feature-101" && first.baseRef == "main")
        #expect(first.headSHA == "aaaa111" && first.ci == .passed)
        #expect(first.url.absoluteString == "https://github.com/owner-a/repo-b/pull/101")
        #expect(first.reviews.isEmpty && first.threads.isEmpty && first.decisions.isEmpty)
        #expect(try pull(answer.toReview, 102).reviewDecision == .approved)
    }

    @Test func aMyPRCarriesItsConversation() throws {
        let answer = try decoded(FixtureFiles.data("poll-basic"))
        let changes = try pull(answer.mine, 90)
        #expect(changes.reviewDecision == .changesRequested)
        #expect(changes.reviews.map(\.state) == [.changesRequested, .commented])
        #expect(changes.decisions.map(\.id.text) == ["R_c1"])
        #expect(
            changes.reviews[0].author
                == Author(login: "user-e", isBot: false, association: .member))
        #expect(Authors.isCopilot(changes.reviews[1].author))
        let thread = try #require(changes.threads.first)
        #expect(thread.id.text == "T_1" && thread.line == 42 && !thread.isResolved)
        #expect(thread.reviewID?.text == "R_c2")
        #expect(thread.comments.map(\.body) == ["Possible null here."])
        #expect(changes.comments.map(\.body) == ["Thanks for the update."])
        // One failed check run, and the rollup is failed too.
        #expect(changes.failedChecks == 1 && changes.ci == .failing)
        #expect(changes.viewerPendingReviewID == nil)

        let approved = try pull(answer.mine, 31)
        #expect(approved.viewerPendingReviewID?.text == "R_p1")
        #expect(approved.threads.first?.isResolved == true && approved.threads.first?.line == nil)
        #expect(approved.failedChecks == 0)
    }

    @Test func aCutListIsMarkedCut() throws {
        let marked = try FixtureFiles.edited("poll-basic") { root in
            edit(&root, list: "toReview") { $0["pageInfo"] = ["hasNextPage": true] }
        }
        let answer = try decoded(marked)
        #expect(answer.toReviewCut && !answer.mineCut)
        #expect(answer.toReview.count == 3)
    }

    @Test func aCutListOfOnePRIsMarkedOnThatPR() throws {
        let answer = try decoded(FixtureFiles.data("poll-truncated"))
        let pr = try pull(answer.mine, 200)
        #expect(pr.truncatedThreads)
        #expect(!pr.truncatedReviews && !pr.truncatedComments && !pr.truncatedChecks)
        #expect(!answer.mineCut)
    }

    @Test func anAnswerWithDataAndErrorsKeepsTheData() throws {
        let partial = try FixtureFiles.edited("poll-basic") { root in
            root["errors"] = [
                ["message": "Could not resolve a team."], ["message": "Could not resolve a team."],
                ["message": "  \u{202E}Second\u{200B} problem\n"], [:],
                ["message": String(repeating: "x", count: 300)],
            ]
        }
        let answer = try decoded(partial)
        #expect(answer.toReview.count == 3 && answer.mine.count == 2)
        #expect(answer.errors.count == 4)
        #expect(answer.errors[0] == "Could not resolve a team.")
        #expect(answer.errors[1] == "Second problem")
        #expect(answer.errors[2] == "GitHub gave an error.")
        #expect(answer.errors[3].count == 200)
    }

    @Test func anAnswerWithNoDataFails() throws {
        let denied = Data(#"{"data":null,"errors":[{"message":"Bad credentials"}]}"#.utf8)
        #expect(PollAnswer.decode(denied) == .failure(.refused("Bad credentials")))

        // A missing list next to errors is no usable data, even with a viewer.
        let noMine = Data(
            #"{"data":{"viewer":{"login":"a"},"toReview":{"nodes":[]}},"errors":[{}]}"#.utf8)
        #expect(PollAnswer.decode(noMine) == .failure(.refused("GitHub gave an error.")))

        #expect(PollAnswer.decode(Data("not json".utf8)) == .failure(.badAnswer))
        #expect(PollAnswer.decode(Data()) == .failure(.badAnswer))
        let noViewer = Data(#"{"data":{"toReview":{"nodes":[]}}}"#.utf8)
        #expect(PollAnswer.decode(noViewer) == .failure(.badAnswer))
        #expect(PollAnswer.decode(Data(#"{}"#.utf8)) == .failure(.badAnswer))
    }

    @Test func oneBadPullRequestIsDropped() throws {
        let broken = try FixtureFiles.edited("poll-basic") { root in
            edit(&root, list: "toReview") { search in
                var nodes = search["nodes"] as? [[String: Any]] ?? []
                // 7 gets a name that could leave the folder of the clones.
                nodes[1]["repository"] = ["name": "..", "owner": ["login": "owner-a"]]
                // 102 gets a number that GitHub never gives.
                nodes[2]["number"] = 0
                search["nodes"] = nodes + [[:], ["number": "abc"]]
            }
        }
        let answer = try decoded(broken)
        #expect(answer.toReview.map(\.key.number) == [101])
        #expect(answer.dropped == 4)
        #expect(answer.mine.count == 2)
    }

    @Test func aTeamRequestIsToldApartFromADirectOne() throws {
        let answer = try decoded(FixtureFiles.data("poll-basic"))
        let both = try pull(answer.toReview, 101)
        #expect(both.isDirectRequest)
        #expect(both.requestedUsers == ["viewer-a"] && both.requestedTeams == ["team-b"])
        let team = try pull(answer.toReview, 7)
        #expect(!team.isDirectRequest)
        #expect(team.requestedUsers == ["user-c"] && team.requestedTeams == ["team-a"])
        #expect(try pull(answer.toReview, 102).isDirectRequest)
    }

    @Test func theRequestTimeIsTheNewestEventOrTheCreationTime() throws {
        let answer = try decoded(FixtureFiles.data("poll-basic"))
        // A direct request: the newer of the two events for the viewer.
        #expect(try pull(answer.toReview, 101).requestedAt == time("2026-11-05T12:30:00Z"))
        // A team request: the team event.
        #expect(try pull(answer.toReview, 7).requestedAt == time("2026-11-04T08:00:00Z"))
        // No event: the creation time.
        let none = try pull(answer.toReview, 102)
        #expect(none.requestedAt == none.createdAt)

        // A newer team event does not move a direct request, and an event for another user
        // does not either.
        let later = try FixtureFiles.edited("poll-basic") { root in
            edit(&root, list: "toReview") { search in
                var nodes = search["nodes"] as? [[String: Any]] ?? []
                let items = nodes[0]["timelineItems"] as? [String: Any]
                var events = items?["nodes"] as? [[String: Any]] ?? []
                events.append([
                    "createdAt": "2026-11-09T00:00:00Z",
                    "requestedReviewer": ["__typename": "Team", "slug": "team-b"],
                ])
                events.append([
                    "createdAt": "2026-11-09T01:00:00Z",
                    "requestedReviewer": ["__typename": "User", "login": "user-c"],
                ])
                nodes[0]["timelineItems"] = ["nodes": events]
                search["nodes"] = nodes
            }
        }
        #expect(try pull(decoded(later).toReview, 101).requestedAt == time("2026-11-05T12:30:00Z"))
    }

    @Test func theViewerOpinionAndTheApprovalsOfOthersComeFromTheLatestReviews() throws {
        let opinions = try FixtureFiles.edited("poll-basic") { root in
            edit(&root, list: "toReview") { search in
                var nodes = search["nodes"] as? [[String: Any]] ?? []
                func review(_ id: String, _ login: String, _ state: String) -> [String: Any] {
                    [
                        "id": id, "author": ["__typename": "User", "login": login], "state": state,
                        "submittedAt": "2026-11-06T10:00:00Z", "commit": ["oid": "aaaa111"],
                    ]
                }
                nodes[0]["latestOpinionatedReviews"] = [
                    "nodes": [
                        review("R_1", "Viewer-A", "APPROVED"), review("R_2", "user-x", "APPROVED"),
                        review("R_3", "user-y", "CHANGES_REQUESTED"),
                        review("R_4", "user-z", "APPROVED"),
                    ]
                ]
                search["nodes"] = nodes
            }
        }
        let first = try pull(decoded(opinions).toReview, 101)
        let submitted = try time("2026-11-06T10:00:00Z")
        #expect(
            first.viewerReviews
                == [ViewerOpinion(state: .approved, commit: "aaaa111", submittedAt: submitted)])
        #expect(first.approvals == 2)
        #expect(first.decisions.isEmpty)
    }

    @Test func aFieldOfTheWrongTypeReadsAsMissingAndTheRestStays() throws {
        let odd = try FixtureFiles.edited("poll-basic") { root in
            editPR(&root, list: "toReview", number: 101) {
                $0["title"] = 5
                $0["reviews"] = "x"
                $0["isDraft"] = "yes"
                $0["headRefName"] = ["a"]
            }
        }
        let first = try pull(decoded(odd).toReview, 101)
        #expect(first.title == "" && !first.isDraft && first.headRef == "")
        #expect(first.headSHA == "aaaa111" && first.requestedUsers == ["viewer-a"])
        #expect(try decoded(odd).dropped == 0 && decoded(odd).toReview.count == 3)
    }

    @Test func aMissingListIsMarkedCut() throws {
        let noMine = try FixtureFiles.edited("poll-basic") { root in
            var data = root["data"] as? [String: Any] ?? [:]
            data["mine"] = nil
            data["toReview"] = "not a list"
            root["data"] = data
        }
        let answer = try decoded(noMine)
        #expect(answer.mineCut && answer.toReviewCut)
        #expect(answer.mine.isEmpty && answer.toReview.isEmpty)
    }

    @Test func aResultForAnotherCommitThanTheHeadCountsAsRunning() throws {
        let moved = try FixtureFiles.edited("poll-basic") { root in
            editPR(&root, list: "mine", number: 31) { $0["headRefOid"] = "dddd444" }
        }
        #expect(try pull(decoded(moved).mine, 31).ci == .running)
        // The same result for the head itself is a pass.
        #expect(try pull(decoded(FixtureFiles.data("poll-basic")).mine, 31).ci == .passed)
    }

    @Test func aFailedRollupWithNoFailedCheckInThePageCountsOneFailedCheck() throws {
        let hidden = try FixtureFiles.edited("poll-basic") { root in
            editPR(&root, list: "mine", number: 31) { node in
                var commits = node["commits"] as? [String: Any] ?? [:]
                var items = commits["nodes"] as? [[String: Any]] ?? []
                var commit = items[0]["commit"] as? [String: Any] ?? [:]
                var rollup = commit["statusCheckRollup"] as? [String: Any] ?? [:]
                rollup["state"] = "ERROR"
                commit["statusCheckRollup"] = rollup
                items[0]["commit"] = commit
                commits["nodes"] = items
                node["commits"] = commits
            }
        }
        let pr = try pull(decoded(hidden).mine, 31)
        #expect(pr.failedChecks == 1 && pr.ci == .failing)
    }

    @Test func eachListOfAPRMarksItsOwnCut() throws {
        func marked(_ field: String, _ flag: String) throws -> PullRequest {
            let data = try FixtureFiles.edited("poll-basic") { root in
                editPR(&root, list: "mine", number: 31) { node in
                    var list = node[field] as? [String: Any] ?? [:]
                    list["pageInfo"] = [flag: true]
                    node[field] = list
                }
            }
            return try pull(decoded(data).mine, 31)
        }
        let reviews = try marked("reviews", "hasNextPage")
        #expect(reviews.truncatedReviews && !reviews.truncatedComments && !reviews.truncatedThreads)
        let opinions = try marked("latestOpinionatedReviews", "hasNextPage")
        #expect(opinions.truncatedReviews && !opinions.truncatedComments)
        let comments = try marked("comments", "hasPreviousPage")
        #expect(comments.truncatedComments && !comments.truncatedReviews)
        let threads = try marked("reviewThreads", "hasPreviousPage")
        #expect(threads.truncatedThreads && !threads.truncatedComments)
    }

    @Test func aThreadWithMoreCommentsMarksTheThreadsCut() throws {
        let data = try FixtureFiles.edited("poll-basic") { root in
            editPR(&root, list: "mine", number: 31) { node in
                var threads = node["reviewThreads"] as? [String: Any] ?? [:]
                var items = threads["nodes"] as? [[String: Any]] ?? []
                var comments = items[0]["comments"] as? [String: Any] ?? [:]
                comments["pageInfo"] = ["hasNextPage": true]
                items[0]["comments"] = comments
                threads["nodes"] = items
                node["reviewThreads"] = threads
            }
        }
        #expect(try pull(decoded(data).mine, 31).truncatedThreads)
    }

    @Test func moreChecksThanThePageMarkTheChecksCut() throws {
        let data = try FixtureFiles.edited("poll-basic") { root in
            editPR(&root, list: "mine", number: 31) { node in
                var commits = node["commits"] as? [String: Any] ?? [:]
                var items = commits["nodes"] as? [[String: Any]] ?? []
                var commit = items[0]["commit"] as? [String: Any] ?? [:]
                var rollup = commit["statusCheckRollup"] as? [String: Any] ?? [:]
                var contexts = rollup["contexts"] as? [String: Any] ?? [:]
                contexts["pageInfo"] = ["hasNextPage": true]
                rollup["contexts"] = contexts
                commit["statusCheckRollup"] = rollup
                items[0]["commit"] = commit
                commits["nodes"] = items
                node["commits"] = commits
            }
        }
        let pr = try pull(decoded(data).mine, 31)
        #expect(pr.truncatedChecks && !pr.truncatedReviews)
    }

    @Test func theQueryAddsOnlyTheNewFields() throws {
        let query = PollQuery.query
        #expect(query.isRead)
        let text = query.text
        let mineStart = try #require(text.range(of: "fragment MineFields"))
        let toReviewStart = try #require(text.range(of: "fragment ToReviewFields"))
        let toReview = String(text[toReviewStart.lowerBound..<mineStart.lowerBound])
        let mine = String(text[mineStart.lowerBound...])
        // The merge state and the base commit: only a PR of the user.
        #expect(mine.contains("mergeable baseRefOid"))
        #expect(!toReview.contains("mergeable") && !toReview.contains("baseRefOid"))
        #expect(text.components(separatedBy: "mergeable").count == 2)
        // My PRs reads 50 checks, To review 20, and both read the same check fields.
        #expect(mine.contains("contexts(first: 50)") && !mine.contains("contexts(first: 20)"))
        #expect(
            toReview.contains("contexts(first: 20)") && !toReview.contains("contexts(first: 50)"))
        for part in [
            "name status conclusion databaseId detailsUrl",
            "checkSuite { app { slug } workflowRun { databaseId } }",
            "... on StatusContext { context state targetUrl }",
        ] {
            #expect(mine.contains(part) && toReview.contains(part), "\(part)")
        }
        // Each other name is a name of the earlier query: GitHub must know each new one.
        let earlier: Set<String> = [
            "query", "Poll", "toReview", "String", "mine", "viewer", "login", "search", "type",
            "ISSUE", "first", "pageInfo", "hasNextPage", "nodes", "on", "PullRequest",
            "ToReviewFields", "MineFields", "fragment", "number", "title", "isDraft", "additions",
            "deletions", "createdAt", "updatedAt", "repository", "name", "owner", "author",
            "reviewDecision", "reviewRequests", "requestedReviewer", "__typename", "User", "Team",
            "slug", "timelineItems", "last", "itemTypes", "REVIEW_REQUESTED_EVENT",
            "ReviewRequestedEvent", "pendingReviews", "reviews", "states", "PENDING", "id",
            "latestOpinionatedReviews", "authorAssociation", "state", "submittedAt", "commit",
            "oid", "databaseId", "body", "url", "reviewThreads", "hasPreviousPage", "isResolved",
            "path", "line", "comments", "pullRequestReview", "commits", "statusCheckRollup",
            "contexts", "CheckRun", "conclusion", "StatusContext", "headRefName", "headRefOid",
            "baseRefName", "isCrossRepository",
        ]
        let added: Set<String> = [
            "mergeable", "baseRefOid", "status", "detailsUrl", "checkSuite", "app", "workflowRun",
            "context", "targetUrl",
        ]
        #expect(names(text) == earlier.union(added))
    }

    @Test func aMinePRReadsMergeableTheBaseCommitAndTheFailedJobs() throws {
        let answer = try decoded(FixtureFiles.data("poll-mine-health"))
        #expect(answer.faults.isEmpty && answer.dropped == 0)
        let pr = try pull(answer.mine, 55)
        #expect(pr.mergeable == .conflicting)
        #expect(pr.baseSHA == String(repeating: "b2", count: 20))
        #expect(pr.headSHA == mineHead)
        let checks = pr.checks
        #expect(checks.onHead && !checks.cut && checks.settled)
        let build = HeadCheck(
            name: "build", outcome: .failed("FAILURE"),
            source: .actions(job: try #require(JobID(101)), run: try #require(RunID(9001))),
            url: URL(string: "https://github.com/owner-a/repo-a/actions/runs/9001/job/101"))
        // A cancelled job is a failed check, but no CI round acts on it.
        #expect(checks.failedJobs == [build])
        #expect(checks.jobKey == [try #require(JobID(101))])
        let order = ["lint", "build", "deploy", "Preview", "ci/legacy", "docs"]
        #expect(checks.checks.map(\.name) == order)
        #expect(checks.checks[0].outcome == .passed)
        #expect(checks.checks[2].outcome == .failed("CANCELLED"))
        // The rules of the failed count and of the CI state stay.
        #expect(pr.failedChecks == 4 && pr.ci == .failing)
    }

    @Test func aToReviewPRReadsNoMergeableState() throws {
        let data = try FixtureFiles.edited("poll-mine-health") { root in
            editPR(&root, list: "toReview", number: 12) { $0["mergeable"] = "CONFLICTING" }
        }
        let answer = try decoded(data)
        let pr = try pull(answer.toReview, 12)
        #expect(pr.mergeable == nil && pr.baseSHA == "")
        #expect(answer.faults.isEmpty)
        // A To review PR reads its checks too. A job that runs keeps the checks unsettled.
        #expect(pr.checks.onHead && !pr.checks.settled && pr.checks.failedJobs.isEmpty)
        #expect(pr.checks.checks.map(\.outcome) == [.running])
        #expect(pr.ci == .running)
    }

    @Test func aCheckOfAnotherAppOrAStatusIsNotAnActionsJob() throws {
        let data = try FixtureFiles.edited("poll-mine-health") { root in
            editChecks(&root, list: "mine", number: 55) { nodes in
                nodes.append(run("no-run", app: "github-actions", job: 104, run: nil))
                nodes.append(run("no-job", app: "github-actions", job: nil, run: 9001))
                nodes.append(run("other", app: "other-ci", job: 105, run: 9001))
            }
        }
        let answer = try decoded(data)
        let checks = try pull(answer.mine, 55).checks
        #expect(checks.jobKey == [try #require(JobID(101))])
        #expect(checks.others.map(\.name) == ["Preview", "ci/legacy", "no-run", "no-job", "other"])
        #expect(checks.others.map(\.source) == [
            .app("preview-app"), .status, .app("github-actions"), .app("github-actions"),
            .app("other-ci"),
        ])
        #expect(checks.others[0].url?.absoluteString == "https://preview.example.com/builds/5005")
        #expect(checks.others[1].url?.absoluteString == "https://ci.example.com/jobs/77")
        // A job of GitHub Actions without its IDs is logged.
        #expect(answer.faults == [.runID, .jobID])
    }

    @Test func aBadCheckFieldKeepsThePR() throws {
        let data = try FixtureFiles.edited("poll-mine-health") { root in
            editPR(&root, list: "mine", number: 55) { node in
                node["mergeable"] = "SOMETIMES"
                node["baseRefOid"] = 7
            }
            editChecks(&root, list: "mine", number: 55) { nodes in
                var lint = nodes[0] as? [String: Any] ?? [:]
                lint["status"] = 5
                lint["conclusion"] = NSNull()
                nodes[0] = lint
                var build = nodes[1] as? [String: Any] ?? [:]
                build["databaseId"] = "101"
                build["detailsUrl"] = "javascript:alert(1)"
                nodes[1] = build
                var status = nodes[4] as? [String: Any] ?? [:]
                status["state"] = ["ERROR"]
                nodes[4] = status
                nodes.append(NSNull())
                nodes.append(["__typename": "NewKind", "name": "x"])
            }
        }
        let answer = try decoded(data)
        #expect(answer.dropped == 0 && answer.mine.count == 1)
        let pr = try pull(answer.mine, 55)
        #expect(pr.title == "Move the parser" && pr.headSHA == mineHead)
        #expect(pr.mergeable == nil && pr.baseSHA == "")
        // The bad check fields read as missing: no job to act on, and nothing looks settled.
        let checks = pr.checks
        #expect(checks.checks.count == 6 && checks.cut && !checks.settled)
        #expect(checks.checks[0].outcome == .running && checks.checks[4].outcome == .running)
        #expect(checks.failedJobs.isEmpty && checks.checks[1].url == nil)
        #expect(checks.checks[1].source == .app("github-actions"))
        #expect(
            answer.faults == [
                .jobID, .checkRunStatus, .statusState, .baseRefOid, .checkNode, .mergeable,
            ])
    }

    @Test func aRollupWithNoReadableChecksIsCut() throws {
        let data = try FixtureFiles.edited("poll-mine-health") { root in
            editPR(&root, list: "mine", number: 55) { node in
                var commits = node["commits"] as? [String: Any] ?? [:]
                var items = commits["nodes"] as? [[String: Any]] ?? []
                var commit = items[0]["commit"] as? [String: Any] ?? [:]
                commit["statusCheckRollup"] = ["state": "FAILURE", "contexts": "none"]
                items[0]["commit"] = commit
                commits["nodes"] = items
                node["commits"] = commits
            }
        }
        let answer = try decoded(data)
        let pr = try pull(answer.mine, 55)
        #expect(pr.checks.checks.isEmpty && pr.checks.cut && !pr.checks.settled)
        #expect(pr.failedChecks == 1)
        #expect(answer.faults == [.contexts])

        // With no rollup the head has no checks, and the empty list is settled.
        let none = try FixtureFiles.edited("poll-mine-health") { root in
            editPR(&root, list: "mine", number: 55) { node in
                node["commits"] = ["nodes": [["commit": ["oid": mineHead]]]]
            }
        }
        let bare = try pull(decoded(none).mine, 55)
        #expect(bare.checks == HeadChecks(checks: [], cut: false, onHead: true))
        #expect(bare.checks.settled)
    }

    @Test func aJobIDAboveThe32BitRangeKeepsItsValue() throws {
        // GitHub gives these IDs in full, although the schema says Int.
        let job = 135_562_930_272, run = 44_524_952_431
        let page = "https://github.com/owner-a/repo-a/actions/runs/\(run)/job/\(job)"
        let data = try FixtureFiles.edited("poll-mine-health") { root in
            editChecks(&root, list: "mine", number: 55) { nodes in
                var build = nodes[1] as? [String: Any] ?? [:]
                build["databaseId"] = job
                build["detailsUrl"] = page
                build["checkSuite"] = [
                    "app": ["slug": "github-actions"], "workflowRun": ["databaseId": run],
                ]
                nodes[1] = build
            }
        }
        let answer = try decoded(data)
        let checks = try pull(answer.mine, 55).checks
        let failed = try #require(checks.failedJobs.first)
        let ids = (job: try #require(JobID(job)), run: try #require(RunID(run)))
        #expect(failed.source == .actions(job: ids.job, run: ids.run))
        #expect(failed.job?.value == 135_562_930_272 && checks.jobKey.count == 1)
        #expect(answer.faults.isEmpty)

        // A null databaseId leaves the job status only, also with a good link.
        let noID = try FixtureFiles.edited("poll-mine-health") { root in
            editChecks(&root, list: "mine", number: 55) { nodes in
                var build = nodes[1] as? [String: Any] ?? [:]
                build["databaseId"] = NSNull()
                nodes[1] = build
            }
        }
        let bare = try decoded(noID)
        let build = try #require(try pull(bare.mine, 55).checks.checks.first { $0.name == "build" })
        #expect(build.source == .app("github-actions") && build.url != nil)
        #expect(try pull(bare.mine, 55).checks.failedJobs.isEmpty)
        #expect(bare.faults == [.jobID])
    }

    @Test func aCheckListWithNoNodesIsUnknownNotEmpty() throws {
        func read(_ change: (inout [String: Any]) -> Void) throws -> PollAnswer {
            try decoded(
                FixtureFiles.edited("poll-mine-health") { root in
                    editContexts(&root, list: "mine", number: 55, change)
                })
        }
        // GitHub sends nodes null, with an error, when it can't list the checks.
        for answer in [
            try read { $0["nodes"] = NSNull() }, try read { $0["nodes"] = nil },
            try read { $0["nodes"] = "none" },
        ] {
            let pr = try pull(answer.mine, 55)
            #expect(pr.checks.checks.isEmpty && pr.checks.cut && !pr.checks.settled)
            #expect(pr.checks.failedJobs.isEmpty && pr.truncatedChecks)
            #expect(answer.faults == [.contextsNodes])
            // The rollup state still counts one failed check.
            #expect(pr.failedChecks == 1 && pr.ci == .failing)
        }
        // A full page with no readable page info can lack checks too.
        for answer in [
            try read { $0["pageInfo"] = nil }, try read { $0["pageInfo"] = [String: Any]() },
            try read { $0["pageInfo"] = ["hasNextPage": "no"] },
        ] {
            let checks = try pull(answer.mine, 55).checks
            #expect(checks.checks.count == 6 && checks.cut && !checks.settled)
            #expect(answer.faults == [.contextsPageInfo])
        }
    }

    @Test func aRollupOfTheWrongTypeIsUnknownNotEmpty() throws {
        let data = try FixtureFiles.edited("poll-mine-health") { root in
            editCommit(&root, list: "mine", number: 55) { $0["statusCheckRollup"] = "FAILURE" }
        }
        let answer = try decoded(data)
        let pr = try pull(answer.mine, 55)
        #expect(pr.checks.checks.isEmpty && pr.checks.cut && !pr.checks.settled)
        #expect(answer.faults == [.rollup])
        // A null rollup is a head with no checks: settled, with no fault.
        let none = try FixtureFiles.edited("poll-mine-health") { root in
            editCommit(&root, list: "mine", number: 55) { $0["statusCheckRollup"] = NSNull() }
        }
        let bare = try decoded(none)
        #expect(try pull(bare.mine, 55).checks.settled && bare.faults.isEmpty)
    }

    @Test func aSearchWithNoNodesOrPageInfoIsCut() throws {
        let noNodes = try FixtureFiles.edited("poll-basic") { root in
            edit(&root, list: "mine") { $0["nodes"] = NSNull() }
        }
        let empty = try decoded(noNodes)
        #expect(empty.mineCut && empty.mine.isEmpty && !empty.toReviewCut)
        #expect(lists(empty) == [.mine])
        let noInfo = try FixtureFiles.edited("poll-basic") { root in
            edit(&root, list: "toReview") { $0["pageInfo"] = nil }
        }
        let full = try decoded(noInfo)
        #expect(full.toReviewCut && full.toReview.count == 3 && !full.mineCut)
        #expect(lists(full) == [.toReview])
    }

    @Test func aConversationListWithNoNodesIsMarkedCut() throws {
        let data = try FixtureFiles.edited("poll-basic") { root in
            editPR(&root, list: "mine", number: 31) { node in
                node["reviewThreads"] = ["nodes": NSNull(), "pageInfo": ["hasPreviousPage": false]]
                node["comments"] = nil
                node["reviews"] = ["nodes": [Any]()]
            }
        }
        let answer = try decoded(data)
        let pr = try pull(answer.mine, 31)
        #expect(pr.truncatedThreads && pr.truncatedComments && pr.truncatedReviews)
        #expect(pr.threads.isEmpty && pr.comments.isEmpty)
        #expect(lists(answer) == [.comments, .threads, .reviews])
        // A To review PR asks for the latest opinions, and a thread for its comments.
        let opinions = try FixtureFiles.edited("poll-basic") { root in
            editPR(&root, list: "toReview", number: 7) { $0["latestOpinionatedReviews"] = nil }
            editPR(&root, list: "mine", number: 90) { node in
                var threads = node["reviewThreads"] as? [String: Any] ?? [:]
                var items = threads["nodes"] as? [[String: Any]] ?? []
                items[0]["comments"] = ["nodes": [Any]()]
                threads["nodes"] = items
                node["reviewThreads"] = threads
            }
        }
        let other = try decoded(opinions)
        #expect(try pull(other.toReview, 7).truncatedReviews)
        #expect(try pull(other.mine, 90).truncatedThreads)
        #expect(lists(other) == [.opinions, .threadComments])
        // A To review PR does not ask for the conversation, so it is not cut for it.
        let toReview = try pull(decoded(FixtureFiles.data("poll-mine-health")).toReview, 12)
        #expect(!toReview.truncatedThreads && !toReview.truncatedComments)
        #expect(!toReview.truncatedReviews)
    }

    @Test func aMissingHeadCommitOrBranchIsLogged() throws {
        let data = try FixtureFiles.edited("poll-mine-health") { root in
            editPR(&root, list: "mine", number: 55) { node in
                node["headRefName"] = nil
                node["baseRefName"] = 3
            }
            editPR(&root, list: "toReview", number: 12) { node in
                node["commits"] = ["nodes": [Any]()]
                node["headRefOid"] = NSNull()
            }
        }
        let answer = try decoded(data)
        #expect(answer.faults == [.baseRefName, .commit, .headRefName, .headRefOid])
        #expect(try !pull(answer.toReview, 12).checks.onHead)
        // A commit with no ID is logged too.
        let noID = try FixtureFiles.edited("poll-mine-health") { root in
            editCommit(&root, list: "mine", number: 55) { $0["oid"] = nil }
        }
        let other = try decoded(noID)
        #expect(other.faults == [.commitOid])
        #expect(try !pull(other.mine, 55).checks.settled)
    }

    @Test func aSlugOfTheWrongTypeIsLogged() throws {
        let data = try FixtureFiles.edited("poll-mine-health") { root in
            editChecks(&root, list: "mine", number: 55) { nodes in
                var build = nodes[1] as? [String: Any] ?? [:]
                build["checkSuite"] = ["app": ["slug": 5], "workflowRun": ["databaseId": 9001]]
                nodes[1] = build
            }
        }
        let answer = try decoded(data)
        let checks = try pull(answer.mine, 55).checks
        #expect(checks.failedJobs.isEmpty && checks.others.first?.source == .app(""))
        #expect(answer.faults == [.appSlug])
    }
}
