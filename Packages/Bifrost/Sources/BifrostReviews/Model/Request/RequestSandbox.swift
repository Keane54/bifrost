// The --settings value of a request session (docs/behaviour/reviews.md, "Request rounds"). The
// session has Bash, so Claude Code's sandbox and permission rules keep a PR body or a comment from
// making Claude post, push, read secrets or send data out:
// - No statusline, and no hook at all: a PR head can hold a .claude folder with hooks.
// - The sandbox is on. Bash runs in it with no prompt, and no command can run outside it.
// - The network allows only the package registries of registryDomains, with the strict allow
//   list, so a Bash call that asks for one more host is refused. No entry is a GitHub host, and
//   no entry is a proxy that fetches a module from any host.
// - Bash can't write the .git folder of the clone. The worktree of the PR is a linked worktree,
//   so its git data is in that folder, and Bifrost runs git there.
// - Bash can't read the input folders and the worktrees of the other PRs of the clone, the
//   Reviews folder (the state with the token of each round, and the other clones) or a secret
//   path of the home (SecretPath). It can read its own worktree, its own input folder and the
//   .git folder of the clone, which git needs. The file tools stay in the working folders
//   (--restricted, PRSessionArgs).
// - Edit and Write can't write outside the worktree and the input folder.
// - The deny list stops a commit, the push, gh, the web tools and the reads of the secret paths
//   by the file tools. It also stops Edit and Write in the .git folder of the clone, so that
//   block does not rest on one key only. A rule path that starts with "//" is an absolute path.
// Each path must be the real path that Claude Code compares; the round gives them.
import BifrostFoundation
import Foundation

// A file or a folder below the home of the user that a request session never reads: the sandbox
// read rules refuse Bash, and the deny list refuses the file tools. This enum is the one list of
// them.
package enum SecretPath: String, CaseIterable, Sendable {
    // The folder of Bifrost: the Reviews state (the token of each round) and every clone.
    case bifrost = ".bifrost"
    case ssh = ".ssh"
    case gnupg = ".gnupg"
    case aws = ".aws"
    case gh = ".config/gh"
    case netrc = ".netrc"
    case gitCredentials = ".git-credentials"
    // The whole folder, so also its config.json with the logins of the registries.
    case docker = ".docker"
    case npm = ".npmrc"
    case gem = ".gem/credentials"
    case kube = ".kube"
    case keychains = "Library/Keychains"

    // True for a file. Each other secret path is a folder.
    package var isFile: Bool {
        switch self {
        case .netrc, .gitCredentials, .npm, .gem: true
        default: false
        }
    }
}

// The real paths of the folders of one request session, for its rules.
package struct SessionPaths: Sendable, Equatable {
    // The clone of the repository.
    package var clone: String
    // The worktree of the PR, below the clone.
    package var worktree: String
    // The input folder of the PR, below the clone.
    package var inputFolder: String
    // The Reviews folder: the state of Reviews and every clone.
    package var reviews: String
    // The home of the user (the user database), which holds the secret paths.
    package var home: String

    // Each path loses a "/" at its end.
    package init(
        clone: String, worktree: String, inputFolder: String, reviews: String, home: String
    ) {
        self.clone = Self.plain(clone)
        self.worktree = Self.plain(worktree)
        self.inputFolder = Self.plain(inputFolder)
        self.reviews = Self.plain(reviews)
        self.home = Self.plain(home)
    }

    private static func plain(_ path: String) -> String {
        path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
    }
}

package enum RequestSandbox {
    // The package registries that the sandbox network allows.
    package static let registryDomains = [
        "registry.npmjs.org", "registry.yarnpkg.com", "repo.yarnpkg.com", "pypi.org",
        "files.pythonhosted.org", "index.crates.io", "static.crates.io", "rubygems.org",
        "index.rubygems.org", "repo.maven.apache.org", "repo1.maven.org", "plugins.gradle.org",
        "services.gradle.org", "api.nuget.org",
    ]

    // The commands and the tools that the session can never use.
    package static let deniedTools = [
        "Bash(git push:*)", "Bash(git commit:*)", "Bash(gh:*)", "WebFetch", "WebSearch",
    ]

    // The settings for the folders of the session, as one argument. No shell reads it. nil when
    // the encoder fails: then the round does not start, because empty settings have no sandbox.
    package static func settings(_ paths: SessionPaths) -> String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(value(paths)) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    // The settings as a JSON value.
    package static func value(_ paths: SessionPaths) -> JSONValue {
        let gitFolder = paths.clone + "/.git"
        // The worktree and the input folder are below the folder of Bifrost, and --restricted
        // keeps the file tools in them, so the deny rule of that folder is for Bash only.
        let fileSecrets = SecretPath.allCases.filter { $0 != .bifrost }
        let deny =
            deniedTools + fileSecrets.map { readRule($0, home: paths.home) }
            + ["Edit(/\(gitFolder)/**)", "Write(/\(gitFolder)/**)"]
        let denyRead =
            [
                paths.reviews, paths.clone + "/" + ReviewsLayout.ioFolder,
                paths.clone + "/" + ReviewsLayout.worktreesFolder,
            ] + SecretPath.allCases.map { paths.home + "/" + $0.rawValue }
        let allowRead = [paths.worktree, paths.inputFolder, gitFolder]
        return [
            "statusLine": ["type": "command", "command": "true"],
            "disableAllHooks": true,
            "permissions": [
                "blockWritesOutsideWorkingDirectories": true,
                "deny": .array(deny.map(JSONValue.string)),
            ],
            "sandbox": [
                "enabled": true,
                "autoAllowBashIfSandboxed": true,
                "allowUnsandboxedCommands": false,
                "filesystem": [
                    "denyWrite": [.string(gitFolder)],
                    "denyRead": .array(denyRead.map(JSONValue.string)),
                    "allowRead": .array(allowRead.map(JSONValue.string)),
                ],
                "network": [
                    "allowedDomains": .array(registryDomains.map(JSONValue.string)),
                    "strictAllowlist": true,
                ],
            ],
        ]
    }

    // The deny rule of the reads of a secret path by the file tools, with its absolute path. A
    // rule with /** does not match a file, so the rule of a file names the file, and the rule of
    // a folder names each file below it.
    private static func readRule(_ secret: SecretPath, home: String) -> String {
        let path = "/" + home + "/" + secret.rawValue
        return secret.isFile ? "Read(\(path))" : "Read(\(path)/**)"
    }
}
