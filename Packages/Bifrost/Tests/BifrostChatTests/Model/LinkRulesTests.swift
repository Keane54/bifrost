// The link rules: the target of a link and the action for a target. The tests of the action give
// fake facts, so they read no file and open nothing. The tests of the facts of real files are in
// LinkFileFactsTests.swift.
import BifrostChat
import Foundation
import Testing
import UniformTypeIdentifiers

private let host = "devbox.local"

private func url(_ text: String) throws -> URL {
    try #require(URL(string: text))
}

@Suite("link target")
struct LinkTargetTests {
    @Test("http and https links open as web targets")
    func webLinks() throws {
        #expect(
            LinkRules.target("https://github.com/a/b/pull/1", localHost: host)
                == .web(try url("https://github.com/a/b/pull/1")))
        #expect(
            LinkRules.target("http://localhost:5173/", localHost: host)
                == .web(try url("http://localhost:5173/")))
    }

    @Test("a file link with no host, localhost or the own host is a file target")
    func fileLinks() {
        #expect(
            LinkRules.target("file:///Users/dev-user/repo/src/a.ts", localHost: host)
                == .file("/Users/dev-user/repo/src/a.ts"))
        for link in ["file://localhost/tmp/a.txt", "file://DEVBOX.local/tmp/a.txt"] {
            #expect(LinkRules.target(link, localHost: host) == .file("/tmp/a.txt"))
        }
    }

    @Test
    func decodesThePath() {
        #expect(
            LinkRules.target("file:///tmp/my%20notes.md#L12", localHost: host)
                == .file("/tmp/my notes.md"))
    }

    @Test("a file link of another host is refused")
    func anotherHost() {
        #expect(LinkRules.target("file://other-mac/tmp/a.txt", localHost: host) == nil)
    }

    @Test("other protocols, bad URLs and very long links are refused")
    func refusedLinks() {
        for link in [
            "javascript:alert(1)", "mailto:a@b.c", "vscode://file/tmp/a.ts", "ftp://example.com/a",
            "not a url", "",
            "https://example.com/\(String(repeating: "a", count: LinkRules.maxLength))",
        ] {
            #expect(LinkRules.target(link, localHost: host) == nil)
        }
    }

    // A bad percent sequence in the path, or bytes that are not UTF-8, give no target. A space
    // and a character that is not ASCII get percent-encoded, and a good sequence next to them
    // stays. A space at the ends and a line break go away.
    @Test func aLinkIsReadAsABrowserReadsIt() throws {
        for bad in ["file:///tmp/a%zz", "file:///tmp/a%E0%A4%A", "file:///tmp/%FF"] {
            #expect(LinkRules.target(bad, localHost: host) == nil)
        }
        #expect(LinkRules.target("file:///tmp/a%20b c", localHost: host) == .file("/tmp/a b c"))
        #expect(LinkRules.target("file:///tmp/%C3%BCber", localHost: host) == .file("/tmp/über"))
        #expect(LinkRules.target("file:///tmp/über", localHost: host) == .file("/tmp/über"))
        #expect(LinkRules.target("file:///tmp/a%2Fb", localHost: host) == .file("/tmp/a/b"))
        #expect(LinkRules.target("file:///tmp/a?x=%zz", localHost: host) == .file("/tmp/a"))
        #expect(LinkRules.target(" file:///tmp/a.txt\n", localHost: host) == .file("/tmp/a.txt"))
        #expect(LinkRules.target("file:///tmp/a\r\n.txt", localHost: host) == .file("/tmp/a.txt"))
        #expect(
            LinkRules.target("https://example.com/über?q=a b#x y", localHost: host)
                == .web(try url("https://example.com/%C3%BCber?q=a%20b#x%20y")))
        #expect(
            LinkRules.target("https://example.com/a%20b ü", localHost: host)
                == .web(try url("https://example.com/a%20b%20%C3%BC")))
    }
}

// The marks of a fake file. A mode with an execute bit is executable.
private struct Item {
    var folder = false
    var mode = 0o644
    var package = false
    var alias = false
}

// The type that macOS gives to an item with this name: the same type as the contentType
// resource value of a real item.
private func systemType(of path: String, folder: Bool) -> UTType {
    let name = URL(filePath: path, directoryHint: .notDirectory)
    return UTType(filenameExtension: name.pathExtension, conformingTo: folder ? .directory : .data)
        ?? (folder ? .folder : .data)
}

// The fake facts: the real path is the path, and the type comes from the name.
private func facts(_ path: String, _ item: Item) -> FileFacts {
    FileFacts(
        realPath: path, contentType: systemType(of: path, folder: item.folder),
        isFolder: item.folder, executable: item.mode & 0o111 != 0, isPackage: item.package,
        isAlias: item.alias)
}

// A fake app at /Applications/<bundle ID>.app.
private func app(_ id: String) -> AppFacts {
    AppFacts(
        url: URL(filePath: "/Applications/\(id).app", directoryHint: .isDirectory), bundleID: id)
}

private let terminal = "com.apple.Terminal"
private let editor = app("dev.example.editor")

// The facts of Launch Services for a file whose app is the default app of its type. Terminal is
// a terminal, so Launch Services answers.
private func opener(_ app: AppFacts?, terminals: Set<String> = [terminal]) -> OpenerFacts {
    OpenerFacts(app: app, typeApp: app?.url, terminalIDs: terminals)
}

// The action that opens the file in the fake editor, the app that the rules checked.
private func inEditor(_ path: String) -> LinkAction { .openFile(path, app: editor.url) }

// The two steps of the rules: the check, then the app that opens the file.
private func run(_ check: LinkCheck, _ facts: OpenerFacts?) -> LinkAction {
    switch check {
    case .done(let action): return action
    case .askOpener(let file): return LinkRules.action(for: file, opener: facts)
    }
}

// The action of a link. The fake editor opens each file.
private func action(_ link: String, _ items: [String: Item] = [:]) -> LinkAction {
    let check = LinkRules.check(
        LinkRules.target(link, localHost: host),
        facts: { path in items[path].map { facts(path, $0) } })
    return run(check, opener(editor))
}

// The action for a file of this name in the folder /r. The fake editor opens it, unless the
// facts of Launch Services are other facts.
private func fileAction(
    _ name: String, _ item: Item = Item(), opener lookup: OpenerFacts? = opener(editor)
) -> LinkAction {
    run(LinkRules.check(.file("/r/\(name)"), facts: { facts($0, item) }), lookup)
}

@Suite("opening a link")
struct OpenLinkTests {
    @Test("a web link opens in the default browser")
    func aWebLink() throws {
        #expect(action("https://example.com/a") == .openWeb(try url("https://example.com/a")))
    }

    @Test func aMissingFileOrARefusedLinkDoesNothing() {
        #expect(action("file:///r/missing.ts") == .nothing)
        #expect(action("javascript:alert(1)") == .nothing)
    }

    // A plain folder opens, also with the extension of a script.
    @Test func aFileAndAFolderOpen() {
        let folder = Item(folder: true, mode: 0o755)
        let items = ["/r/a.ts": Item(), "/r/src": folder, "/r/tools.sh": folder]
        #expect(action("file:///r/a.ts", items) == inEditor("/r/a.ts"))
        #expect(action("file:///r/src", items) == inEditor("/r/src"))
        #expect(action("file:///r/tools.sh", items) == inEditor("/r/tools.sh"))
    }

    // A document opens in its default app, also a type that macOS does not know.
    @Test(arguments: [
        "notes.txt", "README.md", "main.swift", "a.c", "data.json", "page.html", "report.pdf",
        "photo.png", "archive.zip", "disk.dmg", "notes.xyzzy", ".zshrc", "LICENSE",
    ])
    func aDocumentOpens(name: String) {
        #expect(fileAction(name) == inEditor("/r/\(name)"))
    }

    // A program, a script that a shell or Script Editor runs, or a file that macOS installs or
    // starts from shows in Finder, from its type only: these files have no execute bit and no
    // package mark. Keychain Access adds a certificate to a keychain, so a certificate is an
    // install too.
    @Test(arguments: [
        "Tool.app", "a.exe", "a.jar", "a.pyc", "x.sh", "Run.SH", "go.command", "y.py", "a.pl",
        "a.rb", "a.scpt", "Setup.pkg", "site.webloc", "Pro.terminal", "Do.shortcut",
        "Flow.workflow", "a.cer", "a.crt", "a.der", "a.pem", "a.p12", "a.pfx",
    ])
    func aRunnableTypeShowsInFinder(name: String) {
        #expect(fileAction(name) == .showInFinder("/r/\(name)"))
    }

    // Source code and the parts of a program open, also when macOS marks their type as a
    // program (JavaScript, object code, a Java class, a dynamic library) or as a shell script
    // (PHP).
    @Test(arguments: [
        "app.js", "a.mjs", "page.tsx", "index.php", "rules.mk", "main.o", "Main.class",
        "lib.dylib",
    ])
    func sourceCodeOpens(name: String) {
        #expect(fileAction(name) == inEditor("/r/\(name)"))
    }

    // The execute bits, the package mark and the alias mark show a file in Finder, whatever its
    // type. A folder needs its execute bits to open, so they do not count for a folder.
    @Test func theMarksOfAFileShowItInFinder() {
        #expect(fileAction("run", Item(mode: 0o755)) == .showInFinder("/r/run"))
        #expect(fileAction("notes.txt", Item(mode: 0o001)) == .showInFinder("/r/notes.txt"))
        #expect(fileAction("app.js", Item(mode: 0o755)) == .showInFinder("/r/app.js"))
        let package = Item(folder: true, mode: 0o755, package: true)
        #expect(fileAction("Notes.rtfd", package) == .showInFinder("/r/Notes.rtfd"))
        #expect(fileAction("Plain", package) == .showInFinder("/r/Plain"))
        #expect(fileAction("tool", Item(alias: true)) == .showInFinder("/r/tool"))
        #expect(fileAction("src", Item(folder: true, mode: 0o755)) == inEditor("/r/src"))
    }

    // A folder of a bundle type and an alias type show in Finder also with no mark.
    @Test func aBundleFolderAndAnAliasTypeShowInFinder() {
        let folder = Item(folder: true, mode: 0o755)
        #expect(fileAction("Tool.app", folder) == .showInFinder("/r/Tool.app"))
        #expect(fileAction("Flow.workflow", folder) == .showInFinder("/r/Flow.workflow"))
        let alias = LinkRules.check(.file("/r/tool")) {
            FileFacts(realPath: $0, contentType: .aliasFile)
        }
        #expect(alias == .done(.showInFinder("/r/tool")))
    }

    // A path with a NUL does nothing, and the rule asks for no facts of it. The system reads a
    // path only up to the NUL, so the file would not be the file of the link.
    @Test func aPathWithANulDoesNothing() {
        var asked: [String] = []
        let target = LinkRules.target("file:///A/Tool.app%00", localHost: host)
        #expect(target == .file("/A/Tool.app\u{0}"))
        let check = LinkRules.check(target) { path in
            asked.append(path)
            return FileFacts(realPath: "/A/Tool.app", contentType: .plainText)
        }
        #expect(check == .done(.nothing))
        #expect(asked.isEmpty)
    }

    // Only a file that the type rules open needs the app that opens it, because that answer
    // comes from Launch Services. A web link, a runnable type and a missing file need no app.
    @Test func onlyAFileThatTheTypeRulesOpenNeedsItsApp() throws {
        let notes = FileFacts(realPath: "/r/notes.txt", contentType: .plainText)
        #expect(LinkRules.check(.file("/r/notes.txt")) { _ in notes } == .askOpener(notes))
        #expect(
            LinkRules.check(.file("/r/x.sh")) { facts($0, Item()) }
                == .done(.showInFinder("/r/x.sh")))
        #expect(LinkRules.check(.file("/r/gone")) { _ in nil } == .done(.nothing))
        let web = try url("https://example.com/a")
        #expect(LinkRules.check(.web(web)) { _ in notes } == .done(.openWeb(web)))
        #expect(LinkRules.check(nil) { _ in notes } == .done(.nothing))
    }

    // A file that the type rules open shows in Finder when the app that opens it runs it: a
    // terminal or a launcher. The same file opens in the checked app when that app is an editor.
    @Test func aFileWhoseAppRunsItShowsInFinder() {
        #expect(fileAction("app.js", opener: opener(app(terminal))) == .showInFinder("/r/app.js"))
        let java = opener(app("com.apple.JavaLauncher"))
        #expect(fileAction("Main.class", opener: java) == .showInFinder("/r/Main.class"))
        let notes = fileAction("notes.txt", opener: opener(app(terminal)))
        #expect(notes == .showInFinder("/r/notes.txt"))
        #expect(fileAction("app.js") == inEditor("/r/app.js"))
    }

    // A per-file Open With binding (the extended attribute com.apple.LaunchServices.OpenWith)
    // can name each app on the disk for one file. When the app of the file is not the default
    // app of its type, the file shows in Finder, also when that app is not a terminal or a
    // launcher.
    @Test func aFileWhoseAppIsNotTheAppOfItsTypeShowsInFinder() {
        let xcode = app("com.apple.dt.Xcode")
        let wish = AppFacts(
            url: URL(filePath: "/System/Library/Frameworks/Tk.framework/Wish.app/"),
            bundleID: "com.tcltk.wish")
        let terminals: Set = [terminal]
        for item in [wish, app("dev.example.tool"), editor] {
            let bound = OpenerFacts(app: item, typeApp: xcode.url, terminalIDs: terminals)
            #expect(fileAction("notes.md", opener: bound) == .showInFinder("/r/notes.md"))
        }
        // A copy of the editor in another folder, with the same bundle ID.
        let copy = AppFacts(
            url: URL(filePath: "/tmp/x/dev.example.editor.app/"), bundleID: editor.bundleID)
        let copied = OpenerFacts(app: copy, typeApp: editor.url, terminalIDs: terminals)
        #expect(fileAction("notes.md", opener: copied) == .showInFinder("/r/notes.md"))
        // An app for the file and none for its type, or the reverse.
        let fileOnly = OpenerFacts(app: editor, typeApp: nil, terminalIDs: terminals)
        #expect(fileAction("notes.xyzzy", opener: fileOnly) == .showInFinder("/r/notes.xyzzy"))
        let typeOnly = OpenerFacts(app: nil, typeApp: editor.url, terminalIDs: terminals)
        #expect(fileAction("notes.md", opener: typeOnly) == .showInFinder("/r/notes.md"))
        // The same app for the file and for its type opens the file in that app.
        let same = OpenerFacts(app: xcode, typeApp: xcode.url, terminalIDs: terminals)
        #expect(fileAction("notes.md", opener: same) == .openFile("/r/notes.md", app: xcode.url))
    }

    // A lookup that cannot name the app shows the file in Finder: no answer in the time limit,
    // no terminal (Terminal is always there, so Launch Services did not answer), and an app with
    // no bundle ID. Only a file with no app at all opens, with no app: macOS asks for an app.
    @Test func aLookupThatCannotNameTheAppShowsTheFileInFinder() {
        #expect(fileAction("notes.txt", opener: nil) == .showInFinder("/r/notes.txt"))
        #expect(
            fileAction("notes.txt", opener: opener(editor, terminals: []))
                == .showInFinder("/r/notes.txt"))
        #expect(
            fileAction("notes.xyzzy", opener: opener(nil, terminals: []))
                == .showInFinder("/r/notes.xyzzy"))
        let noID = AppFacts(url: URL(filePath: "/Applications/Plain.app/"), bundleID: nil)
        #expect(fileAction("notes.txt", opener: opener(noID)) == .showInFinder("/r/notes.txt"))
        let noApp = fileAction("notes.xyzzy", opener: opener(nil))
        #expect(noApp == .openFile("/r/notes.xyzzy", app: nil))
    }

    // An app runs a file that it opens when it is a terminal of this Mac or a launcher. Archive
    // Utility, an editor and Finder only open the file.
    @Test func aTerminalOrALauncherRunsAFile() {
        let terminals: Set = ["com.apple.Terminal", "dev.example.terminal"]
        for app in [
            "com.apple.Terminal", "dev.example.terminal", "com.apple.JavaLauncher",
            "org.python.PythonLauncher", "com.tcltk.wish", "com.apple.installer",
            "com.apple.AutomatorInstaller", "com.apple.systempreferences",
            "com.apple.mcx.ProfileHelper", "com.apple.keychainaccess",
        ] {
            #expect(LinkRules.runs(appID: app, terminalIDs: terminals), "\(app)")
        }
        for app in [
            "com.apple.archiveutility", "com.apple.dt.Xcode", "com.apple.TextEdit",
            "com.apple.finder",
        ] {
            #expect(!LinkRules.runs(appID: app, terminalIDs: terminals), "\(app)")
        }
        #expect(!LinkRules.runs(appID: "dev.example.terminal", terminalIDs: []))
    }
}
