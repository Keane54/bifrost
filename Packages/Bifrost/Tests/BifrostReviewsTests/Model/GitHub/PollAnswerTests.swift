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

@Suite("the poll answer", .timeLimit(.minutes(1)))
struct PollAnswerTests {
    @Test func theBasicAnswerGivesBothLists() throws {
        let answer = try decoded(FixtureFiles.data("poll-basic"))
        #expect(answer.viewer == "viewer-a")
        #expect(
            answer.toReview.map(\.key.text)
                == ["owner-a/repo-b#101", "owner-a/repo-a#7", "owner-a/repo-b#102"])
        #expect(answer.mine.map(\.key.text) == ["owner-a/repo-b#90", "owner-a/repo-a#31"])
        #expect(!answer.toReviewCut && !answer.mineCut)
        #expect(answer.errors.isEmpty && answer.dropped == 0)

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
}
