import BifrostFoundation
import BifrostSessions
import Foundation
import OSLog

// The run that writes the drafts of the Daily update (docs/behaviour/daily-update.md, "The run").
// One run, in this order:
// 1. With no ticket source and no merged PRs there is nothing to read.
// 2. A new folder under runs/ with mode 0700, named by the UTC start time. The newest keptRuns
//    folders stay.
// 3. The merged PRs through gh, when the setting is on. A failure goes to the Event log, and the
//    run goes on with no PRs.
// 4. The probe of the MCP servers (InventoryReader). It comes after gh, so its tool list is as
//    new as it can be: the deny list of the run comes from it. A source that is not connected
//    fails, before claude runs.
// 5. input.json (mode 0600) in the folder, then claude -p in the folder with RunArgs.run and no
//    stdin. The run has no tool that writes.
// 6. The check of the output (RunResult).
//
// The owner starts one run at a time (DailyUpdateService). The whole run has a limit of 5 minutes
// on the clock; at the limit the run stops its program and fails with timeout. A cancel of the
// caller stops the run in the same way, and the run fails with stopped. A stopped run is no
// result: it writes no line. The run ends only after its programs ended, so a second run never
// starts while claude of the first still runs.
//
// report gets the start, the end and each failure, and the two notices of a run (the tool calls
// that the permissions refused, and the PRs that gh could not read). The app writes them to the
// Event log. The run never shows in the Overview: it is no session.
@MainActor
package final class DailyRunner {
    package static let limit = Duration.seconds(300)
    // The number of run folders to keep, the new one included.
    package static let keptRuns = 10

    // The short reasons of a claude failure that Bifrost found itself.
    static let notPrepared = "Bifrost couldn't prepare the run."
    static let noServers = "Bifrost couldn't read your MCP servers."
    static let signalled = "Something stopped it before it finished."

    private let claude: ClaudeRunner
    private let gh: GHCommand
    private let layout: DailyLayout
    private let skills: URL
    private let report: @MainActor (DailyRunEvent) -> Void
    private let clock: any Clock<Duration>
    private let calendar: Calendar
    private static let logger = Logger(bifrost: "daily-update")

    // skills is the skills plugin folder of the app. calendar gives the days and the time zone
    // of the periods of the areas; a test pins it.
    package init(
        claude: ClaudeRunner, gh: GHCommand, layout: DailyLayout, skills: URL,
        report: @escaping @MainActor (DailyRunEvent) -> Void, clock: any Clock<Duration>,
        calendar: Calendar = .autoupdatingCurrent
    ) {
        self.claude = claude
        self.gh = gh
        self.layout = layout
        self.skills = skills
        self.report = report
        self.clock = clock
        self.calendar = calendar
    }

    // Run with the settings and the state of now. The state gives the last send of each area.
    package func run(_ settings: DailySettings, state: DailyState, now: Date) async
        throws(RunFailure) -> DailyResult
    {
        report(.started)
        let (clock, limit) = (clock, Self.limit)
        // The draft and the limit race in one group: the first that ends wins, and the cancel of
        // the group stops the other. The cancel sends the kill signal to the program of the run,
        // and each program of the run waits for its end (Command.waitsForEnd): after a SIGTERM,
        // at most the grace and then SIGKILL. The group waits for the draft, so the run ends only
        // after its programs ended. A cancel of the caller cancels the group in the same way.
        let first = await withTaskGroup(of: Result<DailyResult, RunFailure>?.self) { group in
            group.addTask {
                await self.draftResult(settings, state: state, now: now)
            }
            // The limit gives nil, at its end or at a cancel.
            group.addTask {
                try? await clock.sleep(for: limit)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
        // No draft result: the limit came first, or the caller stopped the run.
        let outcome = first ?? .failure(Task.isCancelled ? .stopped : .timeout)
        switch outcome {
        case .success(let result):
            report(.finished)
            return result
        case .failure(.stopped):
            throw .stopped
        case .failure(let failure):
            report(.failed(failure))
            throw failure
        }
    }

    // MARK: - The steps

    // The draft as a value, so the group of the run can race it with the limit.
    private func draftResult(_ settings: DailySettings, state: DailyState, now: Date) async
        -> Result<DailyResult, RunFailure>
    {
        do throws(RunFailure) {
            return .success(try await draft(settings, state: state, now: now))
        } catch {
            return .failure(error)
        }
    }

    private func draft(_ settings: DailySettings, state: DailyState, now: Date) async
        throws(RunFailure) -> DailyResult
    {
        let server = settings.source.server
        if server == nil && !settings.mergedPrs { throw .nothingToRead }
        let folder: URL
        let skills: URL
        do throws(FileError) {
            (folder, skills) = try await RunFolders.prepare(
                layout, skills: self.skills, at: now, keep: Self.keptRuns)
        } catch {
            Self.logger.error(
                "Bifrost cannot prepare the Daily update run: \(error.message, privacy: .private)")
            throw .claudeFailed(Self.notPrepared)
        }
        try stopIfCancelled()
        let prs = try await mergedPRs(settings, state: state, now: now)
        let inventory = await InventoryReader(claude: claude).read(in: folder)
        try stopIfCancelled()
        guard let inventory else { throw .claudeFailed(Self.noServers) }
        if let status = Inventory.problem(of: server, in: inventory) {
            throw .sourceUnavailable(server: server, status: status)
        }
        let input = RunInput(
            settings: settings, state: state, now: now, calendar: calendar, prs: prs,
            tools: RunArgs.allowed(settings, inventory: inventory))
        let file = folder.appending(path: "input.json", directoryHint: .notDirectory)
        do throws(FileError) {
            try await RunFolders.write(input, to: file)
        } catch {
            Self.logger.error(
                "Bifrost cannot write the Daily update input: \(error.message, privacy: .private)")
            throw .claudeFailed(Self.notPrepared)
        }
        let args = RunArgs.run(
            input: file, folder: folder, skills: skills, settings: settings, inventory: inventory)
        let result = await claude.run(
            args, directory: folder.path(percentEncoded: false), timeout: Self.limit,
            killSignal: .terminate, waitsForEnd: true)
        try stopIfCancelled()
        return try read(result, input: input)
    }

    // The merged PRs since the earliest start of the areas, or none when the setting is off or
    // gh fails. A failure of gh goes to the Event log.
    private func mergedPRs(_ settings: DailySettings, state: DailyState, now: Date) async
        throws(RunFailure) -> [MergedPR]
    {
        guard settings.mergedPrs else { return [] }
        let since = RunInput.earliestSince(settings, state: state, now: now, calendar: calendar)
        let answer = await MergedPRsReader(gh: gh).read(since: since)
        try stopIfCancelled()
        switch answer {
        case .success(let prs):
            return prs
        case .failure(let error):
            report(.mergedPRsMissing(error))
            return []
        }
    }

    // The result of the output of claude.
    private func read(_ result: ExecResult, input: RunInput) throws(RunFailure) -> DailyResult {
        let output = Data(result.stdout.utf8)
        let reply = RunResult.reply(output)
        if let denials = reply?.denials, denials > 0 { report(.callsDenied(denials)) }
        switch result.end {
        case .exited(0) where RunResult.errorLine(reply) == nil:
            return try RunResult.check(output, input: input).get()
        case .timedOut: throw .timeout
        case .overflow: throw .badResult
        case .cancelled: throw .stopped
        default: throw .claudeFailed(Self.reason(of: result, reply: reply))
        }
    }

    // The short reason of a failed claude: a fixed text for a signal, then the reason of an
    // error reply, then the text of the output. A JSON reply with no error reason is no text for
    // the user, so the reason does not use it.
    static func reason(of result: ExecResult, reply: ClaudeReply?) -> String {
        if case .signal = result.end { return signalled }
        if let line = RunResult.errorLine(reply) {
            return ClaudeOutput.claudeFailure(ExecResult(result.end, stdout: line)).message
        }
        let stdout = reply == nil ? result.stdout : ""
        return ClaudeOutput.claudeFailure(
            ExecResult(result.end, stdout: stdout, stderr: result.stderr)
        ).message
    }

    private func stopIfCancelled() throws(RunFailure) {
        if Task.isCancelled { throw .stopped }
    }
}

// The folders of the runs: runs/<UTC start time>, for example runs/20261118-093000, with mode
// 0700. The names sort in the order of time. A name that is taken gets a number: -2, -3 and so
// on. Only the folders with such a name are removed, never the new one.
enum RunFolders {
    private static let maxTries = 100
    private static let logger = Logger(bifrost: "daily-update")

    // Make the Daily update folder and runs/ (mode 0700), and a new folder for a run at now.
    // Remove the oldest run folders, so keep folders stay. Give the real paths of the new folder
    // and of the skills folder.
    @concurrent static func prepare(
        _ layout: DailyLayout, skills: URL, at now: Date, keep: Int
    ) async throws(FileError) -> (folder: URL, skills: URL) {
        try await BlockingExecutor.run { () throws(FileError) -> (folder: URL, skills: URL) in
            try PrivateFolder.make(layout.folder)
            try PrivateFolder.make(layout.runsFolder)
            let run = try newFolder(in: layout.runsFolder, base: name(at: now))
            prune(layout.runsFolder, keeping: run, keep: keep)
            let folder = layout.runsFolder.appending(path: run, directoryHint: .isDirectory)
            return (try realFolder(folder), try realFolder(skills))
        }
    }

    // Write the input file with mode 0600.
    @concurrent static func write(_ input: RunInput, to file: URL) async throws(FileError) {
        try await BlockingExecutor.run { () throws(FileError) in
            do {
                try JSONFile.write(JSONFile.encode(input), to: file)
            } catch {
                throw FileError(error, call: .save, path: file.path(percentEncoded: false))
            }
        }
    }

    // The name of the folder of a run at the time: its UTC date and time.
    static func name(at date: Date) -> String {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = .gmt
        let parts = utc.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        return String(
            format: "%04d%02d%02d-%02d%02d%02d", parts.year ?? 0, parts.month ?? 0,
            parts.day ?? 0, parts.hour ?? 0, parts.minute ?? 0, parts.second ?? 0)
    }

    // True for the name of a run folder.
    static func isRunName(_ name: String) -> Bool {
        name.wholeMatch(of: /\d{8}-\d{6}(-\d+)?/) != nil
    }

    private static func newFolder(in runs: URL, base: String) throws(FileError) -> String {
        for number in 1...maxTries {
            let name = number == 1 ? base : "\(base)-\(number)"
            let path = runs.appending(path: name).path(percentEncoded: false)
            if mkdir(path, 0o700) == 0 {
                // The mask of the process can take bits away, never add them.
                if chmod(path, 0o700) != 0 {
                    throw .system(.setPermissions, path: path, code: errno)
                }
                return name
            }
            let code = errno
            if code != EEXIST { throw .system(.createFolder, path: path, code: code) }
        }
        throw .other("Bifrost found no free name for the run folder.")
    }

    // Remove the oldest run folders, so keep folders stay with the new one. A failure goes to the
    // log only: the run goes on.
    private static func prune(_ runs: URL, keeping current: String, keep: Int) {
        let manager = FileManager.default
        let path = runs.path(percentEncoded: false)
        do {
            let names = try manager.contentsOfDirectory(atPath: path)
                .filter { $0 != current && isRunName($0) }.sorted()
            for name in names.dropLast(max(keep - 1, 0)) {
                try manager.removeItem(at: runs.appending(path: name))
            }
        } catch {
            let reason = ErrorText.of(error)
            logger.error(
                "Bifrost cannot remove old Daily update run folders: \(reason, privacy: .private)")
        }
    }

    // The real path of a folder, or a failure when nothing is there.
    private static func realFolder(_ folder: URL) throws(FileError) -> URL {
        let path = folder.path(percentEncoded: false)
        guard let real = RealPath.of(path) else { throw .system(.check, path: path, code: ENOENT) }
        return URL(filePath: real, directoryHint: .isDirectory)
    }
}
