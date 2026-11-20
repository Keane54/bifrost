// The repo store of Reviews (docs/behaviour/reviews.md, "Clones and trust"): Bifrost's own clone
// of each repository, one detached worktree and one input folder for each PR, all below
// ReviewsLayout.reposRoot. Bifrost never uses a checkout of the user.
//
// - A clone is a partial clone with no checkout (GitCommand.clone), in lower case. It goes to a
//   new temporary folder first (<clone>~cloning-<random>) and moves to its place only when git
//   ends well, so a stop half way never leaves a folder that looks like a clone. Each clone has
//   its own temporary folder, so no two gits ever write into one folder; a clone removes the
//   temporary folders of its repository that an earlier run left. One worker (SerialWork) runs
//   the clones and the removals one at a time, in the order of the calls. A second call for a
//   clone that runs or waits waits for the same clone.
// - cancelClones() stops each clone: git gets SIGTERM, then SIGKILL at the end of its grace, and
//   the call ends when each git ended and its temporary folder went. A stopped clone is no
//   failure. Reviews calls it at a turn-off and at a quit, so no git outlives Reviews.
// - A failed clone logs one line, and the repository counts as failed for retryAfter on the
//   clock (failedRecently). The set-up skips it until then; a click on Review tries at once.
// - Bifrost owns these folders, so it removes, resets and cleans them. Each removal first checks
//   that the path is below the repos folder, also after each link above it resolves. The last
//   part of a path does not resolve: a removal deletes a link, never the folder that it names.
// - Each git command runs through RepoGit at a GitPlace, so git never reads the .git file of a
//   worktree, which a session can write. The worktree command prunes first, so git gives the
//   admin folder of the new worktree the name that GitPlace.adminFolder pins.
// - The file work runs on the blocking executor, because a slow disk can hold it.
// - The one session of a PR keeps its working folders from round to round
//   (docs/behaviour/reviews.md, "PR sessions"): roundFolder keeps the input folder and removes
//   each item in it, and placeWorktree keeps the worktree and moves it to the new head. A kept
//   worktree must be clean at the head after its reset, else placeWorktree makes it again and
//   logs it. inputFolder and prepareWorktree make the folders again at each round.
// - The safety net of the worktree (docs/behaviour/reviews.md, "Your own requests"): at the end
//   of the turn of a round, markLeftovers keeps each change of the worktree with the stamp of its
//   file, and a reset keeps what stays after it. unknownChanges gives each change that is not in
//   that record: a change after the turn, which a person made in the session. The record is in
//   memory only, so after a restart each change counts as a change of a person.
// - An own request of the user: the file in the input folder (OwnRequestFile), and uncommit, which
//   makes a commit that did not reach GitHub changes in the worktree again.
import BifrostFoundation
import Darwin
import Foundation
import OSLog

// The commits of a PR after its fetch: the head, the tip of the base branch, and their merge
// base, where the full diff of the PR starts.
package struct FetchedPR: Sendable, Equatable {
    package var head: CommitID
    package var base: CommitID
    package var mergeBase: CommitID

    package init(head: CommitID, base: CommitID, mergeBase: CommitID) {
        self.head = head
        self.base = base
        self.mergeBase = mergeBase
    }
}

// The worktree of a PR for a round: kept is the worktree of the last round at the new head, made
// is a new worktree.
package enum WorktreePlace: Sendable, Equatable {
    case kept(URL), made(URL)

    package var url: URL {
        switch self {
        case .kept(let url), .made(let url): url
        }
    }

    package var isKept: Bool {
        if case .kept = self { true } else { false }
    }
}

// What the read of the result file of a round gives. Only a regular file within the limit gives
// its bytes: a link, a folder or another special item is not a regular file.
package enum ResultRead: Sendable, Equatable {
    case missing, notRegular, tooLarge
    case data(Data)

    // Why the read gave no good result of a round, for the text of the failure only. refusal
    // gives the reason of the check of the round for the bytes, or nil when they pass now: the
    // turn ended with no good result, so a later good file does not count.
    func failure(limit: Int, refusal: (Data) -> ResultRefusal?) -> RoundFailure {
        switch self {
        case .data(let data):
            refusal(data).map(RoundFailure.badResult) ?? .noResult
        case .missing:
            .noResult
        case .notRegular:
            .badResult(ResultRefusal("the result is not a regular file"))
        case .tooLarge:
            .badResult(
                ResultRefusal("the result is larger than \(ReviewResult.count(limit)) bytes"))
        }
    }
}

// A failure of the repo store. message is its text for the user and the log.
package enum RepoError: Error, Sendable, Equatable {
    // A git command failed. The text says what Bifrost tried and the first line of the error
    // of git.
    case git(String)
    // A file call on the folders of the clones failed.
    case files(FileError)
    // A stop of Reviews ended the clone (RepoStore.cancelClones).
    case cancelled

    package var message: String {
        switch self {
        case .git(let text): text
        case .cancelled: "Bifrost stopped the copy of the repository."
        case .files(let failure):
            "Bifrost couldn't change its copy of the repository. \(failure.message)"
        }
    }
}

@MainActor
package final class RepoStore {
    // The wait after a failed clone before the set-up tries that clone again.
    package static let retryAfter = Duration.seconds(3600)

    package let layout: ReviewsLayout
    // The git runner of the clones. The fix commit and the push of a request round use it too.
    package let git: RepoGit
    private let cloneAddress: @Sendable (RepoName) -> URL
    private let timeline: Timeline
    private let log: any ReviewsLog
    private let folders: RepoFolders
    // The one worker of the clones and the removals.
    private let work = SerialWork()
    // The callers that wait for the clone of each repository that runs now or waits for its
    // turn. The first call adds the clone to the worker.
    private var cloneWaiters: [RepoName: [CheckedContinuation<Result<Void, RepoError>, Never>]] =
        [:]
    // The task of the clone that runs now, so cancelClones can end its git.
    private var cloning: Task<Result<Void, RepoError>, Never>?
    // The count of the calls of cancelClones. A clone that waited for its turn while a cancel came
    // does not start.
    private var cancels = 0
    // The time of the last failed clone of each repository, on the timeline. A clone that works
    // clears it.
    private var failures: [RepoName: Duration] = [:]
    // The head of the worktree of each PR, from its prepare. The reset goes back to it.
    private var heads: [PRKey: CommitID] = [:]
    // The changes of the worktree of each PR that Bifrost knows: what a round left at the end of
    // its turn, or what stayed after a reset. Each path has the stamp of its file.
    private var known: [PRKey: [String: PathStamp]] = [:]

    private static let logger = Logger(bifrost: "reviews")

    // cloneAddress gives the source of a clone: in the app, https://github.com/<owner>/<repo>.git.
    // A test gives a local bare repository. clock runs the wait after a failed clone.
    package init(
        layout: ReviewsLayout, git: RepoGit, cloneAddress: @escaping @Sendable (RepoName) -> URL,
        clock: any Clock<Duration>, log: any ReviewsLog
    ) {
        self.layout = layout
        self.git = git
        self.cloneAddress = cloneAddress
        timeline = Timeline(clock)
        self.log = log
        folders = RepoFolders(root: layout.reposRoot.plainPath)
    }

    // MARK: - The clones

    // The source of the clone of the repository: the only address that the push of a fix goes
    // to.
    package func address(of repo: RepoName) -> URL { cloneAddress(repo) }

    // True when the clone of the repository is in its place: its .git folder is there.
    package func hasClone(_ repo: RepoName) async -> Bool {
        let (folders, path) = (folders, layout.clone(repo).plainPath + "/.git")
        return await BlockingExecutor.run { folders.isFolder(path) }
    }

    // True for retryAfter after a failed clone of the repository.
    package func failedRecently(_ repo: RepoName) -> Bool {
        guard let failed = failures[repo] else { return false }
        return timeline.now() - failed < Self.retryAfter
    }

    // Make the clone of the repository when it is missing. A clone of the repository that runs
    // gives its own result. The clones and the removals run one at a time, in the order of the
    // calls.
    package func ensureClone(_ repo: RepoName) async throws(RepoError) {
        if cloneWaiters[repo] != nil {
            try await withCheckedContinuation { cloneWaiters[repo, default: []].append($0) }.get()
            return
        }
        cloneWaiters[repo] = []
        let (git, folders, layout, cancel) = (git, folders, layout, cancels)
        let address = cloneAddress(repo)
        let result = await work.run { [weak self] () -> Result<Void, RepoError> in
            guard let self, cancel == self.cancels else { return .failure(.cancelled) }
            let clone = Task {
                await Self.makeClone(
                    repo, from: address, git: git, folders: folders, layout: layout)
            }
            self.cloning = clone
            let result = await clone.value
            self.cloning = nil
            return result
        }
        record(repo, result)
        for waiter in cloneWaiters.removeValue(forKey: repo) ?? [] {
            waiter.resume(returning: result)
        }
        try result.get()
    }

    // Stop each clone that runs or waits. The call ends when each git ended (SIGTERM, then
    // SIGKILL at the end of its grace) and each temporary folder of a stopped clone went. A
    // stopped clone counts as no failure.
    package func cancelClones() async {
        cancels += 1
        cloning?.cancel()
        await work.idle()
    }

    // Remove each clone with its worktrees and input folders. The repos folder stays, and
    // nothing else of the Reviews folder changes. The removal waits for the clone that runs, and
    // a later clone waits for the removal. Each folder first moves to <name>~deleting, so a
    // removal that stops half way never leaves a folder that looks like a clone.
    package func removeAllClones() async throws(RepoError) {
        let folders = folders
        heads = [:]
        failures = [:]
        let removal = await work.run {
            await BlockingExecutor.run { () -> Result<Void, FileError> in
                Result { () throws(FileError) in try folders.removeAll() }
            }
        }
        if case .failure(let failure) = removal { throw .files(failure) }
    }

    // MARK: - The folders of a PR

    // Make the worktree of the PR again, detached at the head, with mode 0700. An old worktree
    // of the PR goes first, then git forgets it (worktree prune), so the new admin folder gets
    // the name that RepoGit pins. A worktree whose admin folder does not name it goes again.
    package func prepareWorktree(_ pr: PRKey, head: CommitID) async throws(RepoError) -> URL {
        let worktree = layout.worktree(pr.repo, number: pr.number)
        let path = worktree.plainPath
        let folders = folders
        try await files { () throws(FileError) in
            try folders.remove(path)
            try folders.makeFolder((path as NSString).deletingLastPathComponent)
        }
        try await mustRun(.worktreePrune, pr.repo)
        try await mustRun(.worktreeAdd(worktree, head), pr.repo)
        let git = git
        guard await BlockingExecutor.run({ git.belongsToClone(pr) }) else {
            await dropWorktree(pr)
            throw .git(Self.prepareFailed + "git didn't link the worktree to its admin folder.")
        }
        try await files { () throws(FileError) in try folders.setPrivate(path) }
        heads[pr] = head
        known[pr] = [:]
        return worktree
    }

    // The worktree of the PR at the head. The worktree of the last round stays when its folder
    // (not a link) is in its place and belongs to the clone: it resets to the head in place
    // (resetWorktree), and it gets mode 0700 again. It stays only when it is clean at the head
    // after the reset (isClean). Else prepareWorktree makes it again, and a worktree that was in
    // its place gets a line in the log, because the next turn starts a new session.
    package func placeWorktree(_ pr: PRKey, head: CommitID) async throws(RepoError)
        -> WorktreePlace
    {
        let worktree = layout.worktree(pr.repo, number: pr.number)
        let (path, folders, git) = (worktree.plainPath, folders, git)
        let found = await BlockingExecutor.run { () -> (there: Bool, inPlace: Bool) in
            (folders.exists(path), folders.isFolder(path) && git.belongsToClone(pr))
        }
        if found.inPlace, await reset(pr, to: head).didReset, await isClean(pr, at: head) {
            try await files { () throws(FileError) in try folders.setPrivate(path) }
            return .kept(worktree)
        }
        if found.there { log.record(.worktreeMadeAgain(pr)) }
        return .made(try await prepareWorktree(pr, head: head))
    }

    // True when the worktree of the PR is clean at the head after a reset: git status lists no
    // file that git does not track (an entry "??" means that the clean failed for that file), and
    // git gives the head as its HEAD. The check does not look at the tracked files, because line
    // ends or the case of a name can make git list a tracked file that the reset did restore.
    private func isClean(_ pr: PRKey, at head: CommitID) async -> Bool {
        let status = await git.run(.status, in: .worktree(pr))
        guard status.succeeded,
            !status.stdout.split(separator: "\0").contains(where: { $0.hasPrefix("??") })
        else { return false }
        let parsed = await git.run(.revParse("HEAD^{commit}"), in: .worktree(pr))
        return parsed.succeeded && CommitID(parsed.stdout.trimmed()) == head
    }

    // The input folder of the PR, new and empty, with mode 0700.
    package func inputFolder(_ pr: PRKey) async throws(RepoError) -> URL {
        let folder = layout.inputFolder(pr.repo, number: pr.number)
        let (path, folders) = (folder.plainPath, folders)
        try await files { () throws(FileError) in
            try folders.remove(path)
            try folders.makeFolder(path)
            try folders.setPrivate(path)
        }
        return folder
    }

    // The round folder of the PR: its input folder, with mode 0700. The folder itself stays, and
    // each item in it goes, so no file of an earlier round stays. A link in it goes, not the item
    // that it names. A missing folder, or another item at its place, becomes a new folder.
    package func roundFolder(_ pr: PRKey) async throws(RepoError) -> URL {
        let folder = layout.inputFolder(pr.repo, number: pr.number)
        let (path, folders) = (folder.plainPath, folders)
        try await files { () throws(FileError) in try folders.emptyFolder(path) }
        return folder
    }

    // After a round: count the changes of the session in the worktree (each changed, new or
    // deleted file), then reset the worktree to its head, remove each file that git does not
    // track (also the ignored files) and write its .git file again, which a session can change.
    // The count of the changes that went goes to the log: with no head to reset to, only the new
    // files count. A missing worktree gives 0. A failed count gives 0, and the reset and the
    // clean still run. A new head (the fix commit of a request round) becomes the head of the
    // worktree, so the files that the commit does not hold go.
    @discardableResult
    package func resetWorktree(_ pr: PRKey, to newHead: CommitID? = nil) async -> Int {
        await reset(pr, to: newHead).changes
    }

    // The steps of resetWorktree. didReset is true when git reset the worktree to a head with no
    // error.
    private func reset(_ pr: PRKey, to newHead: CommitID?) async -> (changes: Int, didReset: Bool) {
        let worktree = layout.worktree(pr.repo, number: pr.number).plainPath
        let folders = folders
        guard await BlockingExecutor.run({ folders.isFolder(worktree) }) else { return (0, false) }
        if let newHead { heads[pr] = newHead }
        var head = heads[pr]
        if head == nil {
            let parsed = await git.run(.revParse("HEAD^{commit}"), in: .worktree(pr))
            head = parsed.succeeded ? CommitID(parsed.stdout.trimmed()) : nil
        }
        let status = await git.run(.status, in: .worktree(pr))
        // With no head, no reset runs, so only the files that git does not track go (the clean).
        let entries: [Substring] = status.stdout.split(separator: "\0").filter { $0.count > 3 }
        let removed = head == nil ? entries.filter { $0.hasPrefix("??") } : entries
        let changes = status.succeeded ? removed.count : 0
        var didReset = false
        if let head { didReset = await git.run(.resetHard(head), in: .worktree(pr)).succeeded }
        _ = await git.run(.clean, in: .worktree(pr))
        let admin = GitPlace.adminFolder(pr, layout)
        _ = try? await files { () throws(FileError) in
            try folders.writeGitFile(worktree: worktree, admin: admin)
        }
        // Bifrost made the worktree as it is now, so what stays is no change of a person.
        if didReset { known[pr] = await stamps(pr) }
        log.record(.worktreeReset(pr, changes: changes))
        return (changes, didReset)
    }

    // The paths that the session changed in the worktree of the PR (each changed, new or deleted
    // file), relative to the root of the worktree, from git status. nil when git fails. The ignored
    // files are not listed, so the commit of a request round can never hold one.
    package func changedPaths(_ pr: PRKey) async -> Set<String>? {
        let status = await git.run(.status, in: .worktree(pr))
        guard status.succeeded else { return nil }
        return Self.statusPaths(status.stdout)
    }

    // The path of each entry of the output of git status (GitCommand.status). Each entry is
    // "XY <path>": two letters of state, a space and the path. The prefix is three bytes. It is
    // not three Characters: a combining mark at the start of a path joins the space in one
    // Character.
    nonisolated static func statusPaths(_ output: String) -> Set<String> {
        let entries = output.utf8.split(separator: 0).filter { $0.count > 3 }
        return Set(entries.map { String(decoding: $0.dropFirst(3), as: UTF8.self) })
    }

    // MARK: - The safety net and the own requests

    // resetWorktree, only when the worktree of the PR has no change that no round made
    // (unknownChanges): a change of a person stays, and the next round stops with Needs you. A
    // failed read of the changes keeps the worktree too. The result is true when the reset ran.
    @discardableResult
    package func resetIfKnown(_ pr: PRKey, to newHead: CommitID? = nil) async -> Bool {
        guard let unknown = await unknownChanges(pr), unknown.isEmpty else {
            Self.logger.notice(
                """
                The copy of \(pr.text, privacy: .private) has changes that no round made, so \
                Bifrost keeps it as it is.
                """)
            return false
        }
        await resetWorktree(pr, to: newHead)
        return true
    }

    // At the end of the turn of a round: each change of the worktree of the PR is a change of the
    // round. A failed read keeps no change, so each change counts as a change of a person.
    package func markLeftovers(_ pr: PRKey) async {
        known[pr] = await stamps(pr) ?? [:]
    }

    // The changes in the worktree of the PR that no round made, sorted: each changed path that
    // Bifrost does not know (markLeftovers, a reset), or whose file changed since then. None when
    // the worktree is not in its place. nil when git fails.
    package func unknownChanges(_ pr: PRKey) async -> [String]? {
        let (path, folders, git) = (
            layout.worktree(pr.repo, number: pr.number).plainPath, folders, git
        )
        guard await BlockingExecutor.run({ folders.isFolder(path) && git.belongsToClone(pr) })
        else { return [] }
        guard let now = await stamps(pr) else { return nil }
        let before = known[pr] ?? [:]
        return now.filter { before[$0.key] != $0.value }.map(\.key).sorted()
    }

    // Each change of the worktree of the PR with the stamp of its file, or nil when git fails.
    private func stamps(_ pr: PRKey) async -> [String: PathStamp]? {
        guard let paths = await changedPaths(pr) else { return nil }
        let root = layout.worktree(pr.repo, number: pr.number).plainPath
        return await BlockingExecutor.run {
            Dictionary(uniqueKeysWithValues: paths.map { ($0, PathStamp(root + "/" + $0)) })
        }
    }

    // The commit that the worktree of the PR is at, or nil when git fails.
    package func worktreeHead(_ pr: PRKey) async -> CommitID? {
        let parsed = await git.run(.revParse("HEAD^{commit}"), in: .worktree(pr))
        return parsed.succeeded ? CommitID(parsed.stdout.trimmed()) : nil
    }

    // The commit that the worktree of the PR is at, and the head of the PR when that commit is
    // the merge with the markers of a conflict round (ConflictMerge.autoMessage, with the head and
    // the base as its parents): only the clone of Bifrost holds that merge. nil when git fails.
    package func worktreeCommit(_ pr: PRKey) async -> (commit: CommitID, conflictHead: CommitID?)? {
        guard let head = await worktreeHead(pr) else { return nil }
        let read = await git.run(.catFile(head.hex), in: .clone(pr.repo))
        guard read.succeeded, let object = CommitObject(read.stdout) else { return nil }
        let merge =
            object.parents.count == 2 && object.message.trimmed() == ConflictMerge.autoMessage
        return (head, merge ? object.parents.first : nil)
    }

    // Discard these changes: reset the worktree of the PR to the head and clean it
    // (resetWorktree). The result is true only when git reset the worktree.
    package func discard(_ pr: PRKey, to head: CommitID) async -> Bool {
        await reset(pr, to: head).didReset
    }

    // A commit of an own request that did not reach GitHub: HEAD and the index of the worktree go
    // back to the head, and the files stay, so the change of the user is in the worktree as
    // changes again. A worktree at the head stays as it is.
    package func uncommit(_ pr: PRKey, to head: CommitID) async {
        guard let now = await worktreeHead(pr), now != head else { return }
        let result = await git.run(.resetIndex(head), in: .worktree(pr))
        guard result.succeeded else {
            Self.logger.error(
                """
                Bifrost couldn't move the copy of \(pr.text, privacy: .private) back to its head. \
                \(Self.reason(result), privacy: .private)
                """)
            return
        }
        heads[pr] = head
    }

    // The own request file of the PR in its input folder (OwnRequestFile).
    package func ownRequestFile(_ pr: PRKey) -> URL {
        layout.inputFolder(pr.repo, number: pr.number).appending(
            path: OwnRequestFile.name, directoryHint: .notDirectory)
    }

    // True when an item is at the path of the own request file of the PR.
    package func hasOwnRequest(_ pr: PRKey) async -> Bool {
        let (path, folders) = (ownRequestFile(pr).plainPath, folders)
        return await BlockingExecutor.run { folders.exists(path) }
    }

    // Read the own request file of the PR, at most RequestResult.maxBytes. The read follows no
    // link.
    package func readOwnRequest(_ pr: PRKey) async -> ResultRead {
        await readResult(at: ownRequestFile(pr), limit: RequestResult.maxBytes)
    }

    // Remove the own request file of the PR. A link goes as a link. The result is true when an
    // item was there.
    @discardableResult
    package func removeOwnRequest(_ pr: PRKey) async -> Bool {
        let (path, folders) = (ownRequestFile(pr).plainPath, folders)
        let removed = await BlockingExecutor.run { () -> (there: Bool, failure: FileError?) in
            guard folders.exists(path) else { return (false, nil) }
            do throws(FileError) {
                try folders.remove(path)
            } catch {
                return (true, error)
            }
            return (true, nil)
        }
        if let failure = removed.failure {
            Self.logger.error("\(failure.message, privacy: .private)")
        }
        return removed.there
    }

    // Fetch the head of the PR (refs/pull/<n>/head) and its base branch into refs of Bifrost,
    // then read their commits and their merge base.
    package func fetchPR(_ pr: PRKey, base: BranchName) async throws(RepoError) -> FetchedPR {
        let head = "refs/bifrost/pr/\(pr.number)"
        let tip = "refs/bifrost/base/\(pr.number)"
        try await mustRun(.fetch(refspec: "+refs/pull/\(pr.number)/head:\(head)"), pr.repo)
        try await mustRun(.fetch(refspec: "+refs/heads/\(base.text):\(tip)"), pr.repo)
        let headCommit = try await commit(head + "^{commit}", pr.repo)
        let tipCommit = try await commit(tip + "^{commit}", pr.repo)
        let mergeBase = try await self.mergeBase(pr.repo, headCommit, tipCommit)
        return FetchedPR(head: headCommit, base: tipCommit, mergeBase: mergeBase)
    }

    // The merge base of two commits of the clone.
    package func mergeBase(_ repo: RepoName, _ first: CommitID, _ second: CommitID)
        async throws(RepoError) -> CommitID
    {
        let found = await git.run(.mergeBase(first, second), in: .clone(repo))
        guard found.succeeded, let commit = CommitID(found.stdout.trimmed()) else {
            throw .git(Self.prepareFailed + Self.reason(found))
        }
        return commit
    }

    // True when git finds the commit and it is an ancestor of the head (or the head). A commit
    // that git cannot find gives false.
    package func isAncestor(_ commit: CommitID, of head: CommitID, in repo: RepoName) async
        -> Bool
    {
        await git.run(.isAncestor(commit, of: head), in: .clone(repo)).succeeded
    }

    // The text of the diff between the two commits in the clone, or nil when it is longer than
    // the output limit of git.
    package func diff(_ repo: RepoName, from: CommitID, to: CommitID) async throws(RepoError)
        -> String?
    {
        let result = await git.run(.diff(from, to), in: .clone(repo))
        if result.end == .overflow { return nil }
        guard result.succeeded else { throw .git(Self.prepareFailed + Self.reason(result)) }
        return result.stdout
    }

    // The text of the diff between the two commits in the clone, only for the paths, or nil when
    // it is longer than the output limit of git.
    package func diff(_ repo: RepoName, from: CommitID, to: CommitID, paths: [String])
        async throws(RepoError) -> String?
    {
        let result = await git.run(.pathDiff(from, to, paths), in: .clone(repo))
        if result.end == .overflow { return nil }
        guard result.succeeded else { throw .git(Self.prepareFailed + Self.reason(result)) }
        return result.stdout
    }

    // Write the files in the input folder of the PR, each a new file with mode 0600.
    package func writeInput(_ pr: PRKey, _ files: [(name: String, data: Data)])
        async throws(RepoError)
    {
        let folder = layout.inputFolder(pr.repo, number: pr.number).plainPath
        let folders = folders
        try await self.files { () throws(FileError) in
            for file in files { try folders.writeNew(folder + "/" + file.name, file.data) }
        }
    }

    // Read the result file of the PR, at most limit bytes.
    package func readResult(_ pr: PRKey, limit: Int) async -> ResultRead {
        await readResult(
            at: layout.inputFolder(pr.repo, number: pr.number).appending(
                path: "result.json", directoryHint: .notDirectory),
            limit: limit)
    }

    // Read the result file of a round, at most limit bytes.
    package func readResult(at file: URL, limit: Int) async -> ResultRead {
        let path = file.plainPath
        return await BlockingExecutor.run { RepoFolders.readRegular(path, limit: limit) }
    }

    // The request of the PR went: its worktree and its input folder go, and git forgets the
    // worktree. The clone stays. A missing folder is no failure.
    package func removePR(_ pr: PRKey) async {
        heads[pr] = nil
        known[pr] = nil
        await dropWorktree(pr)
        let (input, folders) = (layout.inputFolder(pr.repo, number: pr.number).plainPath, folders)
        _ = try? await files { () throws(FileError) in try folders.remove(input) }
    }

    // MARK: - The steps

    nonisolated private static let prepareFailed =
        "Bifrost couldn't prepare its copy of the pull request: "

    // Remove the worktree folder of the PR, then let git forget it, when the clone is there.
    private func dropWorktree(_ pr: PRKey) async {
        let (path, folders) = (layout.worktree(pr.repo, number: pr.number).plainPath, folders)
        _ = try? await files { () throws(FileError) in try folders.remove(path) }
        if await hasClone(pr.repo) { _ = await git.run(.worktreePrune, in: .clone(pr.repo)) }
    }

    // The commit of the revision in the clone.
    private func commit(_ revision: String, _ repo: RepoName) async throws(RepoError) -> CommitID {
        let result = await git.run(.revParse(revision), in: .clone(repo))
        guard result.succeeded, let commit = CommitID(result.stdout.trimmed()) else {
            throw .git(Self.prepareFailed + Self.reason(result))
        }
        return commit
    }

    // Run the command in the clone of the repository. A failure throws its reason.
    private func mustRun(_ command: GitCommand, _ repo: RepoName) async throws(RepoError) {
        let result = await git.run(command, in: .clone(repo))
        guard result.succeeded else { throw .git(Self.prepareFailed + Self.reason(result)) }
    }

    // Run the file work on the blocking executor.
    private func files(_ work: @escaping @Sendable () throws(FileError) -> Void)
        async throws(RepoError)
    {
        do throws(FileError) {
            try await BlockingExecutor.run(work)
        } catch {
            throw .files(error)
        }
    }

    // Keep the result of a clone: a failure logs one line for the first failure of a row of
    // failures and starts the wait; a clone that works ends the row.
    private func record(_ repo: RepoName, _ result: Result<Void, RepoError>) {
        switch result {
        case .success:
            failures[repo] = nil
        case .failure(.cancelled):
            break
        case .failure(let failure):
            if failures[repo] == nil { log.record(.cloneFailed(repo, failure)) }
            failures[repo] = timeline.now()
        }
    }

    // The clone of the repository into a new temporary folder, then the move to its place. A
    // clone that is already in its place gives success. A folder at the place with no .git folder
    // (a removal that failed) goes first. A stop before git starts runs no git, and a stop
    // during git ends git, then the temporary folder goes.
    @concurrent private static func makeClone(
        _ repo: RepoName, from address: URL, git: RepoGit, folders: RepoFolders,
        layout: ReviewsLayout
    ) async -> Result<Void, RepoError> {
        guard !Task.isCancelled else { return .failure(.cancelled) }
        let clone = layout.clone(repo).plainPath
        let temp = clone + RepoFolders.cloning + UInt32.random(in: .min ... .max).hexText
        let prepared = await BlockingExecutor.run { () -> Result<Bool, FileError> in
            Result { () throws(FileError) -> Bool in
                if folders.isFolder(clone + "/.git") { return true }
                try folders.makeFolder((clone as NSString).deletingLastPathComponent)
                // An earlier run can stop during a clone and leave a temporary folder.
                try folders.removeTemporaryFolders(of: clone)
                try folders.makeFolder(temp)
                return false
            }
        }
        switch prepared {
        case .success(true): return .success(())
        case .success(false): break
        case .failure(let failure): return .failure(.files(failure))
        }
        let result: ExecResult
        if Task.isCancelled {
            result = ExecResult(.cancelled)
        } else {
            result = await git.run(
                .clone(address), in: .newClone(URL(filePath: temp, directoryHint: .isDirectory)))
        }
        let moved = await BlockingExecutor.run { () -> Result<Void, FileError> in
            Result { () throws(FileError) in
                guard result.succeeded else {
                    try folders.remove(temp)
                    return
                }
                try folders.remove(clone)
                try folders.rename(temp, to: clone)
            }
        }
        if result.end == .cancelled { return .failure(.cancelled) }
        guard result.succeeded else {
            return .failure(.git("Bifrost couldn't copy \(repo): \(reason(result))"))
        }
        return moved.mapError { .files($0) }
    }

    // The reason of a failed git command: the first line of its error, at most 200 characters.
    nonisolated static func reason(_ result: ExecResult) -> String {
        switch result.end {
        case .timedOut: return "git took too long."
        case .overflow: return "git gave too much output."
        case .cancelled: return "Bifrost stopped git."
        case .exited, .notStarted, .signal: break
        }
        let line = result.stderr.split(whereSeparator: \.isNewline).lazy
            .map { $0.trimmed() }.first { !$0.isEmpty }
        if let line { return String(line.prefix(200)) }
        if case .exited(let code) = result.end { return "git stopped with exit code \(code)." }
        return "git didn't finish."
    }
}

// MARK: - The file calls

// The file calls of the repo store on the folders below the repos folder. Each call runs on the
// thread of the caller, so the store runs them on the blocking executor.
struct RepoFolders: Sendable {
    // The repos folder, with no "/" at the end.
    let root: String

    private static let notOwned = FileError.other(
        "That folder isn't in Bifrost's reviews folder, so Bifrost left it alone.")
    private static let deleting = "~deleting"
    // The start of the end of the name of a temporary folder of a clone: <clone>~cloning-<hex>.
    // A repository name cannot hold "~", so this folder is never the clone of a repository.
    static let cloning = "~cloning-"

    // True when a folder (not a link) is at the path.
    func isFolder(_ path: String) -> Bool {
        var info = stat()
        return lstat(path, &info) == 0 && info.st_mode & S_IFMT == S_IFDIR
    }

    // True when an item is at the path. A link counts as an item, also when its target is gone.
    func exists(_ path: String) -> Bool {
        var info = stat()
        return lstat(path, &info) == 0
    }

    // True when the path is below the repos folder, before and after each link above its last
    // part resolves.
    func isOwned(_ path: String) -> Bool {
        let path = path.hasSuffix("/") ? String(path.dropLast()) : path
        guard path.hasPrefix(root + "/"), !path.split(separator: "/").contains("..") else {
            return false
        }
        let parent = (path as NSString).deletingLastPathComponent
        let real = Self.realOf(parent) + "/" + (path as NSString).lastPathComponent
        return real.hasPrefix(Self.realOf(root) + "/")
    }

    // Remove the item at the path and its content. A link goes, not the folder that it names. A
    // missing item is no failure.
    func remove(_ path: String) throws(FileError) {
        guard isOwned(path) else { throw Self.notOwned }
        var info = stat()
        guard lstat(path, &info) == 0 else { return }
        do {
            try FileManager.default.removeItem(atPath: path)
        } catch {
            throw FileError(error, call: .remove, path: path)
        }
    }

    // Remove each temporary folder of the clone (<clone>~cloning-...) and the folder
    // <clone>~cloning of an earlier version.
    func removeTemporaryFolders(of clone: String) throws(FileError) {
        let parent = (clone as NSString).deletingLastPathComponent
        let name = (clone as NSString).lastPathComponent
        guard isFolder(parent) else { return }
        let names: [String]
        do {
            names = try FileManager.default.contentsOfDirectory(atPath: parent)
        } catch {
            throw FileError(error, call: .read, path: parent)
        }
        let old = name + "~cloning"
        for entry in names where entry == old || entry.hasPrefix(name + Self.cloning) {
            try remove(parent + "/" + entry)
        }
    }

    // Make the folder and each missing folder above it, with mode 0700.
    func makeFolder(_ path: String) throws(FileError) {
        guard isOwned(path) || path == root else { throw Self.notOwned }
        do {
            try FileManager.default.createDirectory(
                atPath: path, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
        } catch {
            throw FileError(error, call: .createFolder, path: path)
        }
    }

    // Keep the folder and remove each item in it, then give it mode 0700. A link in it goes, not
    // the item that it names. When the item at the path is not a folder (a link or a file), it
    // goes, and a new folder takes its place. A missing folder is made.
    func emptyFolder(_ path: String) throws(FileError) {
        if !isFolder(path) {
            try remove(path)
            try makeFolder(path)
        }
        let names: [String]
        do {
            names = try FileManager.default.contentsOfDirectory(atPath: path)
        } catch {
            throw FileError(error, call: .read, path: path)
        }
        // Each removal checks again that its path is below the repos folder, after each link
        // above it resolves.
        for name in names { try remove(path + "/" + name) }
        try setPrivate(path)
    }

    // Give the folder mode 0700.
    func setPrivate(_ path: String) throws(FileError) {
        guard chmod(path, 0o700) == 0 else {
            throw .system(.setPermissions, path: path, code: errno)
        }
    }

    func rename(_ from: String, to: String) throws(FileError) {
        guard isOwned(from), isOwned(to) else { throw Self.notOwned }
        guard Darwin.rename(from, to) == 0 else {
            throw .system(.rename(to: to), path: from, code: errno)
        }
    }

    // Write a new file with mode 0600. The write follows no link and never replaces an item.
    func writeNew(_ path: String, _ data: Data) throws(FileError) {
        guard isOwned(path) else { throw Self.notOwned }
        let descriptor = open(path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw .system(.save, path: path, code: errno) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        do {
            try handle.write(contentsOf: data)
        } catch {
            throw FileError(error, call: .save, path: path)
        }
    }

    // The bytes of a regular file of at most limit bytes. The path can change after the lstat,
    // so the open follows no link and does not wait on a pipe, and the checks of the open file see
    // the real file. A file that grew past the limit is too large.
    static func readRegular(_ path: String, limit: Int) -> ResultRead {
        var info = stat()
        guard lstat(path, &info) == 0 else { return .missing }
        guard info.st_mode & S_IFMT == S_IFREG else { return .notRegular }
        guard info.st_size <= limit else { return .tooLarge }
        let descriptor = open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { return errno == ENOENT ? .missing : .notRegular }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG else {
            return .notRegular
        }
        let data: Data
        do {
            // nil: the file is empty.
            data = try handle.read(upToCount: limit + 1) ?? Data()
        } catch {
            return .missing
        }
        return data.count > limit ? .tooLarge : .data(data)
    }

    // Write the .git file of the worktree again: "gitdir: <admin folder>". A link or another
    // item at its path goes first, and the write makes a new file (O_EXCL), so it follows no
    // link.
    func writeGitFile(worktree: String, admin: String) throws(FileError) {
        let file = worktree + "/.git"
        try remove(file)
        let descriptor = open(file, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o644)
        guard descriptor >= 0 else { throw .system(.save, path: file, code: errno) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        do {
            try handle.write(contentsOf: Data("gitdir: \(admin)\n".utf8))
        } catch {
            throw FileError(error, call: .save, path: file)
        }
    }

    // Remove each item of the repos folder. A folder that an earlier removal left goes first, so
    // its name is free. A repos folder that is missing or is a link gives nothing to remove.
    func removeAll() throws(FileError) {
        guard isFolder(root) else { return }
        let names: [String]
        do {
            names = try FileManager.default.contentsOfDirectory(atPath: root)
        } catch {
            throw FileError(error, call: .read, path: root)
        }
        for name in names where name.hasSuffix(Self.deleting) { try remove(root + "/" + name) }
        for name in names where !name.hasSuffix(Self.deleting) {
            let gone = root + "/" + name + Self.deleting
            try rename(root + "/" + name, to: gone)
            try remove(gone)
        }
    }

    // The real path of the path: the real path of its longest part that is there, with the rest
    // of the path after it.
    private static func realOf(_ path: String) -> String {
        var rest: [String] = []
        var at = path
        while true {
            if let real = RealPath.of(at) {
                return ([real] + rest).joined(separator: "/")
            }
            let up = (at as NSString).deletingLastPathComponent
            if up == at || up.isEmpty { return path }
            rest.insert((at as NSString).lastPathComponent, at: 0)
            at = up
        }
    }
}

// The identity, the size and the change times of the item at a path (lstat), or a missing item.
// A write, a new file or a delete at the path gives another stamp. The safety net of the worktree
// compares them (RepoStore.unknownChanges).
struct PathStamp: Sendable, Equatable {
    let exists: Bool
    let mode: UInt16
    let device: Int64
    let inode: UInt64
    let size: Int64
    let modified: Int
    let modifiedNanoseconds: Int
    let changed: Int
    let changedNanoseconds: Int

    init(_ path: String) {
        var info = stat()
        exists = lstat(path, &info) == 0
        if !exists { info = stat() }
        mode = UInt16(info.st_mode)
        device = Int64(info.st_dev)
        inode = UInt64(info.st_ino)
        size = Int64(info.st_size)
        modified = info.st_mtimespec.tv_sec
        modifiedNanoseconds = info.st_mtimespec.tv_nsec
        changed = info.st_ctimespec.tv_sec
        changedNanoseconds = info.st_ctimespec.tv_nsec
    }
}

extension UInt32 {
    // The 8 hex digits of the number, in lower case.
    fileprivate var hexText: String {
        let digits = String(self, radix: 16)
        return String(repeating: "0", count: 8 - digits.count) + digits
    }
}
