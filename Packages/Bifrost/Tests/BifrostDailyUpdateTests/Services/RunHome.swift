import BifrostFoundation
import BifrostSessions
import BifrostTestSupport
import Foundation
import Testing

@testable import BifrostDailyUpdate

// A test home for the runs of the Daily update, in the test sandbox. claude is the fake claude of
// scripts/fake-claude with the test home as HOME and BIFROST_TEST_HOME, so it reads and writes
// only files of the test home: fake-mcp-init.json (the probe), fake-daily-result.json (the run),
// fake-daily-hang (a run that waits) and claude-calls.log (the arguments of each call). gh is a
// FakeRunner: no gh runs. No test runs the real claude or uses a real model.
@MainActor
final class RunHome {
    let folder: TemporaryFolder
    let layout: DailyLayout
    let skills: URL
    let claude: ClaudeRunner
    let gh: FakeRunner
    let clock = ManualClock()
    private(set) var events: [DailyRunEvent] = []

    // ghResult is the answer of each gh call.
    init(ghResult: ExecResult = ExecResult(.exited(0), stdout: "[]")) throws {
        folder = try TemporaryFolder()
        layout = DailyLayout(folder: folder.url.appending(path: ".bifrost/daily-update"))
        skills = folder.url.appending(path: "bifrost-skills", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: skills, withIntermediateDirectories: true)
        let fake = try Repo.fakeClaude()
        let bin = URL(fileURLWithPath: fake).deletingLastPathComponent().path
        let base = [
            "PATH": "\(bin):/usr/bin:/bin", "HOME": folder.path, "BIFROST_TEST_HOME": folder.path,
            "LANG": "en_US.UTF-8",
        ]
        claude = ClaudeRunner(path: fake, baseEnvironment: base, runner: ProcessRunner())
        gh = FakeRunner(ghResult)
        try write("fake-mcp-init.json", initLine + "\n")
    }

    func finish() {
        folder.remove()
    }

    // The runner of the drafts, with the gh fake in the runs folder.
    func runner() -> DailyRunner {
        let ghCommand = GHCommand(
            path: "gh", environment: claude.environment, folder: layout.runsFolder, runner: gh)
        return DailyRunner(
            claude: claude, gh: ghCommand, layout: layout, skills: skills,
            report: { [weak self] in self?.events.append($0) }, clock: clock,
            calendar: calendar())
    }

    func write(_ name: String, _ text: String) throws {
        try Data(text.utf8).write(to: folder.url.appending(path: name))
    }

    func write(_ name: String, _ data: Data) throws {
        try data.write(to: folder.url.appending(path: name))
    }

    // Each call of the fake claude: its arguments, with one space between them.
    var calls: [String] {
        let text = FileManager.default.contents(atPath: folder.appending("claude-calls.log"))
        return String(decoding: text ?? Data(), as: UTF8.self).split(separator: "\n")
            .map(String.init)
    }

    // The calls of the run of the drafts.
    var runCalls: [String] { calls.filter { $0.hasPrefix("-p --output-format json ") } }

    // The pid of the fake run that waits, once it wrote it.
    var hangingPid: pid_t? {
        let file = folder.appending("fake-daily-pid")
        guard let text = try? String(contentsOfFile: file, encoding: .utf8) else { return nil }
        return pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    // The folders of the runs, by name.
    var runFolders: [String] {
        let names = try? FileManager.default.contentsOfDirectory(
            atPath: layout.runsFolder.path(percentEncoded: false))
        return (names ?? []).sorted()
    }
}

// The mode bits of a file or folder, or nil.
func mode(of path: String) -> mode_t? {
    var info = stat()
    guard stat(path, &info) == 0 else { return nil }
    return info.st_mode & 0o777
}
