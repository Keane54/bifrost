import BifrostFoundation
import BifrostTestSupport
import Foundation
import Testing

@testable import BifrostDailyUpdate

// The read of the merged PRs through gh. gh is a FakeRunner: no gh runs.

private let folder = URL(filePath: "/nonexistent/daily-update/runs", directoryHint: .isDirectory)
private let since = Date(timeIntervalSince1970: 1_794_873_600)  // 2026-11-17T00:00:00Z

private func reader(_ runner: FakeRunner) -> MergedPRsReader {
    MergedPRsReader(
        gh: GHCommand(
            path: "gh", environment: ["PATH": "/opt/bin:/usr/bin", "GH_PROMPT_DISABLED": "0"],
            folder: folder, runner: runner))
}

@Suite("the read of the merged PRs")
struct MergedPRsReaderTests {
    // gh gets the env of the claude runs with the two fixed values, and the runs folder as its
    // current folder.
    @Test func ghRunsInTheRunsFolderAndAsksNothing() async throws {
        let runner = FakeRunner(ExecResult(.exited(0), stdout: "[]"))
        #expect(await reader(runner).read(since: since) == .success([]))
        let command = try #require(runner.commands.first)
        #expect(command.executable == "gh")
        #expect(command.arguments == MergedPRs.args(since: since))
        #expect(command.directory == folder.path(percentEncoded: false))
        #expect(
            command.environment == [
                "PATH": "/opt/bin:/usr/bin", "GH_PROMPT_DISABLED": "1",
                "GH_NO_UPDATE_NOTIFIER": "1",
            ])
        #expect(command.timeout == GHCommand.timeout)
        #expect(command.input == nil)
    }

    @Test func aFailureOfGhGivesItsReason() async {
        let failed = FakeRunner(
            ExecResult(.exited(1), stderr: "\n  To get started, run: gh auth login\u{202E}\nmore"))
        #expect(
            await reader(failed).read(since: since)
                == .failure(.failed("To get started, run: gh auth login")))
        let missing = FakeRunner(ExecResult(.notStarted, stderr: "Cannot start gh."))
        #expect(await reader(missing).read(since: since) == .failure(.notStarted))
        let slow = FakeRunner(ExecResult(.timedOut))
        #expect(await reader(slow).read(since: since) == .failure(.timedOut))
        let silent = FakeRunner(ExecResult(.exited(4)))
        #expect(await reader(silent).read(since: since) == .failure(.failed(nil)))
        let garbled = FakeRunner(ExecResult(.exited(0), stdout: "<html>"))
        #expect(await reader(garbled).read(since: since) == .failure(.badAnswer))
    }
}
