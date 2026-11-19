// The PR lookup of Show Info (docs/behaviour/panels.md, "The PR lookup"). gh runs in the folder of
// the session and finds the PR of the branch of that folder itself. Thus no value of the row is an
// argument of gh. The cache is a dictionary of the class, keyed by the folder and the branch, with
// the Timeline time of each entry.
import BifrostFoundation
import Foundation

@MainActor
package final class PRLookup {
    // A good answer (a PR, or no PR) stays this long for one folder and one branch.
    nonisolated package static let goodCache = Duration.seconds(300)
    // A failure stays for a short time, so a fix shows soon, and gh does not run again at once.
    nonisolated package static let failCache = Duration.seconds(30)
    nonisolated package static let ghTimeout = Duration.seconds(10)
    nonisolated package static let ghArgs = ["pr", "view", "--json", "number,title,url,state"]
    // The time limit of the folder reads before a run of gh.
    nonisolated package static let folderLimit = Duration.seconds(2)
    // The longest reason line of gh, in characters.
    nonisolated static let reasonLimit = 200

    private struct Key: Hashable {
        let folder: String
        let branch: String
    }

    private struct Entry {
        let at: Duration
        let result: PRInfo
    }

    private let runner: any CommandRunner
    private let environment: [String: String]
    private let folders: FolderReads
    private let timeline: Timeline
    private var cache: [Key: Entry] = [:]
    // The run of each key that did not end. A second lookup of the key waits for the same run.
    private var running: [Key: Task<PRInfo, Never>] = [:]
    private var stopped = false

    // environment is the env of gh: the env of the claude runs, so gh is the gh of the login PATH.
    // skipRoots are the folders in which the lookup runs no gh (SkipRoots). A test gives a manual
    // clock, a fake folder read (fileKind) and a fake real path.
    package init(
        runner: any CommandRunner, environment: [String: String], skipRoots: [String],
        clock: any Clock<Duration>,
        fileKind: @escaping @Sendable (String) -> DirInfo.Kind = PRLookup.folderKind,
        realPath: @escaping @Sendable (String) -> String? = RealPath.of
    ) {
        self.runner = runner
        self.environment = environment
        folders = FolderReads(
            skipRoots: SkipRoots(skipRoots), clock: clock, fileKind: fileKind, realPath: realPath)
        timeline = Timeline(clock)
    }

    // The PR of the branch of the row. A row with no absolute folder or with no branch has no
    // PR, and the lookup runs nothing. The answer comes from the cache while it is fresh.
    package func pr(_ row: SessionRow) async -> PRInfo {
        guard let key = Self.key(of: row) else { return .none }
        if let entry = cache[key], Self.isFresh(entry, at: timeline.now()) { return entry.result }
        if let task = running[key] { return await task.value }
        guard !stopped else { return .unavailable(.failed) }
        let task = Task { await look(key) }
        running[key] = task
        return await task.value
    }

    // The address that a click on the PR of Show Info opens, or nil. A panel can stay open for
    // longer than the cache, so the click asks again: the cache gives the answer while it is
    // fresh, else gh runs again. Only an https address opens.
    package func urlToOpen(_ row: SessionRow) async -> URL? {
        guard case .pr(_, _, let url, _) = await pr(row), url.scheme == "https" else { return nil }
        return url
    }

    // Cancel each run of gh, and run gh no more. The runner stops a gh that runs. The owner calls
    // this at its stop.
    package func stop() {
        stopped = true
        for task in running.values { task.cancel() }
        running = [:]
    }

    // The PR of the output of gh. A good exit gives the PR when the JSON has each value with the
    // right type and an https address. Else the error of gh gives no PR or a reason. A gh that
    // does not start (it is not on the PATH, or it cannot run) is a gh that is not installed. An
    // output over the limit of the runner and a cancel give the fixed failure text, not the text
    // of the runner. The reason line is the first line of the error, with no hidden characters,
    // at most 200 characters.
    nonisolated package static func parse(_ result: ExecResult) -> PRInfo {
        if result.succeeded, let pr = readPR(result.stdout) { return pr }
        if result.stderr.range(of: "no pull requests found", options: .caseInsensitive) != nil {
            return .none
        }
        switch result.end {
        case .timedOut: return .unavailable(.timedOut)
        case .notStarted: return .unavailable(.notInstalled)
        case .overflow, .cancelled: return .unavailable(.failed)
        case .exited, .signal: break
        }
        let first = result.stderr.trimmed().split(whereSeparator: { $0 == "\n" || $0 == "\r\n" })
            .first.map(String.init) ?? ""
        let line = String(withoutHiddenCharacters(first).trimmed().prefix(reasonLimit))
        return .unavailable(line.isEmpty ? .failed : .gh(line))
    }

    // What is at the path for gh. A folder in which gh cannot start (no search permission) is
    // missing, so it gets the folder text, not the text of a gh that is not installed.
    nonisolated package static func folderKind(_ path: String) -> DirInfo.Kind {
        let kind = ProcessProbe.fileKind(path)
        guard kind == .dir else { return kind }
        return access(path, X_OK) == 0 ? .dir : .missing
    }

    // MARK: - The run

    // One run for the key: the folder reads, then gh. The answer goes into the cache, and the
    // entries that are not fresh go out, so the cache does not grow. The answer of a cancelled
    // run goes nowhere.
    private func look(_ key: Key) async -> PRInfo {
        let result = await answer(in: key.folder)
        running[key] = nil
        if Task.isCancelled { return .unavailable(.failed) }
        let now = timeline.now()
        cache = cache.filter { Self.isFresh($0.value, at: now) }
        cache[key] = Entry(at: now, result: result)
        return result
    }

    private func answer(in folder: String) async -> PRInfo {
        switch await folders.read(folder, skipRootCheck: true) {
        case .missing: return .unavailable(.noFolder)
        case .underSkipRoot: return .unavailable(.reviewSession)
        case .folder: break
        }
        let result = await runner.run(
            Command(
                "gh", Self.ghArgs, directory: folder, environment: environment,
                timeout: Self.ghTimeout))
        // gh also does not start when the folder went after the read, so the folder gets a
        // second read.
        if result.end == .notStarted,
            await folders.read(folder, skipRootCheck: false) == .missing
        {
            return .unavailable(.noFolder)
        }
        return Self.parse(result)
    }

    // The key of the row, or nil when gh can give no PR: a folder that is not absolute or holds
    // a NUL, or no branch. A branch that starts with "-" is not a git branch, so it counts as no
    // branch.
    nonisolated private static func key(of row: SessionRow) -> Key? {
        guard row.cwd.unicodeScalars.first == "/", !row.cwd.unicodeScalars.contains("\0"),
            let branch = row.branch, !branch.isEmpty, !branch.hasPrefix("-")
        else { return nil }
        return Key(folder: row.cwd, branch: branch)
    }

    nonisolated private static func isFresh(_ entry: Entry, at now: Duration) -> Bool {
        let life: Duration
        if case .unavailable = entry.result { life = failCache } else { life = goodCache }
        return now - entry.at < life
    }

    // The PR of the JSON of gh, or nil when a value is missing or has the wrong type. The number
    // is a whole number. The title and the state come from GitHub, so they lose their hidden
    // characters.
    nonisolated private static func readPR(_ text: String) -> PRInfo? {
        guard let value = try? JSONDecoder().decode(JSONValue.self, from: Data(text.utf8)),
            let fields = value.object, let number = fields["number"]?.wholeNumber,
            let address = fields["url"]?.string, address.hasPrefix("https://"),
            let url = URL(string: address), let title = fields["title"]?.string,
            let state = fields["state"]?.string
        else { return nil }
        return .pr(
            number: number, title: withoutHiddenCharacters(title), url: url,
            state: withoutHiddenCharacters(state))
    }
}

// The reads of a folder before a run of gh. The reads run in one task on the blocking executor
// and race the limit on the clock (BlockingExecutor.run(within:)). A read that does not end in
// the limit gives missing, for example on a network volume that is offline. The type is not
// isolated, so the closure of the reads is not isolated to the main actor.
private struct FolderReads: Sendable {
    enum Read: Sendable {
        case folder, missing, underSkipRoot
    }

    let skipRoots: SkipRoots
    let clock: any Clock<Duration>
    let fileKind: @Sendable (String) -> DirInfo.Kind
    let realPath: @Sendable (String) -> String?

    // What is at the path: a folder, a folder at or below a skip root (by the paths as they are
    // or by their real paths), or nothing that is a folder. skipRootCheck false: no read of the
    // real paths.
    func read(_ path: String, skipRootCheck: Bool) async -> Read {
        await BlockingExecutor.run(within: PRLookup.folderLimit, on: clock, else: .missing) {
            [fileKind, realPath, skipRoots] in
            guard fileKind(path) == .dir else { return .missing }
            guard skipRootCheck else { return .folder }
            return await skipRoots.contains(path) { realPath($0) } ? .underSkipRoot : .folder
        }
    }
}
