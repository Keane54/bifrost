// The check before a Delete (docs/behaviour/actions.md, "The worktree check"). A session in a
// worktree can have work that is not merged: changed files and commits. Each git command only
// reads.
import BifrostFoundation

package struct WorktreeChecker: Sendable {
    // The time limit of each git command.
    package static let gitTimeout = Duration.seconds(5)
    // A failed check tries one more time after this wait. A git command of the session or an
    // install in the worktree can make one check fail.
    package static let retry = Duration.milliseconds(500)
    // The time limit of the reads of the skip root check. A read of a real path can hang, for
    // example on a network volume that is offline.
    package static let skipRootLimit = Duration.seconds(2)

    private let runner: any CommandRunner
    private let environment: [String: String]
    private let skipRoots: SkipRoots
    private let clock: any Clock<Duration>
    private let realPath: @Sendable (String) -> String?

    // environment is the env of git: the env of the claude runs, so git is the git of the login
    // PATH. skipRoots are the folders in which the check runs no git (SkipRoots). A test gives a
    // manual clock and a fake real path.
    package init(
        runner: any CommandRunner, environment: [String: String], skipRoots: [String],
        clock: any Clock<Duration>,
        realPath: @escaping @Sendable (String) -> String? = RealPath.of
    ) {
        self.runner = runner
        self.environment = environment
        self.skipRoots = SkipRoots(skipRoots)
        self.clock = clock
        self.realPath = realPath
    }

    // The counts of the worktree of the folder. A folder outside .claude/worktrees/<name> has no
    // worktree and runs no git. nil means that a git command failed in both tries, or that the
    // worktree or its repository is at or below a skip root, so no git ran.
    package func check(_ cwd: String) async -> WorktreeCheck? {
        guard let root = WorktreeRoot(cwd: cwd) else {
            return WorktreeCheck(branch: nil, changedFiles: 0, unmergedCommits: 0, worktree: nil)
        }
        guard await !underSkipRoot(root) else { return nil }
        return await twice { await countWork(root, upTo: "HEAD") }
    }

    // The check of the Delete dialog for a worktree, and the check of a Delete after the stop:
    // the counts and the HEAD commit of the worktree. The discard needs the same HEAD commit in
    // both checks, and the discard value of claude rm starts with it. Each try reads the HEAD
    // commit first and counts the commits up to that commit, so the counts are always the counts
    // of that HEAD, also when the HEAD moves during the check. nil means that a git command
    // failed in both tries, that the worktree or its repository is at or below a skip root, or
    // that the folder is not in a worktree.
    package func checkWithHead(_ worktree: String) async -> WorktreeCheck? {
        guard let root = WorktreeRoot(cwd: worktree), await !underSkipRoot(root) else {
            return nil
        }
        return await twice {
            guard let head = await git(["-C", root.worktree, "rev-parse", "HEAD"])?.trimmed(),
                Self.isCommitId(head, lengths: [40, 64]),
                var check = await countWork(root, upTo: head)
            else { return nil }
            check.head = head
            return check
        }
    }

    // The count of the changed files that git tracks in a worktree: the lines of git status that
    // do not start with "??", so untracked files do not count. The Delete of a running worktree
    // session reads it before the stop. nil means that git failed in both tries, that the folder
    // is not in .claude/worktrees/<name>, or that the worktree or its repository is at or below
    // a skip root.
    package func trackedChanges(_ worktree: String) async -> UInt? {
        guard let root = WorktreeRoot(cwd: worktree), await !underSkipRoot(root) else {
            return nil
        }
        return await twice {
            guard let status = await git(Self.statusArgs(root.worktree)) else { return nil }
            return UInt(Self.lines(status).count { !$0.hasPrefix("??") })
        }
    }

    // One check. The base is the commit that the main checkout has now, so the check also works
    // for a detached HEAD. The count of the commits goes from the base to the tip: HEAD, or the
    // commit ID that the caller read.
    private func countWork(_ root: WorktreeRoot, upTo tip: String) async -> WorktreeCheck? {
        let worktree = root.worktree
        guard let status = await git(Self.statusArgs(worktree)),
            let head = await git(["-C", worktree, "rev-parse", "--abbrev-ref", "HEAD"]),
            let base = await git(["-C", root.repo, "rev-parse", "HEAD"])?.trimmed(),
            Self.isCommitId(base, lengths: [40, 64]),
            let count = await git(["-C", worktree, "rev-list", "--count", "\(base)..\(tip)"])
                .flatMap({ Self.count($0.trimmed()) })
        else { return nil }
        let branch = head.trimmed()
        return WorktreeCheck(
            branch: branch.isEmpty || branch == "HEAD" ? nil : branch,
            changedFiles: UInt(Self.lines(status).count), unmergedCommits: count,
            worktree: worktree)
    }

    // The work, and when it gives nil, the work again after the wait. A cancel during the wait
    // gives nil.
    private func twice<Value: Sendable>(_ work: () async -> Value?) async -> Value? {
        if let first = await work() { return first }
        do {
            try await clock.sleep(for: Self.retry)
        } catch {
            return nil
        }
        return await work()
    }

    // The output of one git command, or nil when it did not end with exit code 0.
    private func git(_ args: [String]) async -> String? {
        let result = await runner.run(
            Command("git", args, environment: environment, timeout: Self.gitTimeout))
        return result.succeeded ? result.stdout : nil
    }

    // True when the worktree or its repository is at or below a skip root, by the paths as they
    // are or by their real paths. The reads run in one task on the blocking executor and race
    // the limit on the clock (BlockingExecutor.run(within:)). A read that does not end in the
    // limit counts as under a skip root, so the check fails and runs no git. A cancel of the
    // caller also counts as under a skip root.
    private func underSkipRoot(_ root: WorktreeRoot) async -> Bool {
        guard !skipRoots.roots.isEmpty else { return false }
        return await BlockingExecutor.run(within: Self.skipRootLimit, on: clock, else: true) {
            [skipRoots, realPath] in
            for path in [root.worktree, root.repo] {
                if await skipRoots.contains(path, realPath: { realPath($0) }) { return true }
            }
            return false
        }
    }

    // git status takes no optional lock, so it does not write the index.lock of the worktree.
    private static func statusArgs(_ worktree: String) -> [String] {
        ["--no-optional-locks", "-C", worktree, "status", "--porcelain"]
    }

    // The lines of the text that are not empty after the trim. A line ends at each LF, also at
    // the LF of a CR LF pair, which Swift keeps as one Character.
    private static func lines(_ text: String) -> [Substring] {
        text.split(whereSeparator: { $0 == "\n" || $0 == "\r\n" }).filter {
            !$0.trimmed().isEmpty
        }
    }

    // A count of git: one or more ASCII digits, in the range of UInt. A sign is not a count.
    private static func count(_ text: String) -> UInt? {
        guard !text.isEmpty, text.utf8.allSatisfy({ (0x30...0x39).contains($0) }) else {
            return nil
        }
        return UInt(text)
    }

    // A commit ID: lower-case hex digits, of one of the lengths (40 for SHA-1, 64 for SHA-256).
    private static func isCommitId(_ text: String, lengths: Set<Int>) -> Bool {
        lengths.contains(text.utf8.count)
            && text.utf8.allSatisfy { (0x30...0x39).contains($0) || (0x61...0x66).contains($0) }
    }
}
