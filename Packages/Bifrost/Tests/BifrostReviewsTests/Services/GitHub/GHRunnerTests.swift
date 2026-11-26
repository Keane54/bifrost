// The gh runner of Reviews (docs/behaviour/reviews.md, "Safety"). A recording runner shows the
// argv, the env, the folder, the stdin and the limits of each run. No gh runs.
import BifrostFoundation
import BifrostTestSupport
import Foundation
import Testing

@testable import BifrostReviews

private let folder = URL(filePath: "/nonexistent-bifrost-test/reviews", directoryHint: .isDirectory)
private let environment = ["PATH": "/opt/homebrew/bin:/usr/bin", "HOME": "/Users/someone"]
private let read = GitHubQuery(
    name: "viewer", text: "query Viewer($n: Int) { viewer { login } }",
    variables: ["n": .int(1), "s": .string("x"), "z": .null])

private func gh(_ runner: FakeRunner) -> GHRunner {
    GHRunner(
        gh: GHCommand(
            path: "/opt/homebrew/bin/gh", environment: environment, folder: folder, runner: runner))
}

private func consentingState() -> ReviewsState {
    var state = ReviewsState()
    state.consentToCIFix()
    return state
}

private func jobLog() throws -> GitHubRead {
    .jobLog(try #require(RepoName("Owner-A/Repo-A")), try #require(JobID(101)))
}

private func node(_ text: String) throws -> NodeID { try #require(NodeID(text)) }

@Suite("the gh runner of Reviews", .testTimeLimit)
struct GHRunnerTests {
    @Test func ghGetsTheLoginEnvironmentAndNoPrompt() async throws {
        let runner = FakeRunner(ExecResult(.exited(0), stdout: "{}"))
        _ = try await gh(runner).read(read)
        let run = try #require(runner.commands.first)
        #expect(run.executable == "/opt/homebrew/bin/gh")
        #expect(
            run.environment == [
                "PATH": "/opt/homebrew/bin:/usr/bin", "HOME": "/Users/someone",
                "GH_PROMPT_DISABLED": "1", "GH_NO_UPDATE_NOTIFIER": "1",
            ])
        #expect(run.timeout == .seconds(30))
        #expect(run.outputLimit == 16 * 1_048_576)
        // After a cancel, the call ends when gh ended.
        #expect(run.waitsForEnd)
    }

    // The scopes of the login come from one closed read: gh api --include user, with no input.
    // Only the scope names stay: the answer has no other use, and gh gives no token.
    @Test func theScopesReadIsOneClosedCommand() async throws {
        let output = "HTTP/2.0 200 OK\nX-Oauth-Scopes: gist, repo\n\n{}"
        let runner = FakeRunner(ExecResult(.exited(0), stdout: output))
        let scopes = try await gh(runner).scopes()
        #expect(scopes?.names == ["gist", "repo"] && scopes?.lacksWorkflow == true)
        let run = try #require(runner.commands.first)
        #expect(run.arguments == ["api", "--include", "user"])
        #expect(run.directory == folder.path(percentEncoded: false))
        #expect(run.timeout == .seconds(30))
        let silent = FakeRunner(ExecResult(.exited(0), stdout: "HTTP/2.0 200 OK\n\n{}"))
        #expect(try await gh(silent).scopes() == nil)
        let failed = FakeRunner(ExecResult(.exited(4)))
        await #expect(throws: GitHubError.notLoggedIn) { _ = try await gh(failed).scopes() }
    }

    // The texts that tell the user to log in ask for the workflow scope too.
    @Test func theLoginTextsAskForTheWorkflowScope() {
        #expect(
            GitHubError.notInstalled.message
                == "GitHub CLI (gh) isn't installed. Install it with Homebrew (brew install gh), "
                + "log in with gh auth login -s workflow, then click Refresh.")
        #expect(
            GitHubError.notLoggedIn.message
                == "GitHub CLI (gh) isn't logged in. Run gh auth login -s workflow in a terminal, "
                + "then click Refresh.")
    }

    // A PR head can hold a git config, and gh reads the config of its folder.
    @Test func ghRunsInTheReviewsFolder() async throws {
        let runner = FakeRunner(ExecResult(.exited(0), stdout: "{}"))
        _ = try await gh(runner).read(read)
        _ = try await gh(runner).write(.resolveThread(try node("PRRT_1")))
        #expect(runner.commands.count == 2)
        #expect(runner.commands.allSatisfy { $0.directory == folder.path(percentEncoded: false) })
    }

    @Test func aReadSendsItsQueryOnStdin() async throws {
        let runner = FakeRunner(ExecResult(.exited(0), stdout: #"{"data":{}}"#))
        let answer = try await gh(runner).read(read)
        #expect(answer == Data(#"{"data":{}}"#.utf8))
        let run = try #require(runner.commands.first)
        #expect(run.arguments == ["api", "graphql", "--input", "-"])
        let body = try JSONDecoder().decode(JSONValue.self, from: try #require(run.input))
        #expect(
            body == [
                "query": "query Viewer($n: Int) { viewer { login } }",
                "variables": ["n": 1, "s": "x", "z": .null],
            ])
    }

    @Test func aWriteSendsItsArgumentsAndInput() async throws {
        let runner = FakeRunner(ExecResult(.exited(0), stdout: "{}"))
        let write = GitHubWrite.resolveThread(try node("PRRT_1"))
        _ = try await gh(runner).write(write)
        let run = try #require(runner.commands.first)
        #expect(run.arguments == write.arguments)
        #expect(run.input == write.input)
        #expect(run.timeout == .seconds(30))
    }

    // The signed commit can carry 4 MiB of files, so it gets more time.
    @Test func theSignedCommitGetsTheLongerLimit() async throws {
        let runner = FakeRunner(ExecResult(.exited(0), stdout: "{}"))
        let commit = SignedCommit(
            repo: try #require(RepoName("o/r")), branch: try #require(BranchName("fix")),
            expectedHead: try #require(CommitID(String(repeating: "a", count: 40))),
            headline: "Fix", body: "", changes: [])
        _ = try await gh(runner).write(.createSignedCommit(commit))
        #expect(runner.commands.first?.timeout == .seconds(120))
        #expect(GHRunner.signedCommitTimeout == .seconds(120))
    }

    @Test func aQueryWithAMutationIsRefusedBeforeGhRuns() async {
        let runner = FakeRunner(ExecResult(.exited(0), stdout: "{}"))
        let texts = [
            "mutation { addComment(input: {}) { clientMutationId } }",
            "query A { viewer { login } } mutation B { x }", "Mutation { x }", "MUTATION{x}",
            "# mutation\nquery { viewer { login } }", "query{a}\nmutation\n{b}",
        ]
        for text in texts {
            let query = GitHubQuery(name: "q", text: text, variables: [:])
            #expect(!query.isRead, "\(text.debugDescription)")
            await #expect(throws: GitHubError.notSent) { try await gh(runner).read(query) }
        }
        #expect(runner.commands.isEmpty)
        let field = GitHubQuery(name: "q", text: "query { a { clientMutationId } }", variables: [:])
        #expect(field.isRead)
        #expect(GitHubQuery(name: "q", text: "query { mutations }", variables: [:]).isRead)
    }

    @Test func exitCode4IsNotLoggedIn() async {
        let runner = FakeRunner(ExecResult(.exited(4), stderr: "To get started, run: x"))
        await #expect(throws: GitHubError.notLoggedIn) { try await gh(runner).read(read) }
        let other = FakeRunner(ExecResult(.exited(1), stderr: "Please run: gh auth login"))
        await #expect(throws: GitHubError.notLoggedIn) { try await gh(other).read(read) }
        #expect(GitHubError.notLoggedIn.message.contains("gh auth login"))
    }

    @Test func aMissingGhIsNotInstalled() async {
        let runner = FakeRunner(ExecResult(.notStarted, stderr: "Cannot start gh: not found."))
        await #expect(throws: GitHubError.notInstalled) { try await gh(runner).read(read) }
        #expect(GitHubError.notInstalled.message.contains("brew install gh"))
    }

    @Test func aTimeoutOrAnOverflowFails() async throws {
        let late = FakeRunner(ExecResult(.timedOut, stdout: #"{"data":{}}"#))
        await #expect(throws: GitHubError.timedOut) { try await gh(late).read(read) }
        let big = FakeRunner(ExecResult(.overflow, stdout: #"{"data":{}}"#))
        let write = GitHubWrite.resolveThread(try node("PRRT_1"))
        await #expect(throws: GitHubError.badAnswer) { try await gh(big).write(write) }
    }

    @Test func theErrorLineHasNoHiddenCharactersAnd200AtMost() async throws {
        let long = String(repeating: "x", count: 250)
        let cases: [(String, String)] = [
            ("\n  gh: Bad\u{202E}Gateway\u{200B} (HTTP 502)\u{7}\nsecond line\n",
             "gh: BadGateway (HTTP 502)"),
            (long, String(repeating: "x", count: 200)), ("", ""), ("   \n\n", ""),
        ]
        let write = GitHubWrite.resolveThread(try node("PRRT_1"))
        for (stderr, line) in cases {
            let runner = FakeRunner(ExecResult(.exited(1), stderr: stderr))
            await #expect(throws: GitHubError.unknownOutcome(line)) {
                try await gh(runner).write(write)
            }
        }
        // A refusal gets the same clean.
        let notFound = "\n  gh: Not\u{202E}Found\u{200B} (HTTP 404)\u{7}\nsecond line\n"
        let refused = FakeRunner(ExecResult(.exited(1), stderr: notFound))
        await #expect(throws: GitHubError.refused("gh: NotFound (HTTP 404)")) {
            try await gh(refused).write(write)
        }
        #expect(!GitHubError.unknownOutcome("").message.isEmpty)
        #expect(GitHubError.unknownOutcome("gh: Not Found").message.contains("gh: Not Found"))
        #expect(GitHubError.refused("Not allowed").message.contains("Not allowed"))
    }

    // gh exits with an error code when GitHub gives errors next to the data. A read keeps such an
    // answer, so the poll keeps its data. A write never does: its errors mean that GitHub did not
    // make the change.
    @Test func aReadKeepsAnAnswerWithDataAndErrors() async throws {
        let partial = #"{"data":{"viewer":{"login":"me"}},"errors":[{"message":"bad"}]}"#
        let runner = FakeRunner(ExecResult(.exited(1), stdout: partial, stderr: "GraphQL: bad"))
        #expect(try await gh(runner).read(read) == Data(partial.utf8))
        // A write with errors next to a result ran, so its outcome is not known.
        let write = GitHubWrite.resolveThread(try node("PRRT_1"))
        await #expect(throws: GitHubError.unknownOutcome("bad")) {
            try await gh(runner).write(write)
        }
        let errorsOnly = #"{"errors":[{"message":"bad"}]}"#
        let noData = FakeRunner(ExecResult(.exited(1), stdout: errorsOnly, stderr: "GraphQL: bad"))
        await #expect(throws: GitHubError.refused("bad")) { try await gh(noData).read(read) }
        // A network error with no answer keeps nothing.
        let down = FakeRunner(ExecResult(.exited(1), stderr: "error connecting to api.github.com"))
        await #expect(throws: GitHubError.unknownOutcome("error connecting to api.github.com")) {
            try await gh(down).read(read)
        }
    }

    // A write says whether GitHub can have made its change. It is refused only when the answer
    // proves that the change did not happen: an HTTP 4xx status, or GraphQL errors with no result
    // and no sign that GitHub stopped on the way. Each other failure can come after the change,
    // so the caller never sends such a write again by itself.
    @Test func aWriteSaysWhetherItMayHaveHappened() async throws {
        let write = GitHubWrite.resolveThread(try node("PRRT_1"))
        let errors = #"{"data":null,"errors":[{"type":"NOT_FOUND","#
            + #""message":"Could not resolve\nto a node"}]}"#
        let nullResult = #"{"data":{"resolveReviewThread":null},"errors":[{"#
            + #""type":"FORBIDDEN","message":"Not allowed"}]}"#
        let withResult = #"{"data":{"resolveReviewThread":{"thread":{"id":"PRRT_1"}}},"#
            + #""errors":[{"message":"Field isResolved failed"}]}"#
        let stopped = #"{"data":null,"errors":[{"message":"Something went wrong while "#
            + #"executing your query. This may be the result of a timeout."}]}"#
        let timedOut = #"{"data":null,"errors":[{"type":"TIMEOUT","message":"Timeout"}]}"#
        let cases: [(ExecResult, GitHubError)] = [
            (ExecResult(.exited(1), stdout: nullResult, stderr: "GraphQL: Not allowed"),
             .refused("Not allowed")),
            (ExecResult(.exited(1), stdout: errors, stderr: "gh: Not Found (HTTP 404)"),
             .refused("gh: Not Found (HTTP 404)")),
            // Errors next to a result, an error that says that GitHub stopped, and an HTTP 5xx
            // status with errors can each come after the write ran.
            (ExecResult(.exited(1), stdout: withResult, stderr: "GraphQL: Field isResolved failed"),
             .unknownOutcome("Field isResolved failed")),
            (ExecResult(.exited(0), stdout: withResult),
             .unknownOutcome("Field isResolved failed")),
            (ExecResult(.exited(1), stdout: stopped, stderr: "GraphQL: Something went wrong"),
             .unknownOutcome(
                "Something went wrong while executing your query. This may be the result of a "
                    + "timeout.")),
            (ExecResult(.exited(1), stdout: timedOut), .unknownOutcome("Timeout")),
            (ExecResult(.exited(1), stdout: errors, stderr: "gh: Bad Gateway (HTTP 502)"),
             .unknownOutcome("gh: Bad Gateway (HTTP 502)")),
            (ExecResult(.exited(1), stderr: "gh: Validation Failed (HTTP 422)\n"),
             .refused("gh: Validation Failed (HTTP 422)")),
            (ExecResult(.exited(1), stdout: errors, stderr: "GraphQL: Could not resolve"),
             .refused("Could not resolve")),
            // An answer with errors is a refusal also with exit code 0.
            (ExecResult(.exited(0), stdout: errors), .refused("Could not resolve")),
            (ExecResult(.exited(1), stderr: "gh: Server Error (HTTP 502)"),
             .unknownOutcome("gh: Server Error (HTTP 502)")),
            (ExecResult(.exited(1), stderr: "error connecting to api.github.com"),
             .unknownOutcome("error connecting to api.github.com")),
            (ExecResult(.signal(9)), .unknownOutcome("")),
            (ExecResult(.cancelled, stderr: "Bifrost stopped the program."),
             .unknownOutcome("Bifrost stopped the program.")),
            (ExecResult(.timedOut, stdout: errors), .timedOut),
            (ExecResult(.overflow), .badAnswer),
            (ExecResult(.notStarted), .notInstalled),
            (ExecResult(.exited(4)), .notLoggedIn),
        ]
        for (result, expected) in cases {
            await #expect(throws: expected) { try await gh(FakeRunner(result)).write(write) }
        }
        let unknown: [GitHubError] = [.timedOut, .badAnswer, .unknownOutcome("x")]
        let known: [GitHubError] = [.notInstalled, .notLoggedIn, .notSent, .refused("x")]
        #expect(unknown.allSatisfy { $0.writeMayHaveHappened })
        #expect(known.allSatisfy { !$0.writeMayHaveHappened })
    }

    // The read of a job log is a GET with no body. gh gets the flag that lets escape sequences
    // pass, because a CI log has colour codes.
    @Test func aLogReadIsAGetWithNoBodyInTheReviewsFolder() async throws {
        let runner = FakeRunner(ExecResult(.exited(0), stdout: "log text"))
        let answer = try await gh(runner).fetch(try jobLog())
        #expect(answer == Data("log text".utf8))
        let run = try #require(runner.commands.first)
        #expect(
            run.arguments == [
                "api", "--allow-escape-sequences", "repos/Owner-A/Repo-A/actions/jobs/101/logs",
            ])
        #expect(!run.arguments.contains("--method"))
        #expect(run.input == nil)
        #expect(run.directory == folder.path(percentEncoded: false))
        #expect(run.timeout == .seconds(60))
        #expect(GHRunner.logTimeout == .seconds(60))
        #expect(run.outputLimit == 16 * 1_048_576)
        #expect(run.waitsForEnd)
    }

    @Test func aLogOverTheLimitIsABadAnswer() async throws {
        let big = FakeRunner(ExecResult(.overflow, stdout: "partial"))
        await #expect(throws: GitHubError.badAnswer) { try await gh(big).fetch(try jobLog()) }
        let gone = FakeRunner(ExecResult(.exited(1), stderr: "gh: Not Found (HTTP 404)"))
        await #expect(throws: GitHubError.refused("gh: Not Found (HTTP 404)")) {
            try await gh(gone).fetch(try jobLog())
        }
        // Data next to an error is not kept, also when the data is a GraphQL answer.
        let data = FakeRunner(ExecResult(.exited(1), stdout: #"{"data":{}}"#, stderr: "failed"))
        await #expect(throws: GitHubError.unknownOutcome("failed")) {
            try await gh(data).fetch(try jobLog())
        }
    }

    // An older gh does not know the flag. The read then runs once more without it.
    @Test func anOlderGhGetsTheReadOnceMoreWithoutTheFlag() async throws {
        let old = FakeRunner { command in
            command.arguments.contains("--allow-escape-sequences")
                ? ExecResult(.exited(1), stderr: "unknown flag: --allow-escape-sequences\n")
                : ExecResult(.exited(0), stdout: "plain log")
        }
        let answer = try await gh(old).fetch(try jobLog())
        #expect(answer == Data("plain log".utf8))
        #expect(
            old.commands.map(\.arguments) == [
                ["api", "--allow-escape-sequences", "repos/Owner-A/Repo-A/actions/jobs/101/logs"],
                ["api", "repos/Owner-A/Repo-A/actions/jobs/101/logs"],
            ])
        #expect(old.commands.allSatisfy { $0.input == nil && $0.timeout == .seconds(60) })
        // The second read can fail too, and it is not read a third time.
        let flag = "unknown flag: --allow-escape-sequences"
        let both = FakeRunner(ExecResult(.exited(1), stderr: flag))
        await #expect(throws: GitHubError.unknownOutcome(flag)) {
            try await gh(both).fetch(try jobLog())
        }
        #expect(both.commands.count == 2)
    }

    @Test func anyOtherFailureOfALogReadIsNotReadAgain() async throws {
        let results = [
            ExecResult(.exited(1), stderr: "unknown flag: --other"),
            // The flag name alone is no unknown-flag error.
            ExecResult(
                .exited(1),
                stderr: "the response contains terminal escape sequences; pass "
                    + "--allow-escape-sequences to output it anyway"),
            ExecResult(.exited(1), stderr: "error connecting to api.github.com"),
            ExecResult(.exited(1), stderr: "gh: Not Found (HTTP 404)"),
            ExecResult(.timedOut), ExecResult(.notStarted),
        ]
        for result in results {
            let runner = FakeRunner(result)
            await #expect(throws: (any Error).self) { try await gh(runner).fetch(try jobLog()) }
            #expect(runner.commands.count == 1, "\(result.stderr)")
        }
    }

    @Test func theRerunWriteIsAPostWithAnEmptyBody() async throws {
        let runner = FakeRunner(ExecResult(.exited(0), stdout: ""))
        let state = consentingState()
        let write = GitHubWrite.rerunFailedJobs(
            try #require(RepoName("Owner-A/Repo-A")), try #require(RunID(55)),
            consent: try #require(state.ciConsent(true)))
        _ = try await gh(runner).write(write)
        let run = try #require(runner.commands.first)
        #expect(
            run.arguments == [
                "api", "--method", "POST", "repos/Owner-A/Repo-A/actions/runs/55/rerun-failed-jobs",
                "--input", "-",
            ])
        #expect(run.input == Data("{}".utf8))
        #expect(run.timeout == .seconds(30))
    }

    // The fake of the tests answers by name, records each call and refuses a mutation as gh does.
    @MainActor @Test func theFakeRecordsEachCallAndRefusesAMutation() async throws {
        let write = GitHubWrite.resolveThread(try node("PRRT_1"))
        let fake = FakeGitHub(answers: [
            "viewer": .success(Data("{}".utf8)), "resolveReviewThread": .failure(.timedOut),
        ])
        #expect(try await fake.read(read) == Data("{}".utf8))
        await #expect(throws: GitHubError.timedOut) { try await fake.write(write) }
        let mutation = GitHubQuery(name: "m", text: "mutation { x }", variables: [:])
        await #expect(throws: GitHubError.notSent) { try await fake.read(mutation) }
        let other = GitHubQuery(name: "other", text: "query { x }", variables: [:])
        await #expect(throws: GitHubError.refused("FakeGitHub has no answer for other.")) {
            try await fake.read(other)
        }
        #expect(fake.calls == [.read("viewer"), .write(write), .read("other")])
        let create = GitHubWrite.createPendingReview(
            try #require(PRKey(text: "o/r#1")),
            commit: try #require(CommitID(String(repeating: "a", count: 40))), body: "x",
            comments: [])
        #expect(FakeGitHub.key(create) == FakeGitHub.pendingReviewKey)
        #expect(FakeGitHub.key(write) == "resolveReviewThread")
        let rerun = GitHubWrite.rerunFailedJobs(
            try #require(RepoName("o/r")), try #require(RunID(5)),
            consent: try #require(consentingState().ciConsent(true)))
        #expect(FakeGitHub.key(rerun) == FakeGitHub.rerunKey)
        #expect(FakeGitHub.key(rerun) != FakeGitHub.pendingReviewKey)
        let logs = FakeGitHub(answers: ["job-log 101": .success(Data("log".utf8))])
        #expect(try await logs.fetch(try jobLog()) == Data("log".utf8))
        #expect(logs.calls == [.fetch("job-log 101")])
    }
}
