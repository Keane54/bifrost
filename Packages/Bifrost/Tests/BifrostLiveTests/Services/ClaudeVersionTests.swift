import BifrostFoundation
import BifrostLive
import BifrostSessions
import BifrostTestSupport
import Foundation
import Testing

// The version check of Claude Code: the run of claude --version, the parse of its output and the
// compare with the minimum. The fake runner runs no program.

private func check(
    _ result: ExecResult, minimum: ClaudeCodeVersion = ClaudeVersionCheck.liveMinimum
)
    async -> (ClaudeVersionCheck, [Command])
{
    let runs = FakeRunner(result)
    let check = await ClaudeVersion.check(runs.claude(), minimum: minimum)
    return (check, runs.commands)
}

@Suite("The version check of Claude Code")
struct ClaudeVersionTests {
    @Test func theLiveMinimumIs2_1_290() {
        #expect(ClaudeVersionCheck.liveMinimum == "2.1.290")
    }

    @Test func theCheckRunsVersionWithA5SecondLimit() async {
        let (_, calls) = await check(ExecResult(.exited(0), stdout: "2.1.290 (Claude Code)\n"))
        #expect(
            calls == [
                Command(
                    FakeRunner.claudePath, ["--version"], environment: [:], timeout: .seconds(5),
                    killSignal: .kill)
            ])
    }

    @Test func anOlderVersionIsNotOk() async {
        let (result, _) = await check(ExecResult(.exited(0), stdout: "2.1.289 (Claude Code)\n"))
        #expect(result == ClaudeVersionCheck(version: "2.1.289", ok: false, minimum: "2.1.290"))
    }

    @Test func theMinimumAndANewerVersionAreOk() async {
        let (same, _) = await check(ExecResult(.exited(0), stdout: "2.1.290 (Claude Code)\n"))
        #expect(same == ClaudeVersionCheck(version: "2.1.290", ok: true, minimum: "2.1.290"))
        let (newer, _) = await check(ExecResult(.exited(0), stdout: "2.10.0 (Claude Code)\n"))
        #expect(newer.ok)
    }

    @Test func theCheckUsesTheGivenMinimum() async {
        let (result, _) = await check(
            ExecResult(.exited(0), stdout: "2.1.200 (Claude Code)\n"), minimum: "2.1.281")
        #expect(result == ClaudeVersionCheck(version: "2.1.200", ok: false, minimum: "2.1.281"))
    }

    @Test(arguments: [
        ExecResult(.exited(1), stdout: "2.1.300", stderr: "x"),
        ExecResult(.timedOut, stdout: "2.1.300"),
        ExecResult(.notStarted, stderr: "Cannot start claude."),
        ExecResult(.exited(0), stdout: "hello"),
    ])
    func aFailedRunOrOddTextGivesNoVersion(_ run: ExecResult) async {
        let (result, _) = await check(run)
        #expect(result == ClaudeVersionCheck(version: nil, ok: false, minimum: "2.1.290"))
    }

    @Test func theParseTakesTheFirstVersionNumber() {
        #expect(ClaudeCodeVersion(firstIn: "Claude Code 2.1.290 (build 2.0.0)") == "2.1.290")
        #expect(ClaudeCodeVersion(firstIn: "v10.20.30-beta\n") == ClaudeCodeVersion(10, 20, 30))
        #expect(ClaudeCodeVersion(firstIn: "2.1") == nil)
        #expect(ClaudeCodeVersion(firstIn: "hello") == nil)
        // A zero at the start of a part changes nothing.
        #expect(ClaudeCodeVersion(firstIn: "2.01.3") == "2.1.3")
        // A part that is too large for an Int gives no version, so the check is not ok.
        #expect(ClaudeCodeVersion(firstIn: "2.1.99999999999999999999") == nil)
    }

    @Test func theParseReadsOnlyASCIIDigits() {
        // Arabic-Indic digits are digits for Unicode, but a version has ASCII digits only.
        #expect(ClaudeCodeVersion(firstIn: "\u{0662}.\u{0661}.\u{0662}") == nil)
    }

    @Test func versionsComparePartByPartAsNumbers() {
        let versions: [ClaudeCodeVersion] = ["2.1.318", "2.1.281", "2.10.0", "2.9.9", "2.1.9"]
        #expect(versions.sorted() == ["2.1.9", "2.1.281", "2.1.318", "2.9.9", "2.10.0"])
        #expect(ClaudeCodeVersion(2, 1, 281) == "2.1.281")
        #expect(ClaudeCodeVersion(2, 1, 290).description == "2.1.290")
    }
}
