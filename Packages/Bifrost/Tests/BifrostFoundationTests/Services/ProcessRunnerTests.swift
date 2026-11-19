import BifrostTestSupport
import Foundation
import Testing

@testable import BifrostFoundation

// The process runner with real programs (/bin/sh, /bin/cat, /bin/sleep) in the test sandbox. The
// timeouts run on a manual clock: a test waits until the program runs (its mark file) and the
// timer of the timeout sleeps, then it moves the clock. One test runs a short timeout on the real
// clock. ExecEnd says how a run ended: exited, a signal, timed out, over the output limit,
// cancelled or not started.

private func run(_ command: Command) async -> ExecResult {
    await ProcessRunner().run(command)
}

// The time limit of a program that ends by itself. On a test host under load the start of a
// program can take more than 5 s, so the limit is wide. The default of a command is 10 s.
private let ends = Duration.seconds(60)

// The pid that a program wrote to the file, or nil.
private func pidIn(_ path: String) -> pid_t? {
    guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
    return pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines))
}

// A run of the command with a manual clock for its timeout.
private func start(_ command: Command, on clock: ManualClock) -> Task<ExecResult, Never> {
    let runner = ProcessRunner(clock: clock)
    return Task { await runner.run(command) }
}

@Suite("process runner", .testTimeLimit, .tags(.realProcess))
struct ProcessRunnerTests {
    // The tests start real programs.
    init() throws { try TestSandbox.require() }

    // The shell ignores SIGTERM and writes its mark. exec keeps the ignored SIGTERM, so only
    // SIGKILL (the default kill signal) can stop the sleep. At the timeout the run ends.
    @MainActor
    @Test func aProgramThatIgnoresSIGTERMStopsAtTheTimeout() async throws {
        let temp = try TemporaryFolder()
        defer { temp.remove() }
        let mark = temp.appending("trap set")
        let clock = ManualClock()
        let script = "trap \"\" TERM; : > '\(mark)'; exec sleep 60"
        let task = start(Command("/bin/sh", ["-c", script], timeout: .seconds(10)), on: clock)
        defer { task.cancel() }
        try #require(await waitUntil { fileExists(mark) })
        try #require(await clock.waitForSleepers(1))
        clock.advance(by: .seconds(10))
        #expect(await task.value.end == .timedOut)
    }

    // claude adds piped stdin to the prompt. So each program gets an empty, closed stdin.
    // cat reads stdin until its end. With an open stdin, cat waits until the timeout.
    @Test("the program gets an empty, closed stdin")
    func closedStdin() async {
        // The timeout is wide, so a slow start under load does not count. With an open stdin, cat
        // waits the 10 s of the timeout, and the last check fails.
        let result = await run(Command("/bin/cat", timeout: .seconds(10)))
        #expect(result.end == .exited(0))
        #expect(result.stdout == "")
    }

    // The timeout uses the time limit of the command, not the default of 10 s, and it sends the
    // kill signal of the command (SIGTERM). The trap of the shell ends it with code 7, and the
    // end is still "timed out". The shell reads its stdin before the mark: an empty, closed stdin
    // ends the read at once, and the shell writes the file "eof". With an open stdin, the read
    // waits and no mark comes. The timeout stops the reads at once, so the test checks no output.
    @MainActor
    @Test func theTimeoutSendsTheKillSignalOfTheCommandAndSetsTimedOut() async throws {
        let temp = try TemporaryFolder()
        defer { temp.remove() }
        let clock = ManualClock()
        let script =
            "trap \"exit 7\" TERM; read -r line || : > \"$1/eof\"; : > \"$1/trap set\"; "
            + "while :; do sleep 0.05; done"
        let task = start(
            Command(
                "/bin/sh", ["-c", script, "sh", temp.path], timeout: .seconds(15),
                killSignal: .terminate),
            on: clock)
        defer { task.cancel() }
        try #require(
            await waitUntil { fileExists(temp.appending("trap set")) },
            "The stdin of the program was open.")
        #expect(fileExists(temp.appending("eof")))
        try #require(await clock.waitForSleepers(1))
        #expect(clock.nextDeadline == ManualClock.Instant(offset: .seconds(15)))
        clock.advance(by: .seconds(15))
        let result = await task.value
        #expect(result.end == .timedOut)
        #expect(result.stderr == "")
    }

    // A program that ignores SIGTERM gets SIGKILL at the end of the grace, and not before. The
    // shell writes its pid, then exec keeps the ignored SIGTERM for the sleep.
    @MainActor
    @Test func aProgramThatIgnoresSIGTERMGetsSIGKILLAtTheEndOfTheGrace() async throws {
        let temp = try TemporaryFolder()
        defer { temp.remove() }
        let clock = ManualClock()
        let script = "trap \"\" TERM; echo $$ > \"$1/pid\"; : > \"$1/mark\"; exec sleep 60"
        let task = start(
            Command(
                "/bin/sh", ["-c", script, "sh", temp.path], timeout: .seconds(10),
                killSignal: .terminate),
            on: clock)
        defer { task.cancel() }
        try #require(await waitUntil { fileExists(temp.appending("mark")) })
        let pid = try #require(pidIn(temp.appending("pid")))
        try #require(await clock.waitForSleepers(1))
        clock.advance(by: .seconds(10))
        try #require(await clock.waitForSleepers(1))
        #expect(clock.nextDeadline == ManualClock.Instant(offset: .seconds(15)))
        #expect(Command.defaultTerminateGrace == .seconds(5))
        clock.advance(by: .seconds(5) - .milliseconds(1))
        #expect(kill(pid, 0) == 0)
        clock.advance(by: .milliseconds(1))
        #expect(await task.value.end == .timedOut)
        #expect(await waitUntil { kill(pid, 0) != 0 })
    }

    // A program that ends within the grace gets no SIGKILL: it exits with code 0, and the
    // grace ends with it.
    @MainActor
    @Test func aProgramThatEndsWithinTheGraceGetsNoSIGKILL() async throws {
        let temp = try TemporaryFolder()
        defer { temp.remove() }
        let clock = ManualClock()
        let run = temp.appending("run")
        try FileManager.default.createDirectory(atPath: run, withIntermediateDirectories: true)
        let script =
            "trap ': > \"$1/term\"' TERM; : > \"$1/mark\"; "
            + "while [ -d \"$1/run\" ]; do sleep 0.05; done; exit 0"
        let task = start(
            Command(
                "/bin/sh", ["-c", script, "sh", temp.path], timeout: .seconds(10),
                killSignal: .terminate),
            on: clock)
        defer { task.cancel() }
        try #require(await waitUntil { fileExists(temp.appending("mark")) })
        try #require(await clock.waitForSleepers(1))
        clock.advance(by: .seconds(10))
        try #require(await waitUntil { fileExists(temp.appending("term")) })
        try #require(await clock.waitForSleepers(1))
        clock.advance(by: .seconds(5) - .milliseconds(1))
        try FileManager.default.removeItem(atPath: run)
        #expect(await task.value.end == .exited(0))
        #expect(await clock.waitUntilNoSleepers())
    }

    // A cancel returns at once, and its SIGTERM starts the grace too: a program that ignores it
    // gets SIGKILL at the end of the grace.
    @MainActor
    @Test func aCancelWithSIGTERMGetsSIGKILLAfterTheGrace() async throws {
        let temp = try TemporaryFolder()
        defer { temp.remove() }
        let clock = ManualClock()
        let script = "trap \"\" TERM; echo $$ > \"$1/pid\"; : > \"$1/mark\"; exec sleep 60"
        let task = start(
            Command(
                "/bin/sh", ["-c", script, "sh", temp.path], timeout: .seconds(60),
                killSignal: .terminate),
            on: clock)
        try #require(await waitUntil { fileExists(temp.appending("mark")) })
        let pid = try #require(pidIn(temp.appending("pid")))
        try #require(await clock.waitForSleepers(1))
        task.cancel()
        #expect(await task.value.end == .cancelled)
        #expect(kill(pid, 0) == 0)
        try #require(await clock.waitForSleepers(exactly: 1))
        clock.advance(by: .seconds(5))
        #expect(await waitUntil { kill(pid, 0) != 0 })
    }

    // A command that waits for its end gives the result of a cancel only when the program ended:
    // here after the SIGKILL at the end of the grace.
    @MainActor
    @Test func aCancelOfACommandThatWaitsForItsEndGivesTheResultAfterTheEnd() async throws {
        let temp = try TemporaryFolder()
        defer { temp.remove() }
        let clock = ManualClock()
        let script = "trap \"\" TERM; echo $$ > \"$1/pid\"; : > \"$1/mark\"; exec sleep 60"
        let task = start(
            Command(
                "/bin/sh", ["-c", script, "sh", temp.path], timeout: .seconds(60),
                killSignal: .terminate, waitsForEnd: true),
            on: clock)
        let end = TaskEnd(task)
        try #require(await waitUntil { fileExists(temp.appending("mark")) })
        let pid = try #require(pidIn(temp.appending("pid")))
        try #require(await clock.waitForSleepers(1))
        task.cancel()
        // The timer of the timeout goes, and the grace of the SIGTERM sleeps.
        try #require(await clock.waitForSleepers(exactly: 1))
        #expect(!end.ended)
        #expect(kill(pid, 0) == 0)
        clock.advance(by: .seconds(5))
        #expect(await task.value.end == .cancelled)
        // The system reaped the program before the result came.
        #expect(kill(pid, 0) == -1 && errno == ESRCH)
    }

    // With no grace, a program that ignores SIGTERM gets no SIGKILL: the caller sets its own
    // limit.
    @MainActor
    @Test func noGraceSendsNoSIGKILL() async throws {
        let temp = try TemporaryFolder()
        defer { temp.remove() }
        let clock = ManualClock()
        let run = temp.appending("run")
        try FileManager.default.createDirectory(atPath: run, withIntermediateDirectories: true)
        let script =
            "trap ': > \"$1/term\"' TERM; : > \"$1/mark\"; "
            + "while [ -d \"$1/run\" ]; do sleep 0.05; done; exit 0"
        let task = start(
            Command(
                "/bin/sh", ["-c", script, "sh", temp.path], timeout: .seconds(10),
                killSignal: .terminate, terminateGrace: nil),
            on: clock)
        defer { task.cancel() }
        try #require(await waitUntil { fileExists(temp.appending("mark")) })
        try #require(await clock.waitForSleepers(1))
        clock.advance(by: .seconds(10))
        try #require(await waitUntil { fileExists(temp.appending("term")) })
        #expect(clock.sleeperCount == 0)
        clock.advance(by: .seconds(3600))
        try FileManager.default.removeItem(atPath: run)
        #expect(await task.value.end == .exited(0))
    }

    @Test("the result gives the signal that ended the program")
    func signal() async {
        let result = await run(Command("/bin/sh", ["-c", "kill -TERM $$"], timeout: ends))
        #expect(result.end == .signal(SIGTERM))
        #expect(result.end != .timedOut)
        #expect(result.end != .cancelled)
    }

    @Test("a program that exits with an error is not timed out")
    func exitCode() async {
        let result = await run(Command("/bin/sh", ["-c", "exit 3"], timeout: ends))
        #expect(result.end == .exited(3))
    }

    // The Swift text names the limit in place of the word maxBuffer.
    @Test("a program stops at the output limit and the result names the limit")
    func limit() async {
        let result = await run(
            Command("/bin/sh", ["-c", "printf \"%064d\" 0"], timeout: ends, outputLimit: 16))
        #expect(result.stderr == "The output is over the limit of 16 bytes.")
        // The limit is not the timeout.
        #expect(result.end == .overflow)
        #expect(result.end != .timedOut)
    }

    @Test
    func limitWithStderr() async {
        let script = "echo note >&2; printf \"%064d\" 0"
        let result = await run(
            Command("/bin/sh", ["-c", script], timeout: ends, outputLimit: 16))
        #expect(result.end == .overflow)
        #expect(result.end != .timedOut)
    }

    // The runner stops the program only when the output is more than the limit. An output of
    // exactly 16 bytes with a limit of 16 is not over the limit.
    @Test
    func outputAtTheLimit() async {
        let result = await run(
            Command("/bin/sh", ["-c", "printf \"%016d\" 0"], timeout: ends, outputLimit: 16))
        #expect(result.end == .exited(0))
        #expect(result.stdout.utf8.count == 16)
    }

    // A command that keeps the bytes of stdout gets each byte as it is, also a byte that is not
    // UTF-8. The text form has U+FFFD for that byte. A command that does not keep them gets nil.
    @Test func theBytesOfStdoutStayAsTheyAre() async {
        let script = "printf 'a\\377\\376'"
        let kept = await run(
            Command("/bin/sh", ["-c", script], timeout: ends, keepsStdoutBytes: true))
        #expect(kept.end == .exited(0))
        #expect(kept.stdoutBytes == Data([0x61, 0xFF, 0xFE]))
        #expect(kept.stdout == "a\u{FFFD}\u{FFFD}")
        let plain = await run(Command("/bin/sh", ["-c", script], timeout: ends))
        #expect(plain.stdoutBytes == nil)
    }

    @Test("the default output limit applies when none is given")
    func defaultLimit() async {
        let result = await run(Command("/bin/sh", ["-c", "printf \"%064d\" 0"], timeout: ends))
        #expect(result.end == .exited(0))
        #expect(result.stdout.utf8.count == 64)
    }

    // gh reads a request body from stdin. cat gives the input back, so the test sees each byte.
    // The input is larger than a pipe buffer and has a character of more than one byte.
    @Test("the input goes to stdin")
    func input() async {
        let input = "café \(String(repeating: "x", count: 200_000))\n"
        let result = await run(Command("/bin/cat", timeout: ends, input: Data(input.utf8)))
        #expect(result.end == .exited(0))
        #expect(result.stdout == input)
    }

    // The program ends before it reads stdin. The write then fails with EPIPE, not SIGPIPE. The
    // runner ignores that error and gives the result of the program.
    @Test
    func inputNotRead() async {
        let input = Data(String(repeating: "x", count: 1_000_000).utf8)
        let result = await run(Command("/bin/sh", ["-c", "exit 3"], timeout: ends, input: input))
        #expect(result.end == .exited(3))
    }

    // A cancel of the task stops a program that runs. The program writes its mark first, so the
    // cancel always stops a program that runs. The sleep and the timeout are longer than the time
    // limit of the suite, so a result comes only from the cancel.
    @MainActor
    @Test func aCancelStopsTheProgram() async throws {
        let temp = try TemporaryFolder()
        defer { temp.remove() }
        let mark = temp.appending("started")
        let script = ": > '\(mark)'; exec sleep 300"
        let task = Task {
            await run(Command("/bin/sh", ["-c", script], timeout: .seconds(300)))
        }
        defer { task.cancel() }
        try #require(await waitUntil { fileExists(mark) })
        task.cancel()
        #expect(await task.value.end == .cancelled)
    }

    // A task that is cancelled before the start starts no program.
    @Test func aTaskThatIsCancelledBeforeTheStartStartsNoProgram() async throws {
        let temp = try TemporaryFolder()
        defer { temp.remove() }
        let folder = temp.url
        let marker = folder.appendingPathComponent("ran").path
        let task = Task {
            // The sleep ends at the cancel, so the run starts in a cancelled task.
            try? await Task.sleep(for: .seconds(10))
            return await run(Command("/bin/sh", ["-c", "touch '\(marker)'"]))
        }
        task.cancel()
        let result = await task.value
        #expect(result == ExecResult(.cancelled, stderr: stoppedText))
        #expect(!FileManager.default.fileExists(atPath: marker))
    }

    @Test("the program reads the input text on stdin")
    func inputText() async {
        let command = Command("/bin/cat", timeout: .seconds(10), input: Data("a job text".utf8))
        let result = await run(command)
        #expect(result == ExecResult(.exited(0), stdout: "a job text", stderr: ""))
    }

    // A name with no slash is found through the PATH of the env of the command.
    @Test func aNameWithNoSlashUsesThePathOfTheEnvironment() async throws {
        let temp = try TemporaryFolder()
        defer { temp.remove() }
        let folder = temp.url
        let name = "bifrost-probe"
        let program = folder.appendingPathComponent(name)
        try Data("#!/bin/sh\necho found\n".utf8).write(to: program)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: program.path)
        let found = await run(
            Command(name, environment: ["PATH": "/nowhere:\(folder.path)"], timeout: ends))
        #expect(found == ExecResult(.exited(0), stdout: "found\n"))
        let missing = await run(Command(name, environment: ["PATH": "/nowhere"]))
        #expect(missing.end == .notStarted)
    }

    // A program that cannot start gets the start text: the program, the folder when
    // the folder is the problem, and the text of the system for the error number.
    @Test func aProgramThatCannotStartGivesTheStartText() async throws {
        let missing = await run(Command("/nowhere/program"))
        let enoent = "Cannot start /nowhere/program: No such file or directory."
        #expect(missing == ExecResult(.notStarted, stderr: enoent))
        let noFolder = await run(Command("/bin/sh", ["-c", "true"], directory: "/nowhere"))
        let inFolder = "Cannot start /bin/sh in /nowhere: No such file or directory."
        #expect(noFolder == ExecResult(.notStarted, stderr: inFolder))
        let temp = try TemporaryFolder()
        defer { temp.remove() }
        let folder = temp.url
        let text = folder.appendingPathComponent("text")
        try Data("echo no\n".utf8).write(to: text)
        let notExecutable = await run(Command(text.path))
        #expect(notExecutable.stderr == "Cannot start \(text.path): Permission denied.")
        #expect(notExecutable.end == .notStarted)
    }

    // A program with no exit code and no stderr gets the text of the signal that ended it. The
    // registry shows that text in the error line when claude does not end by itself. A program
    // that the time limit stopped (with SIGKILL, 9) gets the text of the time limit. This is the
    // one test of a timeout on the real clock.
    @Test(.tags(.timing)) func aProgramWithNoExitCodeGetsTheSignalText() async {
        let signal = await run(Command("/bin/sh", ["-c", "kill -TERM $$"], timeout: ends))
        #expect(signal.stderr == "/bin/sh stopped with signal 15.")
        // The sleep of 60 s ends only at the timeout, also after a slow start under load.
        let timeout = await run(Command("/bin/sleep", ["60"], timeout: .milliseconds(100)))
        #expect(
            timeout
                == ExecResult(.timedOut, stderr: "/bin/sleep did not finish within 0.1 s."))
        let withStderr = await run(
            Command("/bin/sh", ["-c", "echo bad >&2; kill -TERM $$"], timeout: ends))
        #expect(withStderr.stderr == "bad\n")
    }

    // Bifrost stops a program at a cancel. An empty stderr becomes the text of the stop.
    @MainActor
    @Test func aCancelGivesTheStopText() async throws {
        let temp = try TemporaryFolder()
        defer { temp.remove() }
        let mark = temp.appending("started")
        let task = Task { await run(Command("/bin/sh", ["-c", ": > '\(mark)'; exec sleep 5"])) }
        defer { task.cancel() }
        try #require(await waitUntil { fileExists(mark) })
        task.cancel()
        let result = await task.value
        #expect(result == ExecResult(.cancelled, stderr: stoppedText))
    }

    // The shell prints and ends at once, but its child keeps stdout open while the temp folder
    // exists. At the timeout the runner stops the reads, so the result comes while the child
    // runs. The shell exited with code 0, so the end is "exited": a program that exits with code
    // 0 is not timed out. The child writes a mark when the shell ended, and then the test moves
    // the clock to the timeout. The child writes a second mark at its end.
    @MainActor
    @Test func aTimeoutStopsTheReadsOfAProgramThatLeftAChild() async throws {
        let temp = try TemporaryFolder()
        defer { temp.remove() }
        let clock = ManualClock()
        let child =
            "p=$$; while kill -0 $p 2>/dev/null; do sleep 0.02; done; : > \"$1/shell ended\"; "
            + "i=0; while [ -d \"$1\" ] && [ $i -lt 1200 ]; do sleep 0.05; i=$((i + 1)); done; "
            + ": > \"$1/child ended\""
        let task = start(
            Command(
                "/bin/sh", ["-c", "(\(child)) & echo left", "sh", temp.path],
                timeout: .seconds(10)),
            on: clock)
        defer { task.cancel() }
        try #require(await waitUntil { fileExists(temp.appending("shell ended")) })
        try #require(await clock.waitForSleepers(1))
        clock.advance(by: .seconds(10))
        let result = await task.value
        #expect(result.end == .exited(0))
        #expect(!fileExists(temp.appending("child ended")))
    }

    // The output before the timeout stays in the result. The timeout is wide, so the shell prints
    // and ends long before it, also on a test host under load. This test runs on the real clock.
    @Test(.tags(.timing)) func theOutputBeforeTheTimeoutStays() async throws {
        let temp = try TemporaryFolder()
        defer { temp.remove() }
        let child =
            "i=0; while [ -d \"$1\" ] && [ $i -lt 1200 ]; do sleep 0.05; i=$((i + 1)); done"
        let result = await run(
            Command(
                "/bin/sh", ["-c", "(\(child)) & echo left", "sh", temp.path],
                timeout: .seconds(10)))
        #expect(result == ExecResult(.exited(0), stdout: "left\n"))
    }

    // The program records the SIGTERM of the timeout and goes on, so the run waits for its end. A
    // cancel then ends the wait at once. The loop of the program ends when the test removes its
    // folder.
    @MainActor
    @Test func aCancelAfterTheTimeoutEndsTheWait() async throws {
        let temp = try TemporaryFolder()
        defer { temp.remove() }
        let clock = ManualClock()
        let script =
            "trap ': > \"$1/term\"' TERM; : > \"$1/mark\"; "
            + "while [ -d \"$1\" ]; do sleep 0.05; done"
        let task = start(
            Command(
                "/bin/sh", ["-c", script, "sh", temp.path], timeout: .seconds(10),
                killSignal: .terminate),
            on: clock)
        defer { task.cancel() }
        try #require(await waitUntil { fileExists(temp.appending("mark")) })
        try #require(await clock.waitForSleepers(1))
        clock.advance(by: .seconds(10))
        try #require(await waitUntil { fileExists(temp.appending("term")) })
        task.cancel()
        // The cancel stops the reads at once, so the output can lack the last bytes.
        let result = await task.value
        #expect(result.end == .cancelled)
        #expect(result.stderr == stoppedText)
    }
}
