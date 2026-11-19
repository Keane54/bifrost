// The --settings value of a request session (docs/behaviour/reviews.md, "Request rounds"): the
// sandbox, the network allow list, the read rules and the deny list.
import BifrostFoundation
import Foundation
import Testing

@testable import BifrostReviews

@Suite("the sandbox of a request session")
struct RequestSandboxTests {
    static let home = "/Users/someone"
    static let reviews = home + "/.bifrost/reviews"
    static let clone = reviews + "/repos/owner-a/repo-a"
    static let paths = SessionPaths(
        clone: clone, worktree: clone + "/.bifrost-worktrees/7",
        inputFolder: clone + "/.bifrost-io/7", reviews: reviews, home: home)

    // The parsed value of the argument, as Claude Code reads it.
    static func settings() throws -> [String: JSONValue] {
        let text = try #require(RequestSandbox.settings(paths))
        let value = try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
        #expect(value == RequestSandbox.value(paths))
        return try #require(value.object)
    }

    static func filesystem() throws -> [String: JSONValue] {
        try #require(try settings()["sandbox"]?.object?["filesystem"]?.object)
    }

    static func strings(_ value: JSONValue?) throws -> [String] {
        try #require(value?.array?.compactMap { $0.string })
    }

    // The sandbox is on with no way out, its network allows only the package registries (no
    // GitHub host), and neither Bash nor Edit nor Write can change the .git folder of the clone.
    // The writes stay in the working folders, and the session runs no hook and no statusline.
    @Test func theSandboxBlocksGitHubAndTheGitFolder() throws {
        let settings = try Self.settings()
        let sandbox = try #require(settings["sandbox"]?.object)
        #expect(sandbox["enabled"] == true && sandbox["autoAllowBashIfSandboxed"] == true)
        #expect(sandbox["allowUnsandboxedCommands"] == false)
        let network = try #require(sandbox["network"]?.object)
        #expect(network["strictAllowlist"] == true)
        let hosts = try Self.strings(network["allowedDomains"])
        #expect(hosts == RequestSandbox.registryDomains && hosts.contains("registry.npmjs.org"))
        #expect(!hosts.contains { $0.lowercased().contains("github") })
        let gitFolder = Self.clone + "/.git"
        #expect(sandbox["filesystem"]?.object?["denyWrite"] == [.string(gitFolder)])
        let permissions = try #require(settings["permissions"]?.object)
        #expect(permissions["blockWritesOutsideWorkingDirectories"] == true)
        let deny = try Self.strings(permissions["deny"])
        for rule in [
            "Bash(git push:*)", "Bash(git commit:*)", "Bash(gh:*)", "WebFetch", "WebSearch",
            "Edit(/\(gitFolder)/**)", "Write(/\(gitFolder)/**)",
        ] {
            #expect(deny.contains(rule), "\(rule)")
        }
        #expect(settings["disableAllHooks"] == true)
        #expect(settings["statusLine"] == ["type": "command", "command": "true"])
        // A "/" at the end of a path gives the same rules.
        let slash = SessionPaths(
            clone: Self.clone + "/", worktree: Self.paths.worktree + "/",
            inputFolder: Self.paths.inputFolder + "/", reviews: Self.reviews + "/",
            home: Self.home + "/")
        #expect(RequestSandbox.value(slash) == RequestSandbox.value(Self.paths))
    }

    // Bash can't read the folders of the other PRs of the clone, the Reviews folder or a secret
    // path of the home. It can read its own worktree, its own input folder and the .git folder
    // of the clone, which git needs.
    @Test func bashReadsOnlyItsOwnFolders() throws {
        let filesystem = try Self.filesystem()
        let denyRead = try Self.strings(filesystem["denyRead"])
        for path in [
            Self.reviews, Self.clone + "/.bifrost-io", Self.clone + "/.bifrost-worktrees",
            Self.home + "/.bifrost", Self.home + "/.ssh", Self.home + "/.config/gh",
            Self.home + "/.aws", Self.home + "/.netrc", Self.home + "/.gnupg",
            Self.home + "/.docker", Self.home + "/.npmrc", Self.home + "/.gem/credentials",
            Self.home + "/.kube", Self.home + "/Library/Keychains",
            Self.home + "/.git-credentials",
        ] {
            #expect(denyRead.contains(path), "\(path)")
        }
        #expect(denyRead.count == 3 + SecretPath.allCases.count)
        #expect(
            try Self.strings(filesystem["allowRead"])
                == [Self.paths.worktree, Self.paths.inputFolder, Self.clone + "/.git"])
    }

    // The file tools can't read a secret path either: each one has its read rule with the
    // absolute path, a folder for each file below it, a file by its name. The Bifrost folder has
    // no such rule: the working folders are below it, and --restricted keeps the file tools in
    // them.
    @Test func theDenyListHasEachSecretPath() throws {
        let deny = try Self.strings(try Self.settings()["permissions"]?.object?["deny"])
        let folders = SecretPath.allCases.filter { !$0.isFile && $0 != .bifrost }
        for secret in folders {
            #expect(deny.contains("Read(//Users/someone/\(secret.rawValue)/**)"), "\(secret)")
        }
        for secret in SecretPath.allCases where secret.isFile {
            #expect(deny.contains("Read(//Users/someone/\(secret.rawValue))"), "\(secret)")
        }
        #expect(!deny.contains { $0.hasPrefix("Read(") && $0.contains("/.bifrost") })
        #expect(
            Set(SecretPath.allCases.map(\.rawValue))
                == [
                    ".bifrost", ".ssh", ".gnupg", ".aws", ".config/gh", ".netrc",
                    ".git-credentials", ".docker", ".npmrc", ".gem/credentials", ".kube",
                    "Library/Keychains",
                ])
    }
}
