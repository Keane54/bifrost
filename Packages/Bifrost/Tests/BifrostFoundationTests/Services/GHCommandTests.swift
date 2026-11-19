import BifrostTestSupport
import Foundation
import Testing

@testable import BifrostFoundation

// The gh command. gh is a FakeRunner: no gh runs.
@Suite("the gh command")
struct GHCommandTests {
    // gh gets the env of the claude runs with the two fixed values, and the given folder as its
    // current folder. The two fixed values win over the values of the env.
    @Test func ghRunsInItsFolderAndAsksNothing() async throws {
        let folder = URL(filePath: "/nonexistent/gh/runs", directoryHint: .isDirectory)
        let runner = FakeRunner(ExecResult(.exited(0), stdout: "ok"))
        let gh = GHCommand(
            path: "gh", environment: ["PATH": "/opt/bin:/usr/bin", "GH_PROMPT_DISABLED": "0"],
            folder: folder, runner: runner)
        let result = await gh.run(["api", "rate_limit"])
        #expect(result.stdout == "ok")
        let command = try #require(runner.commands.first)
        #expect(command.executable == "gh")
        #expect(command.arguments == ["api", "rate_limit"])
        #expect(command.directory == folder.path(percentEncoded: false))
        #expect(
            command.environment == [
                "PATH": "/opt/bin:/usr/bin", "GH_PROMPT_DISABLED": "1",
                "GH_NO_UPDATE_NOTIFIER": "1",
            ])
        #expect(command.timeout == GHCommand.timeout)
        #expect(command.outputLimit == GHCommand.outputLimit)
        #expect(command.input == nil)
        #expect(command.waitsForEnd)
    }

    // A call can give gh its stdin, a time limit and an output limit of its own.
    @Test func aCallGivesItsInputAndItsLimits() async throws {
        let runner = FakeRunner(ExecResult(.exited(0)))
        let gh = GHCommand(
            path: "gh", environment: [:],
            folder: URL(filePath: "/nonexistent/gh", directoryHint: .isDirectory), runner: runner)
        _ = await gh.run(
            ["api", "graphql", "--input", "-"], input: Data("{}".utf8), timeout: .seconds(120),
            outputLimit: 16)
        let command = try #require(runner.commands.first)
        #expect(command.input == Data("{}".utf8))
        #expect(command.timeout == .seconds(120))
        #expect(command.outputLimit == 16)
        #expect(command.waitsForEnd)
    }
}
