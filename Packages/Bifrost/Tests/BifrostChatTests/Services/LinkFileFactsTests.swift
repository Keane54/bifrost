// The facts of real files and the action of a link to them. Each test makes its items in a temp
// folder that it owns. The tests only compute the action. No test opens a link, starts an app or
// shows Finder, and no test asks Launch Services: a fake gives the apps. The time limit runs on a
// manual clock.
import BifrostChat
import BifrostTestSupport
import Foundation
import Synchronization
import Testing
import UniformTypeIdentifiers

private let host = "devbox.local"

// A fake app at /Applications/<bundle ID>.app.
private func fakeApp(_ id: String) -> AppFacts {
    AppFacts(
        url: URL(filePath: "/Applications/\(id).app", directoryHint: .isDirectory), bundleID: id)
}

// The fake apps of Launch Services. byName gives the app of each file name (a bundle ID).
// typeByName gives the default app of the type of the file when it is another app (a per-file
// Open With binding). With no entry in typeByName, the app of the file is the default app of its
// type. Terminal is a terminal, so Launch Services answers.
private struct FakeApps: DefaultApps {
    var byName: [String: String] = [:]
    var typeByName: [String: String] = [:]
    var terminals: Set<String> = ["com.apple.Terminal"]

    func opener(of file: FileFacts) -> OpenerFacts {
        let name = URL(filePath: file.realPath).lastPathComponent
        let app = byName[name].map(fakeApp)
        let typeApp = typeByName[name].map(fakeApp)?.url ?? app?.url
        return OpenerFacts(app: app, typeApp: typeApp, terminalIDs: terminals)
    }
}

// Launch Services with an answer only after the test opens the gate: the editor opens each file.
private struct WaitingApps: DefaultApps {
    let gate: TestGate

    func opener(of file: FileFacts) -> OpenerFacts {
        gate.passBlocking()
        let editor = fakeApp("dev.example.editor")
        return OpenerFacts(app: editor, typeApp: editor.url, terminalIDs: ["com.apple.Terminal"])
    }
}

// Launch Services that answers only after the test opens the gate, and records the names of the
// files it was asked for and the most lookups that ran at the same time.
private final class CountingApps: DefaultApps {
    private struct Calls {
        var names: [String] = []
        var running = 0
        var most = 0
    }

    let gate: TestGate
    private let calls = Mutex(Calls())

    init(gate: TestGate) { self.gate = gate }

    var names: [String] { calls.withLock { $0.names } }
    var most: Int { calls.withLock { $0.most } }

    func opener(of file: FileFacts) -> OpenerFacts {
        calls.withLock { calls in
            calls.names.append(URL(filePath: file.realPath).lastPathComponent)
            calls.running += 1
            calls.most = max(calls.most, calls.running)
        }
        gate.passBlocking()
        calls.withLock { $0.running -= 1 }
        let editor = fakeApp("dev.example.editor")
        return OpenerFacts(app: editor, typeApp: editor.url, terminalIDs: ["com.apple.Terminal"])
    }
}

private struct Tree {
    let temp: TemporaryFolder
    // The real path of the folder (realpath(3)), for example /private/tmp/....
    let real: String

    // An empty temp folder.
    init() throws {
        temp = try TemporaryFolder(short: true)
        let resolved = try #require(realpath(temp.path, nil))
        real = String(cString: resolved)
        free(resolved)
    }

    // A folder with a fake app folder, a fake .command file, a plain document, and symbolic
    // links with plain names to them.
    static func usual() throws -> Tree {
        let tree = try Tree()
        do {
            try tree.folder("Tool.app/Contents")
            try tree.file("go.command")
            try tree.file("notes.txt")
            let links = [("tool", "Tool.app"), ("go", "go.command"), ("doc", "notes.txt")]
            for (name, target) in links {
                try FileManager.default.createSymbolicLink(
                    atPath: tree.temp.appending(name),
                    withDestinationPath: tree.temp.appending(target))
            }
        } catch {
            tree.remove()
            throw error
        }
        return tree
    }

    // A plain file with no execute bit.
    func file(_ name: String) throws {
        try Data("echo\n".utf8).write(to: URL(filePath: temp.appending(name)))
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o644], ofItemAtPath: temp.appending(name))
    }

    // An empty folder, with the usual mode 0755.
    func folder(_ name: String) throws {
        try FileManager.default.createDirectory(
            atPath: temp.appending(name), withIntermediateDirectories: true)
    }

    // The action of a file link to the folder and the rest of the path. With no fake apps, no
    // file has an app, so a file that the type rules open opens with no app (macOS asks).
    func action(_ rest: String, apps: FakeApps = FakeApps()) async -> LinkAction {
        await LinkRules.action(
            forLink: "file://\(temp.path)\(rest)", localHost: host,
            lookup: OpenerLookup(apps: apps), clock: ManualClock())
    }

    func remove() { temp.remove() }
}

@Suite("link real paths", .timeLimit(.minutes(1)))
struct LinkRealPathTests {
    @Test func aTrailingSlashShowsTheAppInFinder() async throws {
        let tree = try Tree.usual()
        defer { tree.remove() }
        #expect(await tree.action("/Tool.app/") == .showInFinder("\(tree.real)/Tool.app"))
    }

    @Test func aDotSegmentShowsTheAppInFinder() async throws {
        let tree = try Tree.usual()
        defer { tree.remove() }
        #expect(await tree.action("/Tool.app/.") == .showInFinder("\(tree.real)/Tool.app"))
    }

    @Test func anEncodedDotSegmentShowsTheAppInFinder() async throws {
        let tree = try Tree.usual()
        defer { tree.remove() }
        #expect(await tree.action("/Tool.app/%2e") == .showInFinder("\(tree.real)/Tool.app"))
    }

    @Test func aParentSegmentShowsTheAppInFinder() async throws {
        let tree = try Tree.usual()
        defer { tree.remove() }
        let action = await tree.action("/Tool.app/Contents/..")
        #expect(action == .showInFinder("\(tree.real)/Tool.app"))
    }

    @Test func anEncodedParentSegmentShowsTheAppInFinder() async throws {
        let tree = try Tree.usual()
        defer { tree.remove() }
        let action = await tree.action("/Tool.app/Contents/%2e%2e")
        #expect(action == .showInFinder("\(tree.real)/Tool.app"))
    }

    @Test func aLinkWithAPlainNameToAnAppShowsTheAppInFinder() async throws {
        let tree = try Tree.usual()
        defer { tree.remove() }
        #expect(await tree.action("/tool") == .showInFinder("\(tree.real)/Tool.app"))
    }

    @Test func aLinkWithAPlainNameToACommandFileShowsTheFileInFinder() async throws {
        let tree = try Tree.usual()
        defer { tree.remove() }
        #expect(await tree.action("/go") == .showInFinder("\(tree.real)/go.command"))
    }

    // Only this test makes an alias file: the bookmark of an app registers the app with
    // Launch Services, and many registrations at the same time can stop the tests.
    @Test func anAliasFileShowsInFinder() async throws {
        let tree = try Tree.usual()
        defer { tree.remove() }
        let bookmark = try URL(filePath: tree.temp.appending("Tool.app")).bookmarkData(
            options: .suitableForBookmarkFile, includingResourceValuesForKeys: nil,
            relativeTo: nil)
        try URL.writeBookmarkData(bookmark, to: URL(filePath: tree.temp.appending("shortcut")))
        let facts = try #require(FileFacts(atPath: tree.temp.appending("shortcut")))
        #expect(facts.isAlias)
        #expect(!facts.isFolder)
        #expect(!facts.executable)
        #expect(facts.contentType.conforms(to: .aliasFile))
        #expect(await tree.action("/shortcut") == .showInFinder("\(tree.real)/shortcut"))
    }

    @Test func aNulShowsNothing() async throws {
        let tree = try Tree.usual()
        defer { tree.remove() }
        #expect(await tree.action("/Tool.app%00") == .nothing)
        #expect(await tree.action("/Tool.app%00.txt") == .nothing)
        #expect(FileFacts(atPath: tree.temp.appending("Tool.app\u{0}")) == nil)
    }

    // A plain document and a link to it open (the real path), a missing file does nothing, and
    // http and https open in the browser.
    @Test func aDocumentALinkToItAndWebLinksActAsBefore() async throws {
        let tree = try Tree.usual()
        defer { tree.remove() }
        #expect(await tree.action("/notes.txt") == .openFile("\(tree.real)/notes.txt", app: nil))
        #expect(await tree.action("/doc") == .openFile("\(tree.real)/notes.txt", app: nil))
        #expect(await tree.action("/missing.txt") == .nothing)
        for link in ["https://example.com/a", "http://localhost:5173/"] {
            let action = await LinkRules.action(
                forLink: link, localHost: host, lookup: OpenerLookup(apps: FakeApps()),
                clock: ManualClock())
            #expect(action == .openWeb(try #require(URL(string: link))))
        }
    }

    // The facts read the type, the folder, the execute bits and the package mark of the real
    // path.
    @Test func theFactsAreTheFactsOfTheRealPath() throws {
        let tree = try Tree.usual()
        defer { tree.remove() }
        let app = try #require(FileFacts(atPath: tree.temp.appending("tool")))
        #expect(
            app
                == FileFacts(
                    realPath: "\(tree.real)/Tool.app", contentType: .applicationBundle,
                    isFolder: true, executable: true, isPackage: true))
        let document = try #require(FileFacts(atPath: tree.temp.appending("doc")))
        #expect(
            document == FileFacts(realPath: "\(tree.real)/notes.txt", contentType: .plainText))
    }
}

// The type of a real file decides, also with no execute bit. Each name is one plain file with
// mode 0644 in a new temp folder.
@Suite("link file types", .timeLimit(.minutes(1)))
struct LinkFileTypeTests {
    private func fileAction(_ name: String) async throws -> (LinkAction, String) {
        let tree = try Tree()
        defer { tree.remove() }
        try tree.file(name)
        return (await tree.action("/\(name)"), "\(tree.real)/\(name)")
    }

    // A program, and a script that a shell, Terminal or Script Editor runs. A Perl module and a
    // .rbw file have the type of a Perl or a Ruby script.
    @Test(arguments: [
        "a.app", "a.exe", "a.jar", "a.ipa", "a.pyc", "a.sh", "a.bash", "a.zsh", "a.csh", "a.ksh",
        "a.tcsh", "a.command", "a.tool", "Run.SH", "a.py", "a.pl", "a.pm", "a.rb", "a.rbw",
        "a.applescript", "a.scpt",
    ])
    func aScriptOrAProgramShowsInFinder(name: String) async throws {
        let (action, real) = try await fileAction(name)
        #expect(action == .showInFinder(real))
    }

    // Source code and the parts of a program open, also when macOS marks their type as a
    // program or as a shell script.
    @Test(arguments: [
        "a.js", "a.mjs", "a.tsx", "a.php", "Makefile", "a.mk", "a.o", "a.class", "a.dylib",
    ])
    func sourceCodeOpens(name: String) async throws {
        let (action, real) = try await fileAction(name)
        #expect(action == .openFile(real, app: nil))
    }

    // macOS does not mark these types as runnable, but their app installs the file or starts
    // what it points to. Keychain Access adds a certificate to a keychain.
    @Test(arguments: [
        "a.pkg", "a.mpkg", "a.webloc", "a.inetloc", "a.fileloc", "a.url", "a.terminal",
        "a.shortcut", "a.wflow", "a.mobileconfig", "a.configprofile", "a.provisionprofile",
        "a.jnlp", "a.safariextz", "a.cer", "a.crt", "a.der", "a.pem", "a.p12", "a.pfx",
    ])
    func aFileThatMacOSInstallsOrStartsFromShowsInFinder(name: String) async throws {
        let (action, real) = try await fileAction(name)
        #expect(action == .showInFinder(real))
    }

    // A plain file with the name of a bundle type. macOS gives it to the app of that bundle
    // type, for example a .workflow file to the installer of Automator.
    @Test(arguments: [
        "a.workflow", "a.action", "a.kext", "a.prefpane", "a.scptd", "a.saver", "a.plugin",
        "a.appex",
    ])
    func aFileWithTheNameOfABundleShowsInFinder(name: String) async throws {
        let (action, real) = try await fileAction(name)
        #expect(action == .showInFinder(real))
    }

    @Test(arguments: [
        "notes.txt", "README.md", "data.json", "page.html", "disk.dmg", "archive.zip",
        "notes.xyzzy", ".zshrc", "LICENSE", "Dockerfile",
    ])
    func aDocumentOpens(name: String) async throws {
        let (action, real) = try await fileAction(name)
        #expect(action == .openFile(real, app: nil))
    }

    // A bundle folder shows in Finder. A plain folder opens, also with the extension of a script.
    @Test(arguments: [
        "Tool.app", "Flow.workflow", "Setup.pkg", "Pane.prefpane", "Run.action", "Notes.rtfd",
        "Script.scptd",
    ])
    func aBundleShowsInFinder(name: String) async throws {
        let tree = try Tree()
        defer { tree.remove() }
        try tree.folder(name)
        try tree.folder("src")
        try tree.folder("tools.sh")
        #expect(await tree.action("/\(name)") == .showInFinder("\(tree.real)/\(name)"))
        #expect(await tree.action("/src") == .openFile("\(tree.real)/src", app: nil))
        #expect(await tree.action("/tools.sh") == .openFile("\(tree.real)/tools.sh", app: nil))
    }
}

// The app that opens a file that the type rules open. The file opens only in an app that the
// rules checked: the app of the file is the default app of its type, it has a bundle ID, and it
// is not a terminal or a launcher.
@Suite("link default apps", .timeLimit(.minutes(1)))
struct LinkDefaultAppTests {
    private let terminal = "com.apple.Terminal"
    private let editor = "dev.example.editor"
    private let xcode = "com.apple.dt.Xcode"

    private func fileAction(_ name: String, _ apps: FakeApps) async throws -> (LinkAction, String)
    {
        let tree = try Tree()
        defer { tree.remove() }
        try tree.file(name)
        return (await tree.action("/\(name)", apps: apps), "\(tree.real)/\(name)")
    }

    // The same source file shows in Finder when the terminal opens it. It opens in the editor
    // when the editor opens it, and with no app when no app can open it (then macOS asks).
    @Test(arguments: ["a.js", "a.mjs", "a.tsx", "a.dylib", "a.php"])
    func aSourceFileShowsInFinderOnlyWhenATerminalOpensIt(name: String) async throws {
        let (inTerminal, path) = try await fileAction(name, FakeApps(byName: [name: terminal]))
        #expect(inTerminal == .showInFinder(path))
        let (inEditor, editorPath) = try await fileAction(name, FakeApps(byName: [name: editor]))
        #expect(inEditor == .openFile(editorPath, app: fakeApp(editor).url))
        let (noApp, noAppPath) = try await fileAction(name, FakeApps())
        #expect(noApp == .openFile(noAppPath, app: nil))
    }

    // A launcher runs or installs the file that it opens, so the file shows in Finder: Java
    // Launcher a Java class, Wish a Tcl script, Keychain Access a certificate bundle, Automator
    // Installer a workflow.
    @Test(arguments: [
        ("Main.class", "com.apple.JavaLauncher"), ("a.tcl", "com.tcltk.wish"),
        ("a.p7b", "com.apple.keychainaccess"), ("notes.txt", "com.apple.AutomatorInstaller"),
    ])
    func aFileThatALauncherOpensShowsInFinder(name: String, launcher: String) async throws {
        let (action, real) = try await fileAction(name, FakeApps(byName: [name: launcher]))
        #expect(action == .showInFinder(real))
    }

    // A per-file Open With binding: the app of the file is not the default app of its type. The
    // file shows in Finder, whatever the app. With no binding, the file opens in the app.
    @Test(arguments: ["notes.md", "notes.txt", "main.swift", "data.json"])
    func aFileWithAnOpenWithBindingShowsInFinder(name: String) async throws {
        for bound in ["com.tcltk.wish", "dev.example.tool", editor] {
            let apps = FakeApps(byName: [name: bound], typeByName: [name: xcode])
            let (action, real) = try await fileAction(name, apps)
            #expect(action == .showInFinder(real), "\(bound)")
        }
        let (action, real) = try await fileAction(name, FakeApps(byName: [name: xcode]))
        #expect(action == .openFile(real, app: fakeApp(xcode).url))
    }

    // With no terminal, Launch Services did not answer, so the rules cannot check the app.
    @Test func aLookupWithNoTerminalShowsTheFileInFinder() async throws {
        for apps in [
            FakeApps(byName: ["notes.txt": editor], terminals: []), FakeApps(terminals: []),
        ] {
            let (action, real) = try await fileAction("notes.txt", apps)
            #expect(action == .showInFinder(real))
        }
    }

    // The type rules stay: a script shows in Finder also when an editor is its default app.
    @Test func aScriptShowsInFinderAlsoWithAnEditor() async throws {
        let (action, real) = try await fileAction("a.sh", FakeApps(byName: ["a.sh": editor]))
        #expect(action == .showInFinder(real))
    }

    // The app is the app of the real path: here of the target of a symbolic link.
    @Test func theAppIsTheAppOfTheRealPath() async throws {
        let tree = try Tree.usual()
        defer { tree.remove() }
        let apps = FakeApps(byName: ["notes.txt": terminal])
        #expect(await tree.action("/doc", apps: apps) == .showInFinder("\(tree.real)/notes.txt"))
        let inEditor = FakeApps(byName: ["notes.txt": editor])
        #expect(
            await tree.action("/doc", apps: inEditor)
                == .openFile("\(tree.real)/notes.txt", app: fakeApp(editor).url))
    }
}

// Launch Services has a time limit of 5 seconds. The clock is a manual clock, and the fake lookup
// waits for a gate.
@Suite("link time limit", .timeLimit(.minutes(1)))
struct LinkTimeLimitTests {
    // With no answer in the time limit, the file shows in Finder. The rules do not use the late
    // answer.
    @Test func aLookupWithNoAnswerInTheTimeLimitShowsTheFileInFinder() async throws {
        let tree = try Tree()
        defer { tree.remove() }
        try tree.file("notes.txt")
        let gate = TestGate()
        defer { gate.openAll() }
        let clock = ManualClock()
        async let action = LinkRules.action(
            forLink: "file://\(tree.temp.path)/notes.txt", localHost: host,
            lookup: OpenerLookup(apps: WaitingApps(gate: gate)), clock: clock)
        await clock.waitForSleepers(1)
        #expect(clock.nextDeadline == ManualClock.Instant(offset: .seconds(5)))
        clock.advance(by: .seconds(5))
        #expect(await action == .showInFinder("\(tree.real)/notes.txt"))
    }

    // An answer in the time limit decides the action.
    @Test func anAnswerInTheTimeLimitDecides() async throws {
        let tree = try Tree()
        defer { tree.remove() }
        try tree.file("notes.txt")
        let gate = TestGate()
        defer { gate.openAll() }
        let clock = ManualClock()
        async let action = LinkRules.action(
            forLink: "file://\(tree.temp.path)/notes.txt", localHost: host,
            lookup: OpenerLookup(apps: WaitingApps(gate: gate)), clock: clock)
        await clock.waitForSleepers(1)
        gate.open()
        #expect(
            await action
                == .openFile(
                    "\(tree.real)/notes.txt", app: fakeApp("dev.example.editor").url))
        #expect(clock.sleeperCount == 0)
    }

    // A second link waits for the running lookup, then makes its own lookup. Two lookups never
    // run at the same time.
    @Test func aNewLinkWaitsForTheRunningLookup() async throws {
        let tree = try Tree()
        defer { tree.remove() }
        try tree.file("a.txt")
        try tree.file("b.txt")
        let gate = TestGate()
        defer { gate.openAll() }
        let apps = CountingApps(gate: gate)
        let lookup = OpenerLookup(apps: apps)
        let clock = ManualClock()
        async let first = LinkRules.action(
            forLink: "file://\(tree.temp.path)/a.txt", localHost: host, lookup: lookup,
            clock: clock)
        await waitUntil { apps.names == ["a.txt"] }
        async let second = LinkRules.action(
            forLink: "file://\(tree.temp.path)/b.txt", localHost: host, lookup: lookup,
            clock: clock)
        await clock.waitForSleepers(2)
        gate.open()
        gate.open()
        let editor = fakeApp("dev.example.editor").url
        #expect(await first == .openFile("\(tree.real)/a.txt", app: editor))
        #expect(await second == .openFile("\(tree.real)/b.txt", app: editor))
        #expect(apps.names == ["a.txt", "b.txt"])
        #expect(apps.most == 1)
    }

    // A link that waits for a lookup with no answer gets the result of its time limit, and makes
    // no lookup after the late answer.
    @Test func aLinkThatWaitsPastItsTimeLimitMakesNoLookup() async throws {
        let tree = try Tree()
        defer { tree.remove() }
        for name in ["a.txt", "b.txt", "c.txt"] { try tree.file(name) }
        let gate = TestGate()
        defer { gate.openAll() }
        let apps = CountingApps(gate: gate)
        let lookup = OpenerLookup(apps: apps)
        let clock = ManualClock()
        async let first = LinkRules.action(
            forLink: "file://\(tree.temp.path)/a.txt", localHost: host, lookup: lookup,
            clock: clock)
        await waitUntil { apps.names == ["a.txt"] }
        async let second = LinkRules.action(
            forLink: "file://\(tree.temp.path)/b.txt", localHost: host, lookup: lookup,
            clock: clock)
        await clock.waitForSleepers(2)
        clock.advance(by: LinkRules.openerTimeLimit)
        #expect(await first == .showInFinder("\(tree.real)/a.txt"))
        #expect(await second == .showInFinder("\(tree.real)/b.txt"))
        // The late answer comes. The next link waits for the end of the chain, then asks.
        gate.open()
        async let third = LinkRules.action(
            forLink: "file://\(tree.temp.path)/c.txt", localHost: host, lookup: lookup,
            clock: clock)
        await waitUntil { apps.names.count == 2 }
        gate.open()
        let editor = fakeApp("dev.example.editor").url
        #expect(await third == .openFile("\(tree.real)/c.txt", app: editor))
        #expect(apps.names == ["a.txt", "c.txt"])
    }
}
