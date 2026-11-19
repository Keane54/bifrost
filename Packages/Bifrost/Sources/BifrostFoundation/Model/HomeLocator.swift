import Foundation
import System

/// How the check of a test home compares two paths. A test can give its own values. BifrostApp
/// gives the check of the app, PathCheck.system.
public struct PathCheck: Sendable {
    /// True when the compare ignores the case of the letters. The file systems of macOS ignore
    /// it.
    package var ignoresCase: Bool
    /// The real path of a path that exists, with each symbolic link resolved. nil for a path
    /// that does not exist.
    package var realPath: @Sendable (String) -> String?

    package init(ignoresCase: Bool, realPath: @escaping @Sendable (String) -> String?) {
        self.ignoresCase = ignoresCase
        self.realPath = realPath
    }
}

/// The home folder that the app uses, or the value of a test home that the app refuses.
public enum HomeChoice: Sendable, Equatable {
    /// The home folder. isTest is true for a test home.
    case home(URL, isTest: Bool)
    /// The value of the test home variable. The app must not start (refusedTestHome).
    case refused(String)
}

/// Finds the home folder that the app uses for its data.
public enum HomeLocator {
    /// Tests set this variable to move the development app to a safe folder.
    public static let testHomeKey = "BIFROST_TEST_HOME"

    /// The home of the app. The release app always uses the real home folder, and it ignores
    /// the test home variable. The development app uses the real home folder when the variable
    /// is not set, and the test home when testHome accepts the value. A value that testHome
    /// refuses gives refused: the app must not start, so it never uses the real home by mistake.
    /// realHome is the home folder of the user in the user database, from the launch code.
    public static func choose(
        variant: AppVariant, environment: [String: String], realHome: URL, check: PathCheck
    ) -> HomeChoice {
        guard variant == .development, let value = environment[testHomeKey] else {
            return .home(realHome, isTest: false)
        }
        let real = realHome.path(percentEncoded: false)
        guard let home = testHome(environment: environment, realHome: real, check: check) else {
            return .refused(value)
        }
        return .home(URL(fileURLWithPath: home, isDirectory: true), isTest: true)
    }

    /// The folders of the real home that hold the shared state of Claude Code and the data of
    /// Bifrost: the same folders that the test sandbox refuses (scripts/test-sandbox.sb).
    static let sharedFolders = [
        ".claude", ".claude.json", ".bifrost", ".bifrost-native-dev",
        "Library/Application Support/Bifrost", "Library/Application Support/Bifrost Native Dev",
    ]

    /// The test home: the value of testHomeKey, normalised and with no separator at the end. No
    /// value gives nil. The value must be an absolute path.
    /// The check refuses "/", the real home and a parent of the real home, because the test
    /// home must never hold the real files of the user. It also refuses a folder at or below a
    /// shared folder of the real home (sharedFolders), because the app writes its shared state in
    /// the test home. It compares the paths as given and their real paths (realForm). So a
    /// symbolic link to the real home or into a shared folder is refused too. A refused value
    /// also gives nil. The check never reads HOME: a smoke test sets HOME to the test home.
    package static func testHome(
        environment: [String: String], realHome: String, check: PathCheck
    ) -> String? {
        guard let value = environment[testHomeKey], value.hasPrefix("/") else { return nil }
        let home = normal(value)
        let real = normal(realHome)
        let homes = [home, realForm(home, check)]
        let reals = [real, realForm(real, check)]
        let shared = reals.flatMap { r in
            sharedFolders.flatMap { name -> [String] in
                let folder = normal("\(r)/\(name)")
                return [folder, realForm(folder, check)]
            }
        }
        let refused = homes.contains { h in
            reals.contains { r in holdsRealHome(h, r, ignoresCase: check.ignoresCase) }
                || shared.contains { s in isAtOrBelow(h, s, ignoresCase: check.ignoresCase) }
        }
        return refused ? nil : home
    }

    /// The value of testHomeKey when testHome refuses it, else nil. testHome also refuses a
    /// variable that is set but empty.
    package static func refusedTestHome(
        environment: [String: String], realHome: String, check: PathCheck
    ) -> String? {
        guard let value = environment[testHomeKey] else { return nil }
        return testHome(environment: environment, realHome: realHome, check: check) == nil
            ? value : nil
    }

    /// The text for a refused value. An empty value shows as "(empty)".
    public static func refusalText(_ value: String) -> String {
        let shown = value.isEmpty ? "(empty)" : value
        return "Bifrost can't use the test home \(shown). Use an absolute folder that isn't /, "
            + "your home folder, a parent of it, or a data folder of Claude Code or Bifrost."
    }

    // The lexically normal form of an absolute path, with no separator at the end except for
    // the root.
    private static func normal(_ path: String) -> String {
        FilePath(path).lexicallyNormalized().string
    }

    // The real path of the path, or the real path of its nearest parent that exists with the rest
    // of the path after it. So a folder that does not exist yet below a link gets the real place
    // of the link. With no real path at all, the path as given.
    private static func realForm(_ path: String, _ check: PathCheck) -> String {
        var folder = FilePath(path)
        var rest: [String] = []
        while true {
            if let real = check.realPath(folder.string) {
                return normal(rest.reversed().reduce(real) { "\($0)/\($1)" })
            }
            guard let last = folder.lastComponent else { return path }
            rest.append(last.string)
            folder.removeLastComponent()
        }
    }

    // True when home is "/", the real home or a parent of the real home.
    private static func holdsRealHome(_ home: String, _ real: String, ignoresCase: Bool) -> Bool {
        let h = ignoresCase ? home.lowercased() : home
        let r = ignoresCase ? real.lowercased() : real
        return h == "/" || h == r || r.hasPrefix(h + "/")
    }

    // True when path is the folder or a path below it.
    private static func isAtOrBelow(_ path: String, _ folder: String, ignoresCase: Bool) -> Bool {
        let p = ignoresCase ? path.lowercased() : path
        let f = ignoresCase ? folder.lowercased() : folder
        return p == f || p.hasPrefix(f + "/")
    }
}
