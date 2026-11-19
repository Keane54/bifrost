// The git runner of Reviews (docs/behaviour/reviews.md, "Running git"). It runs only the cases of
// the closed GitCommand enum, at a GitPlace that pins the repository, each with the safe config
// items and the network items before it, in an env with no GIT_ variable that could point git at
// another repository, index or config.
import BifrostFoundation
import Foundation

package struct RepoGit: Sendable {
    // The -c items of each command. A repository cannot run a hook or a file monitor. Paths stay
    // as they are in the output. gh gives the credentials, and no other helper runs. A symbolic
    // link of a PR becomes a plain file that holds the link text, so a session that reads its
    // worktree cannot follow a link out of it. git does not go into submodules. The items apply
    // to each command, so they also apply to a clone that an earlier version made.
    package static let config = [
        "-c", "core.hooksPath=/dev/null", "-c", "core.fsmonitor=false", "-c",
        "core.quotePath=false", "-c", "credential.helper=", "-c",
        "credential.helper=!gh auth git-credential", "-c", "advice.detachedHead=false", "-c",
        "core.symlinks=false", "-c", "submodule.recurse=false",
    ]
    // The -c items for the network, also for each command. The clones are partial clones, so
    // each command that reads a file (a checkout, a reset, a diff, a merge) can download it from
    // origin. With no gh login, git runs the askpass program of core.askPass or SSH_ASKPASS,
    // although GIT_TERMINAL_PROMPT is 0: an empty core.askPass stops both. Only https is allowed,
    // so no remote address can run a program (ext::, a file:// address with an upload program) or
    // use an SSH agent or key, which can show a prompt.
    package static let networkConfig = [
        "-c", "core.askPass=", "-c", "protocol.ssh.allow=never", "-c", "protocol.allow=never",
        "-c", "protocol.https.allow=always",
    ]
    package static let timeout = Duration.seconds(120), cloneTimeout = Duration.seconds(900)
    // The time from the SIGTERM of a stop to the SIGKILL of a git that still runs. It is shorter
    // than the wait of the quit (QuitWait.limit, 2 s), so a quit ends each git of Reviews.
    package static let stopGrace = Duration.seconds(1)
    // The limit of stdout and of stderr. The status of a worktree with many new files can be long.
    package static let outputLimit = 16 * 1_048_576

    // The GIT_ variables that stay in the env. A test home sets them, so that git reads no config
    // of the user. Each other GIT_ variable goes, because it can point git at another repository,
    // index or object folder, add config, change the programs of git, or write a trace.
    private static let keptVariables: Set = ["GIT_CONFIG_GLOBAL", "GIT_CONFIG_NOSYSTEM"]

    // The folders of Reviews: each git folder and work tree comes from them.
    package let layout: ReviewsLayout
    private let path: String
    private let environment: [String: String]
    // The items of a test home. They come before the safe items, so they cannot undo them.
    private let testHomeConfig: [String]
    private let runner: any CommandRunner

    // path: the git program, a path or a name on the PATH of the env. environment: the env of the
    // claude runs (the login PATH). identity: only for a test home, which has no git config of
    // the user.
    package init(
        path: String, environment: [String: String], layout: ReviewsLayout,
        identity: CommitIdentity? = nil, runner: any CommandRunner
    ) {
        self.init(
            path: path, environment: environment, layout: layout,
            testHomeConfig: identity?.configItems ?? [], runner: runner)
    }

    #if DEBUG
    // The -c item of a test home whose source repositories are local folders. A protocol item
    // with a name wins over protocol.allow, also when it comes first. Only a Debug build has it,
    // so no Release build can reach a local remote.
    package static let localRemotesConfig = ["-c", "protocol.file.allow=always"]

    // A git runner of a Debug test home whose source repositories are local folders.
    package init(
        path: String, environment: [String: String], layout: ReviewsLayout,
        identity: CommitIdentity? = nil, localRemotesForTestHome: Bool, runner: any CommandRunner
    ) {
        self.init(
            path: path, environment: environment, layout: layout,
            testHomeConfig: (identity?.configItems ?? [])
                + (localRemotesForTestHome ? Self.localRemotesConfig : []),
            runner: runner)
    }
    #endif

    private init(
        path: String, environment: [String: String], layout: ReviewsLayout,
        testHomeConfig: [String], runner: any CommandRunner
    ) {
        self.path = path
        self.environment = environment.filter { name, _ in
            !name.hasPrefix("GIT_") || Self.keptVariables.contains(name)
        }.merging(
            ["GIT_TERMINAL_PROMPT": "0", "GIT_LFS_SKIP_SMUDGE": "1", "GCM_INTERACTIVE": "never"]
        ) { _, fixed in fixed }
        self.layout = layout
        self.testHomeConfig = testHomeConfig
        self.runner = runner
    }

    // The full argv of a command at a place: the items of a test home, config, networkConfig, the
    // pin of the repository and the command.
    package func arguments(for command: GitCommand, in place: GitPlace) -> [String] {
        testHomeConfig + Self.config + Self.networkConfig + place.arguments(layout)
            + command.arguments
    }

    // Run the command at the place. A refused command (GitCommand.isRefused), a command that the
    // place does not allow, a command in a worktree that does not belong to its clone, and an add
    // or a commit in a worktree with a submodule (holdsSubmodule) start no git. The clone and the
    // checkout of a worktree download files, so they get the long limit. git gets SIGTERM at a
    // limit or a cancel, so that it removes its lock files, and SIGKILL when it still runs at the
    // end of stopGrace. After a cancel, the run ends only when git ended, so no git outlives its
    // caller, and the caller can remove the folder of a stopped clone.
    @concurrent package func run(_ command: GitCommand, in place: GitPlace) async -> ExecResult {
        guard !command.isRefused else { return Self.notRun("Bifrost won't run this git command.") }
        guard place.allows(command) else {
            return Self.notRun("Bifrost won't run this git command in this folder.")
        }
        if case .worktree(let pr) = place, !belongsToClone(pr) {
            return Self.notRun("Bifrost won't run git in a worktree that isn't part of its clone.")
        }
        switch (command, place) {
        case (.add, .worktree(let pr)), (.commit, .worktree(let pr)):
            if await holdsSubmodule(pr) != false {
                return Self.notRun("Bifrost won't commit in a repository that has a submodule.")
            }
        default:
            break
        }
        let limit: Duration
        switch command {
        case .clone, .worktreeAdd: limit = Self.cloneTimeout
        default: limit = Self.timeout
        }
        let keepsBytes = if case .blob = command { true } else { false }
        return await runner.run(
            Command(
                path, arguments(for: command, in: place), directory: place.folder(layout),
                environment: environment, timeout: limit, killSignal: .terminate,
                terminateGrace: Self.stopGrace, outputLimit: Self.outputLimit, waitsForEnd: true,
                keepsStdoutBytes: keepsBytes))
    }

    // True when the index or the head of the worktree holds a submodule (a gitlink, mode
    // 160000); nil when git cannot list them. A session can write the folder of a submodule, and
    // git can run a program of that folder: a commit with nothing staged looks into it, as a
    // status with no --ignore-submodules does. So Bifrost never commits in such a worktree.
    package func holdsSubmodule(_ pr: PRKey) async -> Bool? {
        for command in [GitCommand.lsFilesStage([]), .headTree] {
            let result = await run(command, in: .worktree(pr))
            guard result.succeeded, let modes = Self.entryModes(result.stdout) else { return nil }
            if modes.contains("160000") { return true }
        }
        return false
    }

    // The mode of each entry of a listing of ls-files --stage -z or ls-tree -z, in which each
    // entry is the mode, a space, more fields, a tab and the path. nil for an output that does
    // not have this form.
    static func entryModes(_ output: String) -> [Substring]? {
        var modes: [Substring] = []
        for entry in output.split(separator: "\0") {
            guard entry.contains("\t"), let mode = entry.split(separator: " ").first else {
                return nil
            }
            modes.append(mode)
        }
        return modes
    }

    private static func notRun(_ text: String) -> ExecResult {
        ExecResult(.notStarted, stderr: text)
    }

    // True when the admin folder of the worktree in the clone names the worktree of the PR: its
    // gitdir file holds the path of <worktree>/.git (absolute, or relative to the admin folder).
    // The admin folder is in the git folder of the clone, which a session cannot write.
    func belongsToClone(_ pr: PRKey) -> Bool {
        let admin = GitPlace.adminFolder(pr, layout)
        let file = admin + "/gitdir"
        var info = stat()
        guard lstat(file, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size < 4096,
            let data = FileManager.default.contents(atPath: file)
        else { return false }
        let text = String(decoding: data, as: UTF8.self).trimmed()
        guard !text.isEmpty else { return false }
        let named = URL(
            fileURLWithPath: text, relativeTo: URL(fileURLWithPath: admin, isDirectory: true)
        ).standardizedFileURL
        guard named.lastPathComponent == ".git",
            let named = RealPath.of(named.deletingLastPathComponent().path(percentEncoded: false)),
            let expected = RealPath.of(GitPlace.worktree(pr, layout))
        else { return false }
        return named == expected
    }
}
