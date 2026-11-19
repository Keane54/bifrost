import Foundation
import UniformTypeIdentifiers

// The links of a chat window (docs/behaviour/chat.md, "Links"). Claude Code prints its links as
// terminal hyperlinks (OSC 8). A Cmd+click on a link opens it outside the app, with no dialog (user
// decisions, 2026-11-10 and 2026-11-14):
// - An http or https link opens in the default browser.
// - A file link of this Mac opens the file or the folder in its default app.
// - A file that runs or installs something when macOS opens it does not open. Finder shows it
//   instead, so a click on a link never starts a program. Source code opens, also when macOS marks
//   its type as a program or a script, but not when the app that opens it runs it (a terminal or a
//   launcher).
// - A file opens only in the app that the rules checked. When the rules cannot check the app,
//   Finder shows the file.
// All other links do nothing.
//
// The action comes from the real path of the file (realpath(3)): with no ".", no "..", no trailing
// slash and no symbolic link. A path with a NUL does nothing.

// The target of a link.
package enum LinkTarget: Sendable, Equatable {
    case web(URL)
    case file(String)
}

// What the app does for a link.
package enum LinkAction: Sendable, Equatable {
    case openWeb(URL)
    // Open the file at the real path in the app that the rules checked. With no app, no app can
    // open the file, and macOS asks the user for an app.
    case openFile(String, app: URL?)
    case showInFinder(String)
    case nothing
}

// The result of the first step of the rules for a link (LinkRules.check).
package enum LinkCheck: Sendable, Equatable {
    // The action of the link. The rules need no more facts.
    case done(LinkAction)
    // A file that the type rules open. The app that opens it decides the action
    // (LinkRules.action(for:opener:)), so the caller asks Launch Services for that app.
    case askOpener(FileFacts)
}

// An app of Launch Services: the URL of the app bundle and its bundle ID (nil when the bundle has
// no bundle ID).
package struct AppFacts: Sendable, Equatable {
    package var url: URL
    package var bundleID: String?

    package init(url: URL, bundleID: String?) {
        self.url = url
        self.bundleID = bundleID
    }
}

// The facts of Launch Services about the app that opens a file. The services of the chat read
// them (DefaultApps).
package struct OpenerFacts: Sendable, Equatable {
    // The app that opens the file itself. A per-file Open With binding (the extended attribute
    // com.apple.LaunchServices.OpenWith) can name each app on the disk for one file.
    package var app: AppFacts?
    // The default app of the type of the file.
    package var typeApp: URL?
    // The bundle IDs of the terminals of this Mac: the apps that declare public.unix-executable.
    // Terminal is always one of them, so an empty set tells that Launch Services did not answer.
    package var terminalIDs: Set<String>

    package init(app: AppFacts?, typeApp: URL?, terminalIDs: Set<String>) {
        self.app = app
        self.typeApp = typeApp
        self.terminalIDs = terminalIDs
    }
}

// The facts of a file for the action of a link. The services of the chat read them from the
// file system (FileFacts(atPath:)).
package struct FileFacts: Sendable, Equatable {
    // The path with no ".", no "..", no trailing slash and no symbolic link.
    package var realPath: String
    // The type of the item (the contentType resource value). macOS gets the type from the
    // name, the folder mark and the execute bits, and opens the item with an app of the type.
    package var contentType: UTType
    package var isFolder: Bool
    // True when the mode has an execute bit.
    package var executable: Bool
    // True for a package that Finder shows as one item, for example an app or a bundle.
    package var isPackage: Bool
    // True for a Finder alias file.
    package var isAlias: Bool

    package init(
        realPath: String, contentType: UTType, isFolder: Bool = false, executable: Bool = false,
        isPackage: Bool = false, isAlias: Bool = false
    ) {
        self.realPath = realPath
        self.contentType = contentType
        self.isFolder = isFolder
        self.executable = executable
        self.isPackage = isPackage
        self.isAlias = isAlias
    }
}

package enum LinkRules {
    // The longest link that Bifrost opens, in Characters. A longer text is not a real link.
    package static let maxLength = 4096

    // The time that Launch Services has to give the app of a file. With no answer in this time,
    // Finder shows the file.
    package static let openerTimeLimit: Duration = .seconds(5)

    // The types that run or install something when macOS opens them, with their subtypes:
    // - A program: an app, a Unix or a Windows program, a Java archive, an iOS app (.ipa) and
    //   Python bytecode (.pyc).
    // - A script that a shell, Terminal or Script Editor runs: a shell script (also .command
    //   and .tool), Python, Perl, Ruby, and AppleScript as text or as a compiled script.
    //   macOS also marks Python, Perl and Ruby as shell scripts.
    // - A package or a bundle that Finder shows as one item (also an AppleScript bundle), and
    //   an alias file.
    // - A file that its app installs: an installer package, a profile, a certificate (Keychain
    //   Access adds it to a keychain), a Safari extension and a shortcut.
    // - A file that starts what it points to: a .webloc, .inetloc, .fileloc or .url file, a
    //   Terminal settings file (its command) and a Java Web Start file.
    static let runTypes: [UTType] =
        [
            .executable, .shellScript, .pythonScript, .perlScript, .rubyScript, .appleScript,
            .osaScript, .package, .aliasFile, .x509Certificate, .pkcs12,
        ]
        + [
            "com.apple.installer-package-archive", "com.apple.mobileconfig",
            "com.apple.configprofile", "com.apple.provisionprofile", "com.apple.safari.extension",
            "com.apple.shortcut", "com.apple.shortcuts.workflow-file", "public.stored-url",
            "com.apple.terminal.settings", "com.sun.java-web-start",
        ].compactMap { UTType($0) }

    // Source code and the parts of a program. macOS marks JavaScript, object code, a Java class
    // and a dynamic library as programs, and PHP as a shell script. A developer opens these
    // files to read them, so a link to one of them opens it.
    static let codeTypes: [UTType] =
        [.javaScript, .phpScript]
        + ["public.object-code", "com.sun.java-class", "com.apple.mach-o-dylib"].compactMap {
            UTType($0)
        }

    // The apps that start a program from the file that they open, or install it, by bundle ID:
    // Java Launcher, Python Launcher, Wish (a Tcl/Tk script), Installer, Automator Installer,
    // System Settings and Profile Helper (a profile), and Keychain Access (a certificate or a
    // keychain). Archive Utility only unpacks a file, so it is not in the list.
    static let launcherIDs: Set<String> = [
        "com.apple.JavaLauncher", "org.python.PythonLauncher", "com.tcltk.wish",
        "com.apple.installer", "com.apple.AutomatorInstaller", "com.apple.systempreferences",
        "com.apple.mcx.ProfileHelper", "com.apple.keychainaccess",
    ]

    // True when the app with this bundle ID runs a file that it opens: a terminal of this Mac
    // (terminalIDs, the apps that open a Unix program) or a launcher.
    package static func runs(appID: String, terminalIDs: Set<String>) -> Bool {
        launcherIDs.contains(appID) || terminalIDs.contains(appID)
    }

    // The target of a link, or nil when Bifrost must not open it. A file link must have no host,
    // "localhost" or the host name of this Mac. The path of a file link is percent-decoded and
    // starts with "/". The query and the fragment of a file link have no effect.
    package static func target(_ link: String, localHost: String) -> LinkTarget? {
        guard !link.isEmpty, link.count <= maxLength else { return nil }
        // URL(string:) also encodes the percent signs of good sequences again, so only a web
        // link that the strict parse refuses (for example one with a lone "%") uses it.
        let text = cleaned(link)
        let strict = strictURL(text)
        guard let url = strict ?? URL(string: text), let scheme = url.scheme?.lowercased() else {
            return nil
        }
        if scheme == "http" || scheme == "https" {
            guard let host = url.host(), !host.isEmpty else { return nil }
            return .web(url)
        }
        // Only the path of a file link counts. A lone "%" in the path gives nil.
        let pathOnly = String(text.prefix { $0 != "?" && $0 != "#" })
        guard scheme == "file", let url = strict ?? strictURL(pathOnly) else { return nil }
        let host = (url.host() ?? "").lowercased()
        guard host.isEmpty || host == "localhost" || host == localHost.lowercased() else {
            return nil
        }
        // A bad percent sequence or bytes that are not UTF-8 give nil.
        guard let path = url.path(percentEncoded: true).removingPercentEncoding,
            path.hasPrefix("/")
        else { return nil }
        return .file(path)
    }

    // The first step of the action for the target of a link. facts gives the facts of the real
    // path of a file, or nil when the path has no real path (for example a missing file): then
    // the link does nothing. A file that the type rules open needs the app that opens it
    // (askOpener), because that answer comes from Launch Services. The action holds the real
    // path.
    package static func check(_ target: LinkTarget?, facts: (String) -> FileFacts?) -> LinkCheck {
        switch target {
        case nil:
            return .done(.nothing)
        case .web(let url):
            return .done(.openWeb(url))
        case .file(let path):
            // The system reads a path only up to a NUL, so the file would not be the file of the
            // link.
            guard !path.contains("\0"), let file = facts(path) else { return .done(.nothing) }
            return canRun(file) ? .done(.showInFinder(file.realPath)) : .askOpener(file)
        }
    }

    // The action for a file that the type rules open, from the app that opens it. opener is nil
    // when Launch Services gave no answer in the time limit. The file opens only in the app that
    // the rules checked, or with no app when no app can open it (then macOS asks the user for an
    // app). In each other case Finder shows the file:
    // - Launch Services gave no answer, or no terminal (then it did not answer).
    // - The app of the file is not the default app of its type, for example because of a
    //   per-file Open With binding. Or only one of the two has an app.
    // - The app has no bundle ID.
    // - The app runs the file (runs(appID:terminalIDs:)).
    package static func action(for file: FileFacts, opener: OpenerFacts?) -> LinkAction {
        let finder = LinkAction.showInFinder(file.realPath)
        guard let opener, !opener.terminalIDs.isEmpty else { return finder }
        switch (opener.app, opener.typeApp) {
        case (nil, nil):
            return .openFile(file.realPath, app: nil)
        case (let app?, let typeApp?) where sameApp(app.url, typeApp):
            guard let id = app.bundleID, !runs(appID: id, terminalIDs: opener.terminalIDs) else {
                return finder
            }
            return .openFile(file.realPath, app: app.url)
        default:
            return finder
        }
    }

    // True when the two URLs name the same app bundle, with no "." or ".." in the paths.
    private static func sameApp(_ a: URL, _ b: URL) -> Bool {
        a.standardizedFileURL == b.standardizedFileURL
    }

    // True when the file runs or installs something when macOS opens it. A folder needs its
    // execute bits to open, so they do not count for a folder. The execute bit counts also for
    // source code.
    static func canRun(_ file: FileFacts) -> Bool {
        if file.isPackage || file.isAlias || (file.executable && !file.isFolder) { return true }
        let type = file.contentType
        if codeTypes.contains(where: type.conforms(to:)) { return false }
        if runTypes.contains(where: type.conforms(to:)) { return true }
        // A plain file with the extension of a package type gets a dynamic type, but macOS
        // gives it to the app of the package type, for example a plain file Flow.workflow to
        // the installer of Automator.
        let name = URL(filePath: file.realPath, directoryHint: .notDirectory)
        let package = UTType(filenameExtension: name.pathExtension, conformingTo: .package)
        return package?.isDeclared == true
    }

    // The link as a browser reads it: with no tab and no line break, and with no control
    // character or space at the start or at the end.
    private static func cleaned(_ link: String) -> String {
        var scalars = link.unicodeScalars
        scalars.removeAll { lineBreaks.contains($0) }
        return String(scalars).trimmingCharacters(in: edges)
    }

    private static let lineBreaks = CharacterSet(charactersIn: "\t\n\r")
    // The C0 control characters and the space.
    private static let edges = CharacterSet(charactersIn: "\u{0}"..."\u{20}")

    // The ASCII characters that a URL can hold as they are (RFC 3986), and "%".
    private static let urlCharacters = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789"
            + "-._~:/?#[]@!$&'()*+,;=%")

    // The URL of the text, with each other character percent-encoded as UTF-8, as a browser
    // does it. A percent sign stays as it is, so a bad percent sequence gives nil.
    private static func strictURL(_ text: String) -> URL? {
        text.addingPercentEncoding(withAllowedCharacters: urlCharacters).flatMap {
            URL(string: $0, encodingInvalidCharacters: false)
        }
    }
}
