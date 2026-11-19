import BifrostTestSupport
import Foundation
import Synchronization
import Testing

@testable import BifrostFoundation

// The first accepted line of a program, with real programs (/bin/sh, /bin/sleep) in the test
// sandbox. Each program writes its pid to a file first, so a test can check that the program
// ended when the call returned. The limit test runs on a manual clock.

// The pid that a program wrote to the file, or nil.
private func pidIn(_ path: String) -> pid_t? {
    guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
    return pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines))
}

// True when no process has the pid. The call returns after the end of the program, and the
// system reaps the program before that end, so the pid is free.
private func isGone(_ pid: pid_t) -> Bool {
    kill(pid, 0) == -1 && errno == ESRCH
}

// The time limit of a program that must not reach it. A test host under load can start a
// program late, so the limit is wide.
private let wide = Duration.seconds(60)

@Suite("the first line of a program", .timeLimit(.minutes(2)), .tags(.realProcess))
struct ProcessLinesTests {
    // The tests start real programs.
    init() throws { try TestSandbox.require() }

    @Test func theProgramStopsAfterTheAcceptedLine() async throws {
        let temp = try TemporaryFolder()
        defer { temp.remove() }
        let pidFile = temp.appending("pid")
        let script = "echo $$ > '\(pidFile)'; echo one; echo two; echo three; exec sleep 60"
        let line = await ProcessLines.firstLine(
            Command("/bin/sh", ["-c", script], timeout: wide)
        ) { $0 == "two" }
        #expect(line == "two")
        let pid = try #require(pidIn(pidFile))
        #expect(isGone(pid))
    }

    // The program writes no line. At the limit the program stops, and the call gives nil.
    @MainActor
    @Test func aProgramThatPrintsNothingEndsAtItsLimit() async throws {
        let temp = try TemporaryFolder()
        defer { temp.remove() }
        let pidFile = temp.appending("pid")
        let clock = ManualClock()
        let command = Command(
            "/bin/sh", ["-c", "echo $$ > '\(pidFile)'; exec sleep 60"], timeout: .seconds(30))
        let task = Task { await ProcessLines.firstLine(command, clock: clock) { _ in true } }
        defer { task.cancel() }
        try #require(await waitUntil { pidIn(pidFile) != nil })
        try #require(await clock.waitForSleepers(1))
        clock.advance(by: .seconds(30))
        #expect(await task.value == nil)
        let pid = try #require(pidIn(pidFile))
        #expect(isGone(pid))
    }

    // A CR before the LF is not part of the line, an empty line goes to no test, and the text
    // after the last LF is the last line.
    @Test func theLinesEndAtEachLineFeed() async {
        let seen = Mutex<[String]>([])
        let line = await ProcessLines.firstLine(
            Command("/bin/sh", ["-c", "printf 'one\\r\\n\\ntwo\\nlast'"], timeout: wide)
        ) { line in
            seen.withLock { $0.append(line) }
            return line == "last"
        }
        #expect(line == "last")
        #expect(seen.withLock { $0 } == ["one", "two", "last"])
    }

    @Test func aProgramThatEndsWithNoAcceptedLineGivesNil() async {
        let line = await ProcessLines.firstLine(
            Command("/bin/sh", ["-c", "echo one; echo two"], timeout: wide)
        ) { _ in false }
        #expect(line == nil)
    }

    @Test func aProgramThatDoesNotStartGivesNil() async {
        let line = await ProcessLines.firstLine(
            Command("/nonexistent-bifrost-program", timeout: wide)
        ) { _ in true }
        #expect(line == nil)
    }

    // The output limit counts each byte of stdout. A program that writes more stops.
    @Test func aProgramOverTheOutputLimitStops() async throws {
        let temp = try TemporaryFolder()
        defer { temp.remove() }
        let pidFile = temp.appending("pid")
        let script = "echo $$ > '\(pidFile)'; echo 0123456789; exec sleep 60"
        let line = await ProcessLines.firstLine(
            Command("/bin/sh", ["-c", script], timeout: wide, outputLimit: 4)
        ) { _ in true }
        #expect(line == nil)
        let pid = try #require(pidIn(pidFile))
        #expect(isGone(pid))
    }

    // A cancel of the caller stops the program, and the call gives nil.
    @MainActor
    @Test func aCancelStopsTheProgram() async throws {
        let temp = try TemporaryFolder()
        defer { temp.remove() }
        let pidFile = temp.appending("pid")
        let command = Command(
            "/bin/sh", ["-c", "echo $$ > '\(pidFile)'; exec sleep 60"], timeout: wide)
        let task = Task { await ProcessLines.firstLine(command) { _ in true } }
        try #require(await waitUntil { pidIn(pidFile) != nil })
        task.cancel()
        #expect(await task.value == nil)
        let pid = try #require(pidIn(pidFile))
        #expect(isGone(pid))
    }

    // A command with SIGTERM and no grace still ends: the read gives it the default grace, then
    // SIGKILL, so a program that ignores SIGTERM cannot hold the call for ever.
    @MainActor
    @Test func aProgramThatIgnoresTheTermSignalStillEnds() async throws {
        let temp = try TemporaryFolder()
        defer { temp.remove() }
        let pidFile = temp.appending("pid")
        let clock = ManualClock()
        let script = "trap '' TERM; echo $$ > '\(pidFile)'; while :; do sleep 1; done"
        let command = Command(
            "/bin/sh", ["-c", script], timeout: wide, killSignal: .terminate, terminateGrace: nil)
        let task = Task { await ProcessLines.firstLine(command, clock: clock) { _ in true } }
        try #require(await waitUntil { pidIn(pidFile) != nil })
        try #require(await clock.waitForSleepers(1))
        task.cancel()
        // The SIGTERM starts the grace: its deadline is the nearest one on the clock.
        let graceEnd = clock.now.advanced(by: Command.defaultTerminateGrace)
        try #require(await waitUntil { clock.nextDeadline == graceEnd })
        clock.advance(by: Command.defaultTerminateGrace)
        #expect(await task.value == nil)
        let pid = try #require(pidIn(pidFile))
        #expect(isGone(pid))
    }
}
