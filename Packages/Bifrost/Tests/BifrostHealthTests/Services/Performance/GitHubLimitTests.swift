// The GitHub points of the Performance panel from gh api rate_limit. Safety: the runner is a fake,
// so no test starts gh or reaches the network.
import BifrostFoundation
import BifrostTestSupport
import Foundation
import Synchronization
import Testing

@testable import BifrostHealth

private let answer = """
    {"resources": {"core": {"limit": 5000, "remaining": 4990, "reset": 1700000100},
    "graphql": {"limit": 5000, "remaining": 4321, "reset": 1700000000, "used": 679}}}
    """

private func limit(_ result: ExecResult) -> (GitHubLimit, FakeRunner) {
    let runner = FakeRunner(result)
    let gh = GHCommand(
        path: "/nonexistent-bifrost-test/gh", environment: ["PATH": "/usr/bin"],
        folder: URL(filePath: "/nonexistent-bifrost-test/folder"), runner: runner)
    return (GitHubLimit(gh: gh), runner)
}

@Suite("performance github limit")
struct GitHubLimitTests {
    @Test func thePointsComeFromTheGraphQLLimit() async {
        let (github, runner) = limit(ExecResult(.exited(0), stdout: answer))
        let points = GitHubPoints(
            remaining: 4321, limit: 5000, reset: Date(timeIntervalSince1970: 1_700_000_000))
        #expect(await github.read() == .success(points))
        // The read costs no points: it asks only for the limits.
        #expect(runner.calls.map(\.args) == [["api", "rate_limit"]])
        #expect(runner.commands.first?.environment?["GH_PROMPT_DISABLED"] == "1")
    }

    @Test func noGHIsNotInstalled() async {
        let (github, _) = limit(ExecResult(.notStarted))
        #expect(await github.read() == .failure(.noGH))
        #expect(GitHubLimitError.noGH.message == "GitHub CLI isn't installed")
    }

    // Before the app knows the env of gh, the read starts no gh and gives noGH. The next read
    // takes the command of that time.
    @Test func aReadWithNoCommandYetStartsNoGH() async {
        let runner = FakeRunner(ExecResult(.exited(0), stdout: answer))
        let gh = GHCommand(
            path: "/nonexistent-bifrost-test/gh", environment: ["PATH": "/usr/bin"],
            folder: URL(filePath: "/nonexistent-bifrost-test/folder"), runner: runner)
        let known = Mutex(false)
        let github = GitHubLimit { known.withLock { $0 } ? gh : nil }
        #expect(await github.read() == .failure(.noGH))
        #expect(runner.calls.isEmpty)
        known.withLock { $0 = true }
        #expect(await github.read() != .failure(.noGH))
        #expect(runner.calls.map(\.args) == [["api", "rate_limit"]])
    }

    @Test func aLoggedOutGHIsNotSignedIn() async {
        let (byCode, _) = limit(ExecResult(.exited(4), stderr: "error"))
        #expect(await byCode.read() == .failure(.loggedOut))
        let (byText, _) = limit(
            ExecResult(.exited(1), stderr: "To get started with GitHub CLI, run: gh auth login"))
        #expect(await byText.read() == .failure(.loggedOut))
        #expect(GitHubLimitError.loggedOut.message == "GitHub CLI isn't signed in")
    }

    @Test func aBadAnswerCannotBeRead() async {
        let (notJSON, _) = limit(ExecResult(.exited(0), stdout: "not json"))
        #expect(await notJSON.read() == .failure(.failed))
        let (noGraphQL, _) = limit(ExecResult(.exited(0), stdout: #"{"resources": {}}"#))
        #expect(await noGraphQL.read() == .failure(.failed))
        let (timedOut, _) = limit(ExecResult(.timedOut))
        #expect(await timedOut.read() == .failure(.failed))
        #expect(GitHubLimitError.failed.message == "Couldn't read the GitHub limit")
    }
}
