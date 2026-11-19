// The PR lookup of Show Info (docs/behaviour/panels.md, "The PR lookup"). The tests give a fake gh
// runner, a fake folder read and a manual clock. One test runs the fake gh of scripts/fake-gh in
// a test home. No test runs the real gh, and no test uses the network.
import BifrostFoundation
import BifrostTestSupport
import Foundation
import Synchronization
import Testing

@testable import BifrostSessions

private let okJSON =
    #"{"number":12,"title":"Fix","url":"https://github.com/o/r/pull/12","state":"OPEN"}"#
private let prURL = URL(string: "https://github.com/o/r/pull/12")!
private let fixPR = PRInfo.pr(number: 12, title: "Fix", url: prURL, state: "OPEN")
private let environment = ["HOME": "/h", "PATH": "/usr/bin"]

private func ok(_ stdout: String = okJSON) -> ExecResult { ExecResult(.exited(0), stdout: stdout) }
private func fail(_ stderr: String, _ end: ExecEnd = .exited(1)) -> ExecResult {
    ExecResult(end, stderr: stderr)
}

private func row(cwd: String = "/p", branch: String? = "fix-a") -> SessionRow {
    var row = SessionRow.test(cwd: cwd)
    row.branch = branch
    return row
}

// The answer of the fake gh, which a test can change between two lookups.
private final class Answer: Sendable {
    private let result: Mutex<ExecResult>

    init(_ result: ExecResult) { self.result = Mutex(result) }

    var value: ExecResult {
        get { result.withLock { $0 } }
        set { result.withLock { $0 = newValue } }
    }
}

// The folder reads of a test: each path is a folder, except "/gone". With goneAfter set, the
// folder is gone after that many reads.
private final class Folders: Sendable {
    private let reads = Mutex(0)
    private let goneAfter: Int?

    init(goneAfter: Int? = nil) { self.goneAfter = goneAfter }

    var count: Int { reads.withLock { $0 } }

    func kind(_ path: String) -> DirInfo.Kind {
        let count = reads.withLock { n in
            n += 1
            return n
        }
        if path == "/gone" { return .missing }
        if let goneAfter, count > goneAfter { return .missing }
        return .dir
    }
}

@MainActor
private struct Setup {
    let answer: Answer
    let runner: FakeRunner
    let clock = ManualClock()
    let lookup: PRLookup

    init(
        _ result: ExecResult = ok(), skipRoots: [String] = [], folders: Folders = Folders(),
        realPath: @escaping @Sendable (String) -> String? = { _ in nil }
    ) {
        let answer = Answer(result)
        self.answer = answer
        runner = FakeRunner { _ in answer.value }
        lookup = PRLookup(
            runner: runner, environment: environment, skipRoots: skipRoots, clock: clock,
            fileKind: { folders.kind($0) }, realPath: realPath)
    }

    var runs: Int { runner.commands.count }
}

@Suite("PR lookup")
struct PRLookupParseTests {
    @Test func theParseReadsAPR() {
        #expect(PRLookup.parse(ok()) == fixPR)
        // A whole number with a decimal point is still a whole number.
        let point = okJSON.replacingOccurrences(of: #""number":12"#, with: #""number":12.0"#)
        #expect(PRLookup.parse(ok(point)) == fixPR)
    }

    @Test func theParseGivesNoneForNoPRAndTheReasonsOfTheFailures() {
        #expect(PRLookup.parse(fail(#"no pull requests found for branch "fix-a""#)) == .none)
        #expect(PRLookup.parse(fail("No Pull Requests Found for branch x")) == .none)
        #expect(
            PRLookup.parse(fail("Cannot start gh: No such file or directory.", .notStarted))
                == .unavailable(.notInstalled))
        #expect(PRLookup.parse(fail("", .timedOut)) == .unavailable(.timedOut))
        #expect(
            PRLookup.parse(fail("  HTTP 401: bad token\nsecond line  "))
                == .unavailable(.gh("HTTP 401: bad token")))
        #expect(
            PRLookup.parse(fail(String(repeating: "x", count: 300)))
                == .unavailable(.gh(String(repeating: "x", count: 200))))
        #expect(PRLookup.parse(fail("  \n")) == .unavailable(.failed))
        // The texts of the runner are not for the PR line.
        #expect(
            PRLookup.parse(fail("The output is over the limit of 1048576 bytes.", .overflow))
                == .unavailable(.failed))
        #expect(
            PRLookup.parse(fail("Bifrost stopped the program.", .cancelled))
                == .unavailable(.failed))
        // A good exit with an answer that is not a PR is a failure with the fixed text.
        #expect(PRLookup.parse(ok("not json")) == .unavailable(.failed))
    }

    // The PR line of each reason. A line of gh is its own text.
    @Test func eachReasonHasItsText() {
        let texts: [(PRUnavailable, String)] = [
            (.notInstalled, "GitHub CLI (gh) isn't installed."),
            (.timedOut, "GitHub CLI (gh) didn't answer within 10 seconds."),
            (.failed, "GitHub CLI (gh) couldn't check for a PR."),
            (.noFolder, "The session folder isn't there any more."),
            (.reviewSession, "This is a review session, so Bifrost doesn't run gh in its folder."),
            (.gh("HTTP 401: bad token"), "HTTP 401: bad token"),
        ]
        for (reason, text) in texts { #expect(reason.text == text) }
    }

    // The reason line comes from gh, so a hidden character cannot change how the panel reads.
    @Test func theReasonLineHasNoHiddenCharacters() {
        #expect(
            PRLookup.parse(fail("HTTP 404: \u{202E}not found\u{200B}"))
                == .unavailable(.gh("HTTP 404: not found")))
    }

    // The title and the state come from GitHub, so a bidi control cannot change how the panel
    // reads.
    @Test func theTitleAndTheStateHaveNoHiddenCharacters() {
        let title = "Fix\u{202E} it\u{200B}"
        let state = "OP\u{2066}EN"
        let text =
            #"{"number":12,"title":""# + title + #"","url":"https://github.com/o/r/pull/12","#
            + #""state":""# + state + #""}"#
        #expect(
            PRLookup.parse(ok(text)) == .pr(number: 12, title: "Fix it", url: prURL, state: "OPEN"))
    }

    @Test func theParseRefusesAWrongNumberAMissingTitleAndBadJSON() {
        for text in [
            #"{"number":1.5,"title":"a","url":"https://x/y","state":"OPEN"}"#,
            #"{"number":"1","title":"a","url":"https://x/y","state":"OPEN"}"#,
            #"{"number":1,"url":"https://x/y","state":"OPEN"}"#,
            #"{"number":1,"title":"a","url":"https://x/y"}"#,
            "not json", "null", "[]",
        ] {
            guard case .unavailable = PRLookup.parse(ok(text)) else {
                Issue.record("not refused: \(text)")
                continue
            }
        }
    }

    @Test func ghGetsTheFixedArgumentsAndTheLimits() {
        #expect(PRLookup.goodCache == .seconds(300))
        #expect(PRLookup.failCache == .seconds(30))
        #expect(PRLookup.ghTimeout == .seconds(10))
        #expect(PRLookup.ghArgs == ["pr", "view", "--json", "number,title,url,state"])
    }
}

@MainActor
@Suite("PR lookup runs", .timeLimit(.minutes(1)))
struct PRLookupTests {
    @Test func aLookupRunsGhPrViewInTheFolderWithTheEnvironment() async {
        let t = Setup()
        #expect(await t.lookup.pr(row()) == fixPR)
        #expect(
            t.runner.commands == [
                Command(
                    "gh", ["pr", "view", "--json", "number,title,url,state"], directory: "/p",
                    environment: environment, timeout: .seconds(10))
            ])
    }

    // gh takes no value of the row as an argument. A branch that starts with "-" is not a git
    // branch, so it counts as no branch.
    @Test func noBranchARelativeFolderOrADashBranchRunsNothing() async {
        let folders = Folders()
        let t = Setup(folders: folders)
        #expect(await t.lookup.pr(row(branch: nil)) == .none)
        #expect(await t.lookup.pr(row(branch: "")) == .none)
        #expect(await t.lookup.pr(row(branch: "-x")) == .none)
        #expect(await t.lookup.pr(row(cwd: "p")) == .none)
        #expect(await t.lookup.pr(row(cwd: "")) == .none)
        // The C string of a path ends at a NUL, so a read would see another folder.
        #expect(await t.lookup.pr(row(cwd: "/p\u{0}/x")) == .none)
        #expect(t.runs == 0)
        #expect(folders.count == 0)
    }

    @Test func aFolderThatIsGoneGivesItsReasonAndRunsNothing() async {
        let t = Setup()
        #expect(
            await t.lookup.pr(row(cwd: "/gone"))
                == .unavailable(.noFolder))
        #expect(t.runs == 0)
    }

    // A review session can write the git config of its folder, and gh reads it.
    @Test func noGhRunsUnderASkipRoot() async {
        let review = PRInfo.unavailable(.reviewSession)
        let t = Setup(
            skipRoots: ["/reviews"], realPath: { $0 == "/link/pr-7" ? "/reviews/pr-7" : $0 })
        #expect(await t.lookup.pr(row(cwd: "/reviews")) == review)
        #expect(await t.lookup.pr(row(cwd: "/reviews/pr-12/src")) == review)
        // A link outside the root that points into it.
        #expect(await t.lookup.pr(row(cwd: "/link/pr-7")) == review)
        #expect(t.runs == 0)
        // A folder next to the root is not below it.
        #expect(await t.lookup.pr(row(cwd: "/reviews-old")) == fixPR)
        #expect(t.runs == 1)
    }

    @Test func aResultStaysFiveMinutes() async {
        let t = Setup()
        _ = await t.lookup.pr(row())
        t.clock.advance(by: .milliseconds(299_999))
        _ = await t.lookup.pr(row())
        #expect(t.runs == 1)
        t.clock.advance(by: .milliseconds(1))
        _ = await t.lookup.pr(row())
        #expect(t.runs == 2)
    }

    @Test func aFailureStaysThirtySecondsAndNoneStaysFiveMinutes() async {
        let t = Setup(fail("HTTP 500: server error"))
        _ = await t.lookup.pr(row())
        t.clock.advance(by: .milliseconds(29_999))
        _ = await t.lookup.pr(row())
        #expect(t.runs == 1)
        t.clock.advance(by: .milliseconds(1))
        _ = await t.lookup.pr(row())
        #expect(t.runs == 2)
        t.answer.value = fail("no pull requests found")
        #expect(await t.lookup.pr(row(cwd: "/q")) == .none)
        t.clock.advance(by: .seconds(30))
        #expect(await t.lookup.pr(row(cwd: "/q")) == .none)
        #expect(t.runs == 3)
    }

    // The start of gh also fails when the folder went after the check.
    @Test func aGhThatDoesNotStartAfterTheFolderWentGivesTheFolderText() async {
        let notStarted = fail("Cannot start gh in /p: No such file or directory.", .notStarted)
        let gone = Setup(notStarted, folders: Folders(goneAfter: 1))
        #expect(
            await gone.lookup.pr(row())
                == .unavailable(.noFolder))
        // The folder is still there, so gh is missing.
        let missing = Setup(fail("Cannot start gh: No such file or directory.", .notStarted))
        #expect(await missing.lookup.pr(row()) == .unavailable(.notInstalled))
    }

    @Test func theCacheKeyIsTheFolderAndTheBranch() async {
        let t = Setup()
        _ = await t.lookup.pr(row(cwd: "/p", branch: "fix-a"))
        _ = await t.lookup.pr(row(cwd: "/p", branch: "fix-b"))
        _ = await t.lookup.pr(row(cwd: "/q", branch: "fix-a"))
        #expect(t.runs == 3)
        // Another row in the same folder and on the same branch shares the answer.
        var other = row()
        other.sessionId = "s2"
        _ = await t.lookup.pr(other)
        #expect(t.runs == 3)
    }

    // The second lookup starts while gh of the first one waits at the gate. The tasks run on the
    // main actor in order, so the yield lets the second one reach the wait for the same run.
    @Test func twoLookupsAtTheSameTimeRunGhOneTime() async {
        let gate = TestGate()
        defer { gate.openAll() }
        let runner = GatedRunner(gate: gate, result: ok())
        let lookup = PRLookup(
            runner: runner, environment: [:], skipRoots: [], clock: ManualClock(),
            fileKind: { _ in .dir })
        let first = Task { await lookup.pr(row()) }
        await gate.waitUntilHolding(1)
        let second = Task { await lookup.pr(row()) }
        await Task.yield()
        #expect(gate.arrivals == 1)
        gate.open()
        #expect(await first.value == fixPR)
        #expect(await second.value == fixPR)
        #expect(gate.arrivals == 1)
    }

    // A stop cancels the run of gh. Each caller that waits for the run gets the failure text, and
    // the answer that the run gives after the cancel stays out of the cache.
    @Test func aStopDuringARunCancelsItAndKeepsNoAnswer() async {
        let gate = TestGate()
        defer { gate.openAll() }
        let runner = GatedRunner(gate: gate, result: ok())
        let lookup = PRLookup(
            runner: runner, environment: [:], skipRoots: [], clock: ManualClock(),
            fileKind: { _ in .dir })
        let first = Task { await lookup.pr(row()) }
        await gate.waitUntilHolding(1)
        let second = Task { await lookup.pr(row()) }
        await Task.yield()
        lookup.stop()
        gate.open()
        let failed = PRInfo.unavailable(.failed)
        #expect(await first.value == failed)
        #expect(await second.value == failed)
        #expect(runner.sawCancel)
        // The run gave a PR after the cancel. A cached PR would come back here.
        #expect(await lookup.pr(row()) == failed)
        #expect(gate.arrivals == 1)
    }

    // gh cannot start in a folder with no search permission, so the folder text shows, not the
    // text of a gh that is not installed. The test uses the real folder read.
    @Test func aFolderWithNoSearchPermissionGivesTheFolderText() async throws {
        let home = try TemporaryFolder()
        defer { home.remove() }
        let locked = home.appending("locked")
        #expect(mkdir(locked, 0o600) == 0)
        defer { chmod(locked, 0o700) }
        let runner = FakeRunner(ok())
        let lookup = PRLookup(
            runner: runner, environment: [:], skipRoots: [], clock: ManualClock())
        #expect(await lookup.pr(row(cwd: locked)) == .unavailable(.noFolder))
        #expect(runner.commands.isEmpty)
        #expect(PRLookup.folderKind(home.path) == .dir)
        #expect(PRLookup.folderKind(home.appending("none")) == .missing)
    }

    // A folder read can hang, for example on a network volume that is offline. After 2 s the
    // folder counts as gone, and gh does not run.
    @Test func aFolderReadThatHangsGivesTheFolderTextAfterTwoSeconds() async {
        let gate = TestGate()
        defer { gate.openAll() }
        let clock = ManualClock()
        let runner = FakeRunner(ok())
        let lookup = PRLookup(
            runner: runner, environment: [:], skipRoots: [], clock: clock,
            fileKind: { _ in
                gate.passBlocking()
                return .dir
            })
        async let result = lookup.pr(row())
        await gate.waitUntilHolding(1)
        await clock.waitForSleepers(1)
        clock.advance(by: .seconds(2))
        #expect(await result == .unavailable(.noFolder))
        #expect(runner.commands.isEmpty)
    }

    @Test func aStoppedLookupRunsNoGh() async {
        let t = Setup()
        t.lookup.stop()
        guard case .unavailable = await t.lookup.pr(row()) else {
            Issue.record("a stopped lookup gave a PR")
            return
        }
        #expect(t.runs == 0)
    }
}

// The address that a click on the PR of Show Info opens.
@MainActor
@Suite("PR address", .timeLimit(.minutes(1)))
struct PRAddressTests {
    @Test func onlyAnHttpsPRAddressOpens() async {
        for url in [
            #""http://github.com/o/r/pull/12""#, #""javascript:alert(1)""#, "12",
            #""file:///etc/hosts""#, #""HTTPS://github.com/o/r/pull/12""#,
        ] {
            let text = #"{"number":12,"state":"OPEN","title":"Fix","url":\#(url)}"#
            let t = Setup(ok(text))
            guard case .unavailable = PRLookup.parse(ok(text)) else {
                Issue.record("not refused: \(url)")
                continue
            }
            #expect(await t.lookup.urlToOpen(row()) == nil)
        }
        #expect(await Setup().lookup.urlToOpen(row()) == prURL)
    }

    @Test func aClickWhileTheCacheIsFreshRunsGhNoMore() async {
        let t = Setup()
        _ = await t.lookup.pr(row())
        t.clock.advance(by: .milliseconds(299_999))
        #expect(await t.lookup.urlToOpen(row()) == prURL)
        #expect(t.runs == 1)
    }

    // A panel can stay open for longer than the cache.
    @Test func aClickAfterFiveMinutesRunsGhAgainAndStillOpens() async {
        let t = Setup()
        _ = await t.lookup.pr(row())
        t.clock.advance(by: .seconds(300))
        #expect(await t.lookup.urlToOpen(row()) == prURL)
        #expect(t.runs == 2)
    }

    @Test func aClickWithNoLookupBeforeRunsGhAndOpens() async {
        let t = Setup()
        #expect(await t.lookup.urlToOpen(row()) == prURL)
        #expect(t.runs == 1)
    }

    @Test func noPRAFailureNoBranchAndARelativeFolderOpenNothing() async {
        let t = Setup(fail("no pull requests found"))
        #expect(await t.lookup.urlToOpen(row()) == nil)
        t.answer.value = fail("Cannot start gh: No such file or directory.", .notStarted)
        t.clock.advance(by: .seconds(300))
        #expect(await t.lookup.urlToOpen(row()) == nil)
        t.answer.value = ok()
        t.clock.advance(by: .seconds(30))
        #expect(await t.lookup.urlToOpen(row(branch: nil)) == nil)
        #expect(await t.lookup.urlToOpen(row(cwd: "p")) == nil)
        #expect(await t.lookup.urlToOpen(row()) == prURL)
    }
}

// The fake gh of scripts/fake-gh on the PATH, in a test home, with the real process runner.
@MainActor
@Suite("PR lookup with the fake gh", .timeLimit(.minutes(1)), .tags(.realProcess))
struct PRLookupFakeGhTests {
    @Test func theFakeGhGivesThePRLine() async throws {
        let home = try TemporaryFolder()
        defer { home.remove() }
        let project = home.appending("project")
        #expect(mkdir(project, 0o700) == 0)
        let fakeGh = try Repo.fakeGh()
        let environment = [
            "PATH": (fakeGh as NSString).deletingLastPathComponent + ":/usr/bin:/bin",
            "HOME": home.path, "BIFROST_TEST_HOME": home.path,
        ]
        try okJSON.write(toFile: home.appending("fake-pr.json"), atomically: true, encoding: .utf8)
        let lookup = PRLookup(
            runner: ProcessRunner(), environment: environment, skipRoots: [],
            clock: ContinuousClock())
        #expect(await lookup.pr(row(cwd: project)) == fixPR)
        // The fake writes the folder of each run and its arguments.
        let calls = try String(contentsOfFile: home.appending("gh-calls.log"), encoding: .utf8)
        #expect(calls == "\(home.realPath)/project: pr view --json number,title,url,state\n")
        // With no PR file, the branch has no PR.
        try FileManager.default.removeItem(atPath: home.appending("fake-pr.json"))
        let again = PRLookup(
            runner: ProcessRunner(), environment: environment, skipRoots: [],
            clock: ContinuousClock())
        #expect(await again.pr(row(cwd: project)) == .none)
    }
}

// A runner whose run waits at the gate, then gives the result, also after a cancel. It records
// whether the task of the run was cancelled when the gate let it through.
private final class GatedRunner: CommandRunner {
    private let gate: TestGate
    private let result: ExecResult
    private let cancelled = Mutex(false)

    init(gate: TestGate, result: ExecResult) {
        self.gate = gate
        self.result = result
    }

    var sawCancel: Bool { cancelled.withLock { $0 } }

    func run(_ command: Command) async -> ExecResult {
        await gate.pass()
        if Task.isCancelled { cancelled.withLock { $0 = true } }
        return result
    }
}
