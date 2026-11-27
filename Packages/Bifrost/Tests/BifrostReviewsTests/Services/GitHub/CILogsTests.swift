// The read of the logs of the failed Actions jobs of a CI round. The fake GitHub answers by the
// name of the read, so no gh runs.
import BifrostTestSupport
import Foundation
import Testing

@testable import BifrostReviews

private func repo() throws -> RepoName { try #require(RepoName("Owner-A/Repo-A")) }

private func check(_ job: Int, run: Int = 9) throws -> HeadCheck {
    HeadCheck(
        name: "job \(job)", outcome: .failed("FAILURE"),
        source: .actions(job: try #require(JobID(job)), run: try #require(RunID(run))))
}

private func logs(for jobs: [Int]) -> [String: Result<Data, GitHubError>] {
    Dictionary(
        uniqueKeysWithValues: jobs.map {
            ("job-log \($0)", .success(Data("\u{1B}[31mlog \($0)\u{1B}[0m\n".utf8)))
        })
}

@MainActor
@Suite("the logs of the failed jobs", .testTimeLimit)
struct CILogsTests {
    @Test func atMostFiveJobsAreRead() async throws {
        let ids = [107, 101, 105, 103, 102, 106, 104]
        let fake = FakeGitHub(answers: logs(for: ids))
        let result = await CILogs.read(
            try ids.map { try check($0) }
                + [HeadCheck(name: "lint", outcome: .failed("x"), source: .status)],
            repo: try repo(), client: GitHubClient(access: fake))
        #expect(result.map(\.check.job?.value) == [101, 102, 103, 104, 105, 106, 107])
        #expect(fake.calls == (101...105).map { .fetch("job-log \($0)") })
        #expect(result.prefix(5).map(\.text) == (101...105).map { "log \($0)\n" })
        #expect(result.prefix(5).allSatisfy { $0.missing == nil && !$0.cut })
        let late = result.suffix(2)
        #expect(late.map(\.missing) == ["not read", "not read"])
        #expect(late.allSatisfy { $0.text == nil && !$0.cut })
        #expect(CILogs.maxJobs == 5)
    }

    @Test func eachJobIsReadOnce() async throws {
        let fake = FakeGitHub(answers: logs(for: [101]))
        let result = await CILogs.read(
            [try check(101), try check(101, run: 10)], repo: try repo(),
            client: GitHubClient(access: fake))
        #expect(result.count == 1)
        #expect(fake.calls == [.fetch("job-log 101")])
    }

    @Test func aRefusedReadGivesGone() async throws {
        var answers = logs(for: [104])
        answers["job-log 101"] = .failure(.refused("gh: Not Found (HTTP 404)"))
        answers["job-log 102"] = .failure(.badAnswer)
        answers["job-log 103"] = .failure(.timedOut)
        let fake = FakeGitHub(answers: answers)
        let result = await CILogs.read(
            try [101, 102, 103, 104].map { try check($0) }, repo: try repo(),
            client: GitHubClient(access: fake))
        #expect(result.map(\.missing) == ["gone", "too large", "unreadable", nil])
        #expect(result.map(\.text) == [nil, nil, nil, "log 104\n"])
        #expect(fake.calls.count == 4)
        let other = FakeGitHub(answers: ["job-log 101": .failure(.notLoggedIn)])
        let one = await CILogs.read(
            [try check(101)], repo: try repo(), client: GitHubClient(access: other))
        #expect(one.first?.missing == "unreadable")
    }

    // A cancel in the fifth read leaves no entry for the jobs after it, also no "not read" one.
    @Test func aCancelStopsTheReads() async throws {
        let ids = Array(101...107)
        let fake = FakeGitHub(answers: logs(for: ids))
        let jobs = try ids.map { try check($0) }
        let client = GitHubClient(access: fake)
        let place = try repo()
        let task = Task { await CILogs.read(jobs, repo: place, client: client) }
        fake.onRead = { name in if name == "job-log 105" { task.cancel() } }
        let result = await ended(task)
        #expect(result.map(\.check.job?.value) == Array(101...105))
        #expect(result.allSatisfy { $0.missing == nil })
        #expect(fake.calls == (101...105).map { .fetch("job-log \($0)") })
    }

    @Test func aCutLogKeepsItsFlag() async throws {
        let big = Data(String(repeating: "line\n", count: 60_000).utf8)
        let fake = FakeGitHub(answers: ["job-log 101": .success(big)])
        let result = await CILogs.read(
            [try check(101)], repo: try repo(), client: GitHubClient(access: fake))
        #expect(result.first?.cut == true)
        #expect(result.first?.text?.hasPrefix(CILog.cutNote) == true)
    }
}
