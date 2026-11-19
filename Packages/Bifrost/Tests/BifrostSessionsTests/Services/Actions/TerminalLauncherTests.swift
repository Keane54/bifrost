// Open in terminal (docs/behaviour/actions.md, "Open in terminal"). The tests give a fake opener
// and a fake clipboard, so no test opens, activates or scripts an app. The command file is a
// real file in a temporary folder, and a manual clock moves its removal.
import BifrostFoundation
import BifrostTestSupport
import Darwin
import Foundation
import Testing

@testable import BifrostSessions

private let warp = InstalledApp(
    app: ProjectApp(id: .warp, label: "Warp"), path: "/Applications/Warp.app")
private let iterm = InstalledApp(
    app: ProjectApp(id: .iterm2, label: "iTerm2"), path: "/Applications/iTerm.app")
private let ghostty = InstalledApp(
    app: ProjectApp(id: .ghostty, label: "Ghostty"), path: "/Applications/Ghostty.app")
private let finder = InstalledApp(
    app: ProjectApp(id: .finder, label: "Finder"),
    path: "/System/Library/CoreServices/Finder.app")
private let vscode = InstalledApp(
    app: ProjectApp(id: .vscode, label: "VS Code"), path: "/Applications/Visual Studio Code.app")

private let owned = SessionRow.test(sessionId: "s1", shortId: "abcd1234")
private let external: SessionRow = {
    var row = SessionRow.test(sessionId: "s1", shortId: nil, kind: .external, pid: 4242)
    row.terminalApp = "iTerm"
    return row
}()

// A launcher with fakes and a run folder in a temporary folder.
@MainActor
private final class Harness {
    let folder: TemporaryFolder
    let opener: FakeOpener
    let clipboard = FakeClipboard()
    let clock = ManualClock()
    let launcher: TerminalLauncher

    var runFolder: String { folder.appending("dev/run") }

    init(
        _ rows: [SessionRow], apps: [InstalledApp] = [warp], claude: String? = "/bin/claude",
        terminal: TerminalApp? = nil, failure: ActionRefusal? = nil, runFolder: String? = nil
    ) throws {
        let folder = try TemporaryFolder()
        self.folder = folder
        opener = FakeOpener(failure: failure)
        launcher = TerminalLauncher(
            rows: { rows }, apps: { apps }, terminalOf: { _ in terminal },
            claudePath: { claude },
            runFolder: URL(
                filePath: runFolder ?? folder.appending("dev/run"), directoryHint: .isDirectory),
            opener: opener, clipboard: clipboard, clock: clock)
    }

    func file(_ shortId: String = "abcd1234") -> String { "\(runFolder)/attach-\(shortId).command" }

    var runFolderFiles: [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: runFolder)) ?? []
    }

    func open(_ sessionId: String = "s1") async -> Result<String?, ActionRefusal> {
        do throws(ActionRefusal) {
            return .success(try await launcher.openInTerminal(sessionId))
        } catch {
            return .failure(error)
        }
    }

    deinit { folder.remove() }
}

private func mode(_ path: String) -> mode_t? {
    var info = stat()
    guard lstat(path, &info) == 0 else { return nil }
    return info.st_mode & 0o7777
}

// The type of the file at the path, with no link followed.
private func fileType(_ path: String) -> mode_t? {
    var info = stat()
    guard lstat(path, &info) == 0 else { return nil }
    return info.st_mode & S_IFMT
}

@Suite("the attach script")
struct AttachScriptTests {
    @Test func theLaunchMethodOfEachTerminalApp() {
        #expect(TerminalAppID.warp.launch == .commandFile)
        #expect(TerminalAppID.terminal.launch == .commandFile)
        #expect(TerminalAppID.ghostty.launch == .clipboard)
        #expect(TerminalAppID.iterm2.launch == .clipboard)
        #expect(TerminalLauncher.attachCommand("abcd1234") == "claude attach abcd1234")
    }

    @Test func theScriptRunsTheClaudePathWithTheShortId() {
        #expect(
            TerminalLauncher.attachScript(claudePath: "/bin/claude", shortId: "abcd1234")
                == "#!/bin/sh\nexec '/bin/claude' attach abcd1234\n")
    }

    // A quote in the path becomes '\''. The escape reads Unicode scalars, so a quote with a
    // combining mark after it is still a quote for the shell.
    @Test func aQuoteInTheClaudePathIsEscaped() {
        #expect(
            TerminalLauncher.attachScript(claudePath: "/a b/it's/claude", shortId: "abcd1234")
                == "#!/bin/sh\nexec '/a b/it'\\''s/claude' attach abcd1234\n")
        #expect(
            TerminalLauncher.attachScript(claudePath: "/a/it'\u{301}s/claude", shortId: "abcd1234")
                == "#!/bin/sh\nexec '/a/it'\\''\u{301}s/claude' attach abcd1234\n")
    }

    // The shell runs the script in a temporary folder. The claude of the script is a fake that
    // prints its arguments, at a path with quotes, a combining mark and a command substitution.
    @Test func theShellRunsTheClaudePathAsOneWord() async throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let dir = folder.appending("it's it'\u{301}s $(touch pwned) `touch pwned`")
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let claude = dir + "/claude"
        try "#!/bin/sh\nprintf '%s\\n' \"$@\"\n".write(
            toFile: claude, atomically: true, encoding: .utf8)
        #expect(chmod(claude, 0o700) == 0)
        let script = folder.appending("attach.command")
        try TerminalLauncher.attachScript(claudePath: claude, shortId: "abcd1234").write(
            toFile: script, atomically: true, encoding: .utf8)
        let result = await ProcessRunner().run(
            Command(
                "/bin/sh", [script], directory: folder.path, environment: ["PATH": "/usr/bin:/bin"],
                timeout: .seconds(10)))
        #expect(result.end == .exited(0))
        #expect(result.stdout == "attach\nabcd1234\n")
        #expect(!FileManager.default.fileExists(atPath: folder.appending("pwned")))
    }
}

@MainActor
@Suite("Open in terminal")
struct TerminalLauncherTests {
    @Test func theCommandFileStays30s() {
        #expect(TerminalLauncher.scriptKeep == .seconds(30))
    }

    @Test func anOwnedSessionOpensACommandFileInTheTerminalApp() async throws {
        let h = try Harness([owned])
        #expect(await h.open() == .success(nil))
        let text = try String(contentsOfFile: h.file(), encoding: .utf8)
        #expect(text == "#!/bin/sh\nexec '/bin/claude' attach abcd1234\n")
        #expect(h.opener.calls == [.open(file: h.file(), app: "/Applications/Warp.app")])
        #expect(h.clipboard.texts.isEmpty)
        // The temporary file of the write does not stay.
        #expect(h.runFolderFiles == ["attach-abcd1234.command"])
    }

    @Test func theRunFolderAndTheCommandFileHaveMode0700() async throws {
        let h = try Harness([owned])
        _ = await h.open()
        #expect(mode(h.runFolder) == 0o700)
        #expect(mode(h.file()) == 0o700)
    }

    // An old file at the path gets the new text and mode 0700.
    @Test func anOldCommandFileIsWrittenAgainWithMode0700() async throws {
        let h = try Harness([owned])
        try FileManager.default.createDirectory(
            atPath: h.runFolder, withIntermediateDirectories: true)
        try "old text that is longer than the new script\n\n\n\n\n".write(
            toFile: h.file(), atomically: false, encoding: .utf8)
        #expect(chmod(h.file(), 0o644) == 0)
        _ = await h.open()
        #expect(
            try String(contentsOfFile: h.file(), encoding: .utf8)
                == TerminalLauncher.attachScript(claudePath: "/bin/claude", shortId: "abcd1234"))
        #expect(mode(h.file()) == 0o700)
    }

    // The write goes to a new file, and a rename puts it at the name. A link at the name is
    // replaced, and its target stays as it was.
    @Test func aLinkAtTheNameIsReplacedAndItsTargetStays() async throws {
        let h = try Harness([owned])
        try FileManager.default.createDirectory(
            atPath: h.runFolder, withIntermediateDirectories: true)
        let target = h.folder.appending("target")
        try "keep\n".write(toFile: target, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(atPath: h.file(), withDestinationPath: target)
        #expect(await h.open() == .success(nil))
        #expect(try String(contentsOfFile: target, encoding: .utf8) == "keep\n")
        #expect(fileType(h.file()) == S_IFREG)
        #expect(mode(h.file()) == 0o700)
    }

    // A hard link at the name shares its file with another name. The write never reaches that
    // file, and its mode stays.
    @Test func aHardLinkAtTheNameLeavesTheOtherFileAsItWas() async throws {
        let h = try Harness([owned])
        try FileManager.default.createDirectory(
            atPath: h.runFolder, withIntermediateDirectories: true)
        let other = h.folder.appending("other")
        try "keep\n".write(toFile: other, atomically: true, encoding: .utf8)
        #expect(chmod(other, 0o644) == 0)
        #expect(link(other, h.file()) == 0)
        #expect(await h.open() == .success(nil))
        #expect(try String(contentsOfFile: other, encoding: .utf8) == "keep\n")
        #expect(mode(other) == 0o644)
        #expect(
            try String(contentsOfFile: h.file(), encoding: .utf8)
                == TerminalLauncher.attachScript(claudePath: "/bin/claude", shortId: "abcd1234"))
    }

    // A named pipe at the name has no reader. The write does not wait for one.
    @Test func aPipeAtTheNameDoesNotHoldTheWrite() async throws {
        let h = try Harness([owned])
        try FileManager.default.createDirectory(
            atPath: h.runFolder, withIntermediateDirectories: true)
        #expect(mkfifo(h.file(), 0o600) == 0)
        #expect(await h.open() == .success(nil))
        #expect(fileType(h.file()) == S_IFREG)
    }

    // A run folder that is a link can point anywhere, so the write is refused.
    @Test func aRunFolderThatIsALinkIsRefused() async throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let real = folder.appending("real")
        try FileManager.default.createDirectory(atPath: real, withIntermediateDirectories: true)
        let linked = folder.appending("run")
        try FileManager.default.createSymbolicLink(atPath: linked, withDestinationPath: real)
        let h = try Harness([owned], runFolder: linked)
        #expect(await h.open() == .failure(.commandFileFailed))
        #expect(try FileManager.default.contentsOfDirectory(atPath: real).isEmpty)
        #expect(h.opener.calls.isEmpty)
        // The removal of the failed write also does not follow the link.
        try "keep\n".write(
            toFile: "\(real)/attach-abcd1234.command", atomically: true, encoding: .utf8)
        let removal = h.launcher.removal(of: "\(linked)/attach-abcd1234.command")
        await h.clock.waitForSleepers(1)
        h.clock.advance(by: .seconds(30))
        await removal?.value
        #expect(FileManager.default.fileExists(atPath: "\(real)/attach-abcd1234.command"))
    }

    // A run folder that other users can use gets mode 0700.
    @Test func aLooseRunFolderGetsMode0700() async throws {
        let h = try Harness([owned])
        try FileManager.default.createDirectory(
            atPath: h.runFolder, withIntermediateDirectories: true)
        #expect(chmod(h.runFolder, 0o755) == 0)
        #expect(await h.open() == .success(nil))
        #expect(mode(h.runFolder) == 0o700)
    }

    // A folder at the name stops the rename. The write fails and leaves no temporary file.
    @Test func aFolderAtTheNameIsRefusedAndLeavesNoTemporaryFile() async throws {
        let h = try Harness([owned])
        try FileManager.default.createDirectory(atPath: h.file(), withIntermediateDirectories: true)
        #expect(await h.open() == .failure(.commandFileFailed))
        #expect(h.runFolderFiles == ["attach-abcd1234.command"])
        #expect(h.opener.calls.isEmpty)
    }

    @Test func aRunFolderThatCannotBeMadeGivesItsRefusal() async throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let file = folder.appending("file")
        try "x".write(toFile: file, atomically: true, encoding: .utf8)
        let h = try Harness([owned], runFolder: file + "/run")
        #expect(await h.open() == .failure(.commandFileFailed))
        #expect(h.opener.calls.isEmpty)
    }

    @Test func theCommandFileGoesAfter30s() async throws {
        let h = try Harness([owned])
        _ = await h.open()
        let removal = h.launcher.removal(of: h.file())
        #expect(removal != nil)
        await h.clock.waitForSleepers(1)
        h.clock.advance(by: .seconds(30) - .milliseconds(1))
        #expect(FileManager.default.fileExists(atPath: h.file()))
        h.clock.advance(by: .milliseconds(1))
        await removal?.value
        #expect(!FileManager.default.fileExists(atPath: h.file()))
        #expect(h.launcher.removal(of: h.file()) == nil)
    }

    // A second open of the same session writes the file again, and it stays 30 s from then.
    @Test func aSecondOpenKeepsTheCommandFile30sFromThen() async throws {
        let h = try Harness([owned])
        _ = await h.open()
        await h.clock.waitForSleepers(1)
        h.clock.advance(by: .seconds(20))
        _ = await h.open()
        let removal = h.launcher.removal(of: h.file())
        await h.clock.waitForSleepers(exactly: 1)
        h.clock.advance(by: .seconds(20))
        #expect(FileManager.default.fileExists(atPath: h.file()))
        h.clock.advance(by: .seconds(10))
        await removal?.value
        #expect(!FileManager.default.fileExists(atPath: h.file()))
    }

    // Each session has its own file and its own timer.
    @Test func twoSessionsHaveTwoCommandFiles() async throws {
        let other = SessionRow.test(sessionId: "s2", shortId: "0000ffff")
        let h = try Harness([owned, other])
        _ = await h.open("s1")
        _ = await h.open("s2")
        #expect(Set(h.runFolderFiles) == ["attach-abcd1234.command", "attach-0000ffff.command"])
        let removals = [h.file(), h.file("0000ffff")].map { h.launcher.removal(of: $0) }
        await h.clock.waitForSleepers(2)
        h.clock.advance(by: .seconds(30))
        for removal in removals { await removal?.value }
        #expect(h.runFolderFiles.isEmpty)
    }

    @Test func aClipboardTerminalGetsTheAttachCommandAndANotice() async throws {
        let h = try Harness([owned], apps: [finder, iterm])
        #expect(
            await h.open()
                == .success(
                    #"Copied "claude attach abcd1234". Paste it into iTerm2 to open the session."#
                ))
        #expect(h.clipboard.texts == ["claude attach abcd1234"])
        #expect(h.opener.calls == [.activate(app: "/Applications/iTerm.app")])
        #expect(h.runFolderFiles.isEmpty)
    }

    // The list of the installed apps has one terminal app. With more, the first of the terminal
    // order opens.
    @Test func theFirstTerminalAppOfTheOrderOpens() async throws {
        let h = try Harness([owned], apps: [finder, vscode, iterm, ghostty])
        _ = await h.open()
        #expect(h.opener.calls == [.activate(app: "/Applications/Ghostty.app")])
    }

    @Test func anExternalSessionBringsItsTerminalAppToTheFront() async throws {
        let h = try Harness(
            [external], terminal: TerminalApp(name: "iTerm", bundle: "/Applications/iTerm.app"))
        #expect(await h.open() == .success(nil))
        #expect(h.opener.calls == [.activate(app: "/Applications/iTerm.app")])
        #expect(h.clipboard.texts.isEmpty)
        #expect(h.runFolderFiles.isEmpty)
    }

    @Test(arguments: [
        ActionRefusal.openFailed("No app can open it."),
        .openFailed("open did not finish in time."),
    ])
    func aFailedOpenGivesItsRefusal(failure: ActionRefusal) async throws {
        let file = try Harness([owned], failure: failure)
        #expect(await file.open() == .failure(failure))
        let clip = try Harness([owned], apps: [iterm], failure: failure)
        #expect(await clip.open() == .failure(failure))
        let ext = try Harness(
            [external], terminal: TerminalApp(name: "iTerm", bundle: "/Applications/iTerm.app"),
            failure: failure)
        #expect(await ext.open() == .failure(failure))
    }

    // The timer starts before the open, so a failed open also loses its file after 30 s.
    @Test func theCommandFileOfAFailedOpenAlsoGoes() async throws {
        let h = try Harness([owned], failure: .openFailed("No app can open it."))
        _ = await h.open()
        let removal = h.launcher.removal(of: h.file())
        await h.clock.waitForSleepers(1)
        h.clock.advance(by: .seconds(30))
        await removal?.value
        #expect(h.runFolderFiles.isEmpty)
    }

    // exec reads a word that starts with "-" as an option, so only an absolute path can run.
    @Test(arguments: ["-a", "claude", "", "/bin/cl\0aude", " /bin/claude"])
    func aClaudePathThatIsNotAbsoluteIsRefused(path: String) async throws {
        let h = try Harness([owned], claude: path)
        #expect(await h.open() == .failure(.claudeNotFound))
        #expect(h.opener.calls.isEmpty)
        #expect(h.runFolderFiles.isEmpty)
    }

    @Test func noClaudeGivesTheNotFoundRefusalAndNoFile() async throws {
        let h = try Harness([owned], claude: nil)
        #expect(await h.open() == .failure(.claudeNotFound))
        #expect(h.opener.calls.isEmpty)
        #expect(h.runFolderFiles.isEmpty)
    }

    // A clipboard terminal needs no claude path.
    @Test func aClipboardTerminalNeedsNoClaudePath() async throws {
        let h = try Harness([owned], apps: [iterm], claude: nil)
        #expect(await h.open() != .failure(.claudeNotFound))
        #expect(h.clipboard.texts == ["claude attach abcd1234"])
    }

    @Test func eachRefusalComesBeforeAnyFileClipboardOrOpen() async throws {
        var parked = owned
        parked.state = .parked
        let cases: [(Harness, String, ActionRefusal)] = [
            (try Harness([parked]), "s1", .parked),
            (try Harness([owned]), "nope", .unknownSession),
            (try Harness([SessionRow.test(sessionId: "s1", shortId: nil)]), "s1", .badSessionId),
            (try Harness([owned], apps: []), "s1", .noTerminal),
            (try Harness([owned], apps: [finder, vscode]), "s1", .noTerminal),
            (try Harness([external]), "s1", .terminalUnknown),
        ]
        for (h, id, refusal) in cases {
            #expect(await h.open(id) == .failure(refusal))
            #expect(h.opener.calls.isEmpty)
            #expect(h.clipboard.texts.isEmpty)
            #expect(h.runFolderFiles.isEmpty)
        }
    }

    // A parked external session is refused as parked, before its terminal app counts.
    @Test func aParkedExternalSessionIsRefusedAsParked() async throws {
        var row = external
        row.state = .parked
        let h = try Harness(
            [row], terminal: TerminalApp(name: "iTerm", bundle: "/Applications/iTerm.app"))
        #expect(await h.open() == .failure(.parked))
        #expect(h.opener.calls.isEmpty)
    }

    // The short ID comes from the list of claude agents. That parse refuses each text that is
    // not 8 lower-case hex digits, so a bad short ID cannot reach the script or the clipboard.
    @Test(arguments: ["x; rm -rf ~", "-abcdefg", "ABCD1234", "abcd12345", "abcd123", "abcd 123"])
    func aBadShortIdNeverReachesACommand(id: String) async throws {
        let json = try String(
            decoding: JSONEncoder().encode([["sessionId": "s1", "id": id, "cwd": "/p"]]),
            as: UTF8.self)
        guard case .parsed(let entries, _) = AgentList(output: json), let entry = entries.first
        else {
            Issue.record("The list did not parse.")
            return
        }
        #expect(entry.id == nil)
        for apps in [[warp], [iterm]] {
            let h = try Harness([SessionRow.test(sessionId: "s1", shortId: entry.id)], apps: apps)
            #expect(await h.open() == .failure(.badSessionId))
            #expect(h.opener.calls.isEmpty)
            #expect(h.clipboard.texts.isEmpty)
            #expect(h.runFolderFiles.isEmpty)
        }
    }

    // MARK: - The old files of an earlier run

    // A command file and a temporary file of a write have the forms of the write. Each other
    // name is not an old file.
    @Test func theOldFilesHaveTheFormsOfTheWrite() {
        let uuid = "0A1B2C3D-4E5F-4A6B-8C7D-9E0F1A2B3C4D"
        for name in ["attach-abcd1234.command", ".attach-abcd1234.command.\(uuid).tmp"] {
            #expect(TerminalLauncher.isOldFile(name), "\(name)")
        }
        let others = [
            "attach-ABCD1234.command", "attach-abcd123.command", "attach-.command",
            "attach-abcd1234.command.bak", "xattach-abcd1234.command", "notes.txt",
            ".attach-abcd1234.command.x.tmp", ".attach-abcd1234.command.\(uuid)",
            "attach-abcd1234.command.\(uuid).tmp", ".attach-abcd1234.\(uuid).tmp",
            ".attach-x.command.\(uuid).tmp",
        ]
        for name in others {
            #expect(!TerminalLauncher.isOldFile(name), "\(name)")
        }
    }

    // The removal at the start removes the command files and the temporary files of an earlier
    // run, and keeps each other file of the run folder.
    @Test func theOldFilesOfAnEarlierRunGo() async throws {
        let h = try Harness([owned])
        try FileManager.default.createDirectory(
            atPath: h.runFolder, withIntermediateDirectories: true)
        let names = [
            "attach-abcd1234.command", "attach-0000ffff.command",
            ".attach-abcd1234.command.\(UUID().uuidString).tmp", "notes.txt",
            "attach-abcd1234.command.bak",
        ]
        for name in names {
            try "x\n".write(toFile: "\(h.runFolder)/\(name)", atomically: false, encoding: .utf8)
        }
        await h.launcher.removeOldFiles().value
        #expect(h.runFolderFiles.sorted() == ["attach-abcd1234.command.bak", "notes.txt"])
    }

    // A run folder that is a link can point anywhere, so the removal removes nothing there. A
    // run folder that is not there gives no error.
    @Test func theRemovalOfOldFilesDoesNotFollowALinkedRunFolder() async throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let real = folder.appending("real")
        try FileManager.default.createDirectory(atPath: real, withIntermediateDirectories: true)
        try "keep\n".write(
            toFile: "\(real)/attach-abcd1234.command", atomically: true, encoding: .utf8)
        let linked = folder.appending("run")
        try FileManager.default.createSymbolicLink(atPath: linked, withDestinationPath: real)
        let h = try Harness([owned], runFolder: linked)
        await h.launcher.removeOldFiles().value
        #expect(FileManager.default.fileExists(atPath: "\(real)/attach-abcd1234.command"))
        let missing = try Harness([owned], runFolder: folder.appending("none/run"))
        await missing.launcher.removeOldFiles().value
        #expect(!FileManager.default.fileExists(atPath: folder.appending("none")))
    }

    // An open right after the start waits for the removal of the old files, so the new command
    // file stays. The removal waits at a gate: while it waits, the open writes nothing. A second
    // call of the removal gives the same task and removes nothing more.
    @Test func anOpenAfterTheStartKeepsItsNewCommandFile() async throws {
        let h = try Harness([owned])
        try FileManager.default.createDirectory(
            atPath: h.runFolder, withIntermediateDirectories: true)
        try "old\n".write(toFile: h.file(), atomically: false, encoding: .utf8)
        let gate = TestGate()
        defer { gate.openAll() }
        let removal = h.launcher.removeOldFiles { await gate.pass() }
        let open = Task { await h.open() }
        await gate.waitUntilHolding(1)
        for _ in 0..<10 { await Task.yield() }
        #expect(try String(contentsOfFile: h.file(), encoding: .utf8) == "old\n")
        #expect(h.opener.calls.isEmpty)
        gate.openAll()
        #expect(await open.value == .success(nil))
        await removal.value
        #expect(h.launcher.removeOldFiles() == removal)
        #expect(
            try String(contentsOfFile: h.file(), encoding: .utf8)
                == TerminalLauncher.attachScript(claudePath: "/bin/claude", shortId: "abcd1234"))
    }
}
