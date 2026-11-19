// The harness of the tests of the action runner, the dialogs and the row menu: the runner on the
// session commands with fake deps (FakeActionDeps: a real registry on fake session lists and a
// manual clock), the session input on the fake spawner with its own manual clock, the app actions
// on a fake opener and a fake clipboard, a layout, a selection, a dialog host and a UI store in a
// test folder. No test runs a program, opens an app or signals a process.
import AppKit
import BifrostChat
import BifrostFoundation
import BifrostLayout
import BifrostSessions
import BifrostSettings
import BifrostTestSupport
import Foundation
import Testing

@testable import BifrostWindows

// Session IDs whose first 8 characters are the short ID of their job, as for a job of claude.
let s1 = "f3a9c2d1-4b5e-4c6d-8e7f-0a1b2c3d4e5f"
let s2 = "0b1c2d3e-4f50-4a6b-8c7d-9e0f1a2b3c4d"
let s3 = "1c2d3e4f-5061-4b7c-9d8e-0f1a2b3c4d5e"
let newId = "4cb23c30-7283-4d9e-bfa0-2b3c4d5e6f70"
let short1: ShortID = "f3a9c2d1"
let short2: ShortID = "0b1c2d3e"

// The output of claude --bg for the start of the session newId.
let startedOutput = ExecResult(
    .exited(0), stdout: "backgrounded \u{B7} 4cb23c30 \u{B7} bifrost-test-n\n  hint line",
    stderr: "Starting background service\u{2026}")

// A worktree of Claude Code and its repository, and the commits of the fake git.
let repo = "/r"
let wt = "/r/.claude/worktrees/w1"
let baseCommit = String(repeating: "b", count: 40)
let headCommit = "f7698d38614ba22b41f996fab73124361d2fe389"

// The git of the worktree wt with one changed file and two commits that the main checkout does
// not have.
@Sendable
func worktreeGit(_ args: [String]) -> ExecResult {
    gitOfWorktree()(args)
}

// The git of the worktree wt with two commits that the main checkout does not have, the HEAD
// commit, and one changed file when changed is true. The count of the commits answers with HEAD
// and with the HEAD commit as the end of the range.
func gitOfWorktree(head: String = headCommit, changed: Bool = true)
    -> @Sendable ([String]) -> ExecResult
{
    { args in
        let stdout: String
        switch args {
        case ["--no-optional-locks", "-C", wt, "status", "--porcelain"]:
            stdout = changed ? " M a.txt\n" : ""
        case ["-C", wt, "rev-parse", "--abbrev-ref", "HEAD"]: stdout = "worktree-w1\n"
        case ["-C", repo, "rev-parse", "HEAD"]: stdout = "\(baseCommit)\n"
        case ["-C", wt, "rev-list", "--count", "\(baseCommit)..HEAD"]: stdout = "2\n"
        case ["-C", wt, "rev-list", "--count", "\(baseCommit)..\(head)"]: stdout = "2\n"
        case ["-C", wt, "rev-parse", "HEAD"]: stdout = "\(head)\n"
        default: return ExecResult(.exited(128))
        }
        return ExecResult(.exited(0), stdout: stdout)
    }
}

// The output of claude rm for the worktree wt with a commit on no remote: the kept line and the
// value that discards the commits, which starts with the HEAD commit.
func keptOutput(_ shortId: ShortID) -> ExecResult {
    let id = shortId.text
    let value = "\(headCommit)@598a160a880168020f78fdeda23f998a"
    let stdout = [
        "kept \(id) \u{2014} its worktree is still at \u{201C}\(wt)\u{201D}",
        "  1 unpushed commit on \u{201C}worktree-w1\u{201D}: f7698d3 \u{201C}test\u{201D}. It "
            + "exists on no remote, so deleting the worktree would lose it.",
        "  push it and run 'claude rm \(id)' again, or discard the worktree and its commits: "
            + "claude rm \(id) --discard-unpushed \(value)",
        "",
    ]
    return ExecResult(.exited(1), stdout: stdout.joined(separator: "\n"))
}

// A projects folder of Claude Code in a temporary folder, with a transcript that has a user
// message for each session ID, in the project of the folder /p.
func transcripts(_ ids: String...) throws -> TemporaryFolder {
    let temp = try TemporaryFolder()
    let project = temp.appending("-p")
    try FileManager.default.createDirectory(atPath: project, withIntermediateDirectories: false)
    for id in ids {
        try #"{"type":"user","message":{"role":"user","content":"hi"}}"#.appending("\n").write(
            toFile: "\(project)/\(id).jsonl", atomically: true, encoding: .utf8)
    }
    return temp
}

// The entries of the session lists.
enum Entry {
    static func short(_ id: String) -> ShortID? { ShortID(id.prefix(8)) }

    // A background session of the active list: an owned row that runs.
    static func running(
        _ id: String, cwd: String = "/p", pid: pid_t? = 4242, status: AgentStatus = .idle,
        waitingFor: String? = nil
    ) -> AgentEntry {
        AgentEntry(
            sessionId: id, cwd: cwd, isBackground: true, startedAt: 1, name: "bifrost-test-s",
            status: status, pid: pid, id: short(id), waitingFor: waitingFor)
    }

    // A stopped background session of the --all list: a parked row.
    static func stopped(_ id: String, cwd: String = "/p") -> AgentEntry {
        AgentEntry(
            sessionId: id, cwd: cwd, isBackground: true, startedAt: 1, name: "bifrost-test-s",
            id: short(id))
    }

    // An interactive session in another terminal: an external row.
    static func interactive(_ id: String, cwd: String = "/p", pid: pid_t? = 5151) -> AgentEntry {
        AgentEntry(
            sessionId: id, cwd: cwd, startedAt: 1, name: "bifrost-test-x", status: .idle, pid: pid)
    }
}

// The terminal model of a hidden attach. It gives no reply.
@MainActor
private final class QuietTerminal: HiddenTerminal {
    func feed(_ bytes: [UInt8]) -> [UInt8] { [] }
}

// The values that the runner reads from the test: the settings and the installed apps.
@MainActor
final class RunnerValues {
    var settings = BifrostSettings.Settings()
    var apps: [InstalledApp] = []
}

// One focus of the send box that the runner asked for.
struct SendBoxFocus: Equatable {
    let session: String
    let slash: Bool
}

@MainActor
final class ActionsHarness {
    let deps: FakeActionDeps
    let actions: SessionActions
    let spawner = FakeSpawner()
    // The clock of the session input. The test moves it.
    let inputClock = ManualClock()
    let ptys: PTYManager
    let input: SessionInput
    let opener = FakeOpener()
    let clipboard = FakeClipboard()
    let list = SessionListModel()
    let selection: SelectionModel
    let layout = WindowLayoutModel(layout: WindowLayout(bounds: LayoutSize(w: 1200, h: 800)))
    let folder: TemporaryFolder
    let store: UIStateStore
    let look = PanelLook()
    let dialogs: DialogHost
    let values = RunnerValues()
    let runner: ActionRunner
    // Each step of the Take control loader, with its session.
    private(set) var loaderSteps: [String] = []
    // Each focus of the send box that the runner asked for, with its session and slash, while no
    // Selected Item part takes them. A test that sets its own focus can record here too.
    private(set) var sendBoxFocuses: [SendBoxFocus] = []

    func record(_ focus: SendBoxFocus) {
        sendBoxFocuses.append(focus)
    }
    // The attaches of the chats that the test opened.
    private var chats: [PTYAttach] = []
    // The clock of the time limit of a hand-over.
    let handOverClock = ManualClock()

    // projects: the projects folder of the transcript check of Take control, or nil for a path
    // where no folder is. With chats, the runner gives the steps of the loader to them, and the
    // harness does not record the steps. confirmAll: false keeps the new rows of the first --all
    // list unconfirmed (FakeActionDeps.start). With handOver, the runner gets a hand-over on the
    // session input and the registry, with the projects folder, a rules file and a notes folder
    // in the folder of the harness, and the clock handOverClock.
    init(
        store registryStore: RegistryStore = RegistryStore(), active: [AgentEntry] = [],
        all: [AgentEntry] = [], projects: URL? = nil, chats: ChatTerminals? = nil,
        confirmAll: Bool = true, handOver: Bool = false
    ) async throws {
        UITestApp.prepare()
        deps = FakeActionDeps(store: registryStore, active: active, all: all)
        actions = deps.makeActions(projects: projects)
        let registry = deps.registry
        ptys = PTYManager(
            claude: ClaudeRunner(path: "/bin/claude", baseEnvironment: [:], runner: NoRunner()),
            spawner: spawner)
        input = SessionInput(
            ptys: ptys,
            sizes: SessionSizeReader(
                inspector: FakeProcessInspector(size: TerminalSize(cols: 97, rows: 41))),
            rows: { registry.rows }, makeTerminal: { _ in QuietTerminal() }, clock: inputClock,
            log: Recorder<SessionsLogEvent>())
        list.read(from: registry)
        selection = SelectionModel(list: list)
        folder = try TemporaryFolder()
        store = await UIStateStore.open(
            file: folder.url.appending(path: "ui-state.json"), clock: ManualClock(),
            log: Recorder<StoreEvent>())
        let rows = { registry.rows }
        let (opener, clipboard, values) = (opener, clipboard, values)
        let apps = AppActions(
            rows: rows, apps: { values.apps }, opener: opener, clipboard: clipboard)
        let terminals = TerminalLauncher(
            rows: rows, apps: { values.apps }, terminalOf: { _ in nil }, claudePath: { nil },
            runFolder: folder.url.appending(path: "run"), opener: opener, clipboard: clipboard,
            clock: deps.clock)
        dialogs = DialogHost(look: look, clock: deps.clock)
        dialogs.pickFolder = { _, _ in nil }
        var handOverRun: HandOver?
        if handOver {
            try Data("The rules.\n".utf8).write(to: folder.url.appending(path: "rules.md"))
            handOverRun = HandOver(
                input: input, registry: registry,
                projects: projects ?? folder.url.appending(path: "projects"),
                notes: folder.url.appending(path: "notes"),
                rules: folder.url.appending(path: "rules.md"), clock: handOverClock,
                now: Date.init)
        }
        runner = ActionRunner(
            actions: actions, input: input, registry: registry, apps: apps,
            terminals: terminals, layout: layout, selection: selection, chats: chats,
            dialogs: dialogs, uiState: store, settings: { values.settings },
            installedApps: { values.apps }, clock: deps.clock, handOver: handOverRun)
        if chats == nil {
            runner.loader = { [weak self] session, step in
                self?.loaderSteps.append("\(step) \(session)")
            }
        }
        runner.focusSendBox = { [weak self] session, slash in
            self?.sendBoxFocuses.append(SendBoxFocus(session: session, slash: slash))
        }
        await deps.start(confirmAll: confirmAll)
    }

    deinit { folder.remove() }

    var calls: FakeActionCalls { deps.calls }
    var clock: ManualClock { deps.clock }

    func row(_ id: String) -> SessionRow? { deps.row(id) }

    // True while the chat of the session is in a frame.
    func chatOpen(_ id: String) -> Bool {
        guard let session = SessionID(id) else { return false }
        return layout.layout.frame(of: .chat(session)) != nil
    }

    // Wait for the end of the last run of the runner that does its work later, within a limit
    // on the real clock.
    func settle(sourceLocation: SourceLocation = #_sourceLocation) async {
        guard let task = runner.lastTask else { return }
        await finish(task, sourceLocation: sourceLocation)
    }

    // Wait for the end of a task, within the limit. A task that does not end records an issue.
    func finish(
        _ task: Task<Void, Never>, within limit: Duration = testWaitLimit,
        sourceLocation: SourceLocation = #_sourceLocation
    ) async {
        let ended = await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                await task.value
                return true
            }
            group.addTask {
                try? await Task.sleep(for: limit)
                return false
            }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
        if !ended {
            Issue.record("The task did not end within \(limit).", sourceLocation: sourceLocation)
        }
    }

    // The confirmation that shows, after the wait for it.
    func confirmation(sourceLocation: SourceLocation = #_sourceLocation) async throws
        -> ConfirmDialogModel
    {
        await waitUntil(sourceLocation: sourceLocation) { dialogs.isOpen }
        guard case .confirm(let model) = dialogs.dialog else {
            Issue.record("No confirmation shows.", sourceLocation: sourceLocation)
            throw HarnessError.noDialog
        }
        return model
    }

    // The Rename dialog that shows.
    func renameDialog(sourceLocation: SourceLocation = #_sourceLocation) throws
        -> RenameDialogModel
    {
        guard case .rename(let model) = dialogs.dialog else {
            Issue.record("No Rename dialog shows.", sourceLocation: sourceLocation)
            throw HarnessError.noDialog
        }
        return model
    }

    // The New session dialog that shows.
    func newSessionDialog(sourceLocation: SourceLocation = #_sourceLocation) throws
        -> NewSessionDialogModel
    {
        guard case .newSession(let model) = dialogs.dialog else {
            Issue.record("No New session dialog shows.", sourceLocation: sourceLocation)
            throw HarnessError.noDialog
        }
        return model
    }

    // Open the attach of the chat of the session as a chat does, with one chunk of output 1.5 s
    // ago: the output is quiet, so a send types into it at once.
    func quietChat(_ id: String, shortId: ShortID) async throws {
        let session = try #require(SessionID(id))
        await input.chatOpening(chat: session)
        let attach = try await ptys.open(
            .test(.chat(session), shortId: shortId), size: TerminalSize(cols: 97, rows: 41))
        chats.append(try #require(attach))
        input.opened(chat: session, shortId: shortId)
        input.output(chat: session)
        inputClock.advance(by: .milliseconds(1500))
    }

    // Run the work of a send to its end: each time the session input sleeps, the clock of the
    // input moves to the next deadline.
    func drive(_ task: Task<Void, Never>, sourceLocation: SourceLocation = #_sourceLocation) async {
        let done = TaskEnd(task)
        for _ in 0..<20 {
            await waitUntil(sourceLocation: sourceLocation) {
                done.ended || inputClock.sleeperCount > 0
            }
            if done.ended { return }
            if let next = inputClock.nextDeadline {
                inputClock.advance(by: inputClock.now.duration(to: next))
            }
        }
        await finish(task, sourceLocation: sourceLocation)
    }

    // The text that the session got through the attach of its chat.
    var typed: String {
        spawner.fakes.flatMap(\.written).map { String(decoding: $0, as: UTF8.self) }.joined()
    }

    // Wait until a hand-over request is typed into the chat, and give its request ID.
    func typedRequest(sourceLocation: SourceLocation = #_sourceLocation) async -> String? {
        await HandOverLines.typedRequest(
            { typed }, inputClock: inputClock, sourceLocation: sourceLocation)
    }
}

enum HarnessError: Error {
    case noDialog
}
