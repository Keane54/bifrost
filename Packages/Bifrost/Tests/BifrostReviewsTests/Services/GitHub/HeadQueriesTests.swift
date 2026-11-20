// The fresh read of the head of a PR (docs/behaviour/reviews.md, "The GitHub data"), with the
// GitHub of the tests: no gh and no network.
import BifrostTestSupport
import Foundation
import Testing

@testable import BifrostReviews

private let head = String(repeating: "c", count: 40)
private let base = String(repeating: "a", count: 40)
private let jobPage = "https://github.com/owner-a/repo-a/actions/runs/9001/job/101"

// The pull request of a head read, as GitHub gives it.
private func pullRequest() -> [String: Any] {
    [
        "state": "OPEN", "author": ["login": "viewer-a"],
        "repository": ["defaultBranchRef": ["name": "main"]],
        "mergeable": "CONFLICTING", "baseRefOid": base,
        "headRefName": "move-parser", "headRefOid": head, "baseRefName": "release",
        "isCrossRepository": false,
        "commits": [
            "nodes": [
                [
                    "commit": [
                        "oid": head,
                        "statusCheckRollup": [
                            "state": "FAILURE",
                            "contexts": [
                                "pageInfo": ["hasNextPage": false],
                                "nodes": [
                                    [
                                        "__typename": "CheckRun", "name": "build",
                                        "status": "COMPLETED", "conclusion": "FAILURE",
                                        "databaseId": 101, "detailsUrl": jobPage,
                                        "checkSuite": [
                                            "app": ["slug": "github-actions"],
                                            "workflowRun": ["databaseId": 9001],
                                        ],
                                    ],
                                    [
                                        "__typename": "StatusContext", "context": "ci/legacy",
                                        "state": "SUCCESS",
                                    ],
                                ],
                            ],
                        ],
                    ]
                ]
            ]
        ],
    ]
}

// The answer of GitHub with this pull request, and the errors when there are any.
private func answer(
    _ pull: Any = pullRequest(), errors: [[String: Any]]? = nil
) throws -> Data {
    var root: [String: Any] = ["data": ["repository": ["pullRequest": pull]]]
    if let errors { root["errors"] = errors }
    return try JSONSerialization.data(withJSONObject: root)
}

@MainActor
private func read(_ data: Data) async throws -> HeadRead {
    let github = FakeGitHub(answers: [HeadQueries.name: .success(data)])
    let pr = try #require(PRKey(text: "owner-a/repo-a#55"))
    return try await HeadQueries.read(pr, client: GitHubClient(access: github))
}

@MainActor
@Suite("the head read", .testTimeLimit)
struct HeadQueriesTests {
    @Test func theReadGivesTheHeadTheBaseAndTheChecks() async throws {
        let github = FakeGitHub(answers: [HeadQueries.name: .success(try answer())])
        let pr = try #require(PRKey(text: "owner-a/repo-a#55"))
        let fresh = try await HeadQueries.read(pr, client: GitHubClient(access: github))
        #expect(github.calls == [.read("pr-head")])
        #expect(fresh.state == .open && fresh.author == "viewer-a" && !fresh.isFork)
        #expect(fresh.headRef == "move-parser" && fresh.head.hex == head)
        #expect(fresh.baseRef == "release" && fresh.base?.hex == base)
        #expect(fresh.defaultBranch == "main" && fresh.mergeable == .conflicting)
        #expect(fresh.checks.onHead && fresh.checks.settled)
        #expect(fresh.checks.jobKey == [try #require(JobID(101))])
        #expect(fresh.checks.others.isEmpty && fresh.checks.checks.count == 2)

        // The push target comes from the fresh read.
        let target = try #require(PushTarget(fresh))
        #expect(target.branch.text == "move-parser" && target.base == "release")
        #expect(target.defaultBranch == "main" && !target.isFork)

        // A read with each value in a variable, and the check fields and limit of My PRs.
        let query = HeadQueries.query(pr)
        #expect(query.isRead && query.name == "pr-head")
        #expect(
            query.variables == [
                "owner": .string("owner-a"), "repo": .string("repo-a"), "number": .int(55),
            ])
        #expect(!query.text.contains("owner-a") && !query.text.contains("55"))
        for part in [
            "contexts(first: 50)", "name status conclusion databaseId detailsUrl",
            "checkSuite { app { slug } workflowRun { databaseId } }",
            "... on StatusContext { context state targetUrl }", "mergeable baseRefOid",
            "defaultBranchRef { name }", "headRefOid", "isCrossRepository",
        ] {
            #expect(query.text.contains(part), "\(part)")
        }
    }

    @Test func aReadWithNoHeadIsABadAnswer() async throws {
        func without(_ field: String) throws -> Data {
            var pull = pullRequest()
            pull[field] = nil
            return try answer(pull)
        }
        for field in ["headRefOid", "state", "isCrossRepository"] {
            await #expect(throws: GitHubError.badAnswer, "\(field)") {
                try await read(without(field))
            }
        }
        var short = pullRequest()
        short["headRefOid"] = "abc1234"
        await #expect(throws: GitHubError.badAnswer) { try await read(answer(short)) }
        var unknown = pullRequest()
        unknown["state"] = "DRAFTED"
        await #expect(throws: GitHubError.badAnswer) { try await read(answer(unknown)) }
        await #expect(throws: GitHubError.badAnswer) { try await read(answer(NSNull())) }
        await #expect(throws: GitHubError.badAnswer) { try await read(Data("[]".utf8)) }

        // With errors and no PR, the read fails with the error of GitHub.
        let denied = try answer(NSNull(), errors: [["message": "Could not resolve to a PR."]])
        await #expect(throws: GitHubError.refused("Could not resolve to a PR.")) {
            try await read(denied)
        }
    }

    @Test func anErrorNextToAFullHeadKeepsTheRead() async throws {
        var pull = pullRequest()
        pull["mergeable"] = NSNull()
        pull["baseRefOid"] = NSNull()
        let data = try answer(pull, errors: [["message": "Something went wrong."]])
        let fresh = try await read(data)
        #expect(fresh.head.hex == head && fresh.mergeable == nil && fresh.base == nil)
        #expect(fresh.checks.jobKey.count == 1)

        let decoded = try HeadAnswer.decode(data).get()
        #expect(decoded.errors == ["Something went wrong."])
        #expect(decoded.faults == [.baseRefOid, .mergeable])
    }

    @Test func aChecksListWithNoNodesNextToAnErrorKeepsTheReadUnsettled() async throws {
        var pull = pullRequest()
        var commits = pull["commits"] as? [String: Any] ?? [:]
        var items = commits["nodes"] as? [[String: Any]] ?? []
        var commit = items[0]["commit"] as? [String: Any] ?? [:]
        commit["statusCheckRollup"] = [
            "state": "FAILURE", "contexts": ["nodes": NSNull(), "pageInfo": ["hasNextPage": false]],
        ]
        items[0]["commit"] = commit
        commits["nodes"] = items
        pull["commits"] = commits
        let data = try answer(pull, errors: [["message": "Something went wrong."]])
        let github = FakeGitHub(answers: [HeadQueries.name: .success(data)])
        let client = GitHubClient(access: github)
        let fresh = try await HeadQueries.read(
            try #require(PRKey(text: "owner-a/repo-a#55")), client: client)
        #expect(fresh.head.hex == head)
        #expect(fresh.checks.cut && !fresh.checks.settled && fresh.checks.failedJobs.isEmpty)
        // The head read sends its faults to the log of the client.
        #expect(client.loggedFaults == [.contextsNodes])
    }

    @Test func aHeadReadWithNoBranchNamesLogsThem() async throws {
        var pull = pullRequest()
        pull["headRefName"] = nil
        pull["baseRefName"] = NSNull()
        pull["repository"] = ["defaultBranchRef": NSNull()]
        let decoded = try HeadAnswer.decode(answer(pull)).get()
        #expect(decoded.read.headRef == "" && PushTarget(decoded.read) == nil)
        #expect(decoded.faults == [.baseRefName, .headRefName, .defaultBranch])
    }
}
