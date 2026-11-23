// The action runner (docs/behaviour/actions.md, "The action runner"): it runs the plan of a
// session action (RunPlan) for the row of now. It asks with the confirm dialog first where the
// plan has a confirmation, runs the command of the action, and shows the result in the notice
// line or the error line. It also gives the context that the action model needs, and the steps
// that the dialogs and the row menu use.
//
// - Each run reads the row by its ID at the time of the run, so a menu or a button that shows an
//   old row never acts on it. An action that is off for the row of now plans none and does
//   nothing.
// - The running set holds each session with a call that did not end. The session commands also
//   lock a session (SessionActions.isRunning), and the context counts both.
// - A notice shows for messageTime. An error stays until closeError or the next error. While a
//   Delete runs, its notice stays and a new notice waits (DeleteNotices). While a session command
//   checks the active list before it decides (SessionActions.isCheckingSessions), the notice line
//   says so, over any other notice.
// - Hand over runs the hand-over of the shell (HandOver) while the session counts as running.
//   After a good hand-over, the chat of the old session shows the new session, the new row is
//   selected, and the old session parks after a check of its real state (HandOver.checkPark).
// - Only the quit of the app stops a command that runs (SessionActions.stop). The UI never cancels
//   one.
// - New session (beginSession) ends for its dialog when the start is accepted, so the dialog
//   closes at once. The rest of the start runs in a task of the runner. Until the session list
//   has the row of the start, the Overview shows the start as a Starting row (starting). At the
//   end, a good start selects the new row and opens its chat, and a failed start shows its
//   reason in the error line.
// - The runner owns each task of its runs. A task leaves the list at its end, and stop() at the
//   quit cancels the tasks that did not end.
import BifrostChat
import BifrostFoundation
import BifrostLayout
import BifrostSessions
import BifrostSettings
import Foundation
import Observation

// A step of the Take control loader of a chat. start: the call starts. stop: the call failed.
// finish: the call worked, and the loader waits for the first output of the chat.
package enum LoaderStep: Sendable, Equatable {
    case start, stop, finish
}

@MainActor
@Observable
package final class ActionRunner {
    // The time of a notice.
    package static let messageTime = Duration.seconds(5)
    // The notice while the check for unmerged work of a Delete runs.
    package static let checkingNotice = "Checking for unmerged work..."
    // The notice while a Delete runs after the confirmation.
    package static let deletingNotice = "Deleting the session..."
    // The notice while Resume, Resume all or Delete checks the active list before it decides.
    package static let checkingSessionsNotice = "Checking sessions..."
    // The notice when a dialog cannot open, because another dialog is open.
    package static let busyNotice = "Another dialog is open. Finish that one first."
    // The notice while a hand-over waits for its note. The wait can take some minutes.
    package static let handOverNotice = "Writing the hand-over note..."
    // The start of the error when the old session does not park after a good hand-over.
    package static let parkFailedNotice =
        "The new session started, but Bifrost couldn't park the old one."

    @ObservationIgnored private let actions: SessionActions
    @ObservationIgnored private let input: SessionInput
    @ObservationIgnored private let registry: RegistryService
    @ObservationIgnored private let apps: AppActions
    @ObservationIgnored private let terminals: TerminalLauncher
    @ObservationIgnored private let layout: WindowLayoutModel
    @ObservationIgnored package let selection: SelectionModel
    @ObservationIgnored private let chats: ChatTerminals?
    @ObservationIgnored package let dialogs: DialogHost
    @ObservationIgnored private let uiState: UIStateStore
    @ObservationIgnored private let settings: () -> Settings
    @ObservationIgnored private let installedApps: () -> [InstalledApp]
    // nil: Hand over does nothing.
    @ObservationIgnored private let handOver: HandOver?

    private let errorLine: TimedLine
    private let noticeLine: TimedLine
    @ObservationIgnored private var notices = DeleteNotices(deletingText: deletingNotice)
    @ObservationIgnored private var errorCount = 0
    // The sessions with a call of this runner that did not end.
    private var running: Set<String> = []
    // The New session starts that run after the close of their dialog, in their order.
    package private(set) var starting: [StartingSession] = []
    @ObservationIgnored private var startCount = 0
    // True from a click on Resume all until its end, so a second click does nothing.
    private var resumingAll = false

    // Focus the send box of the Selected Item panel for the session, after Send message (false)
    // or Run slash command (true) opened the panel. The Selected Item part sets it when it makes
    // its model (SelectedItemPanels). The panel opens at once, so the send box of the session
    // shows when the call comes.
    @ObservationIgnored package var focusSendBox: (_ sessionId: String, _ slash: Bool) -> Void = {
        _, _ in
    }
    // The steps of the Take control loader of each chat. With the chats, the init gives each
    // step to them, and the chat body shows the loader. A test can record the steps here.
    @ObservationIgnored package var loader: (String, LoaderStep) -> Void = { _, _ in }
    // The tasks of the runs that did not end, by number.
    @ObservationIgnored private var tasks: [Int: Task<Void, Never>] = [:]
    @ObservationIgnored private var taskCount = 0
    #if DEBUG
    // The task of the last run that does its work later (a send, a call or Resume all). A test
    // and the debug test port wait for it.
    @ObservationIgnored package private(set) var lastTask: Task<Void, Never>?
    #endif

    // settings gives the settings of now, and installedApps the installed apps of Open project
    // (ProjectApps.projectApps). The runner reads them at each run on the main actor, so the app
    // gives a list that it found off the main actor, not a new search of the files. The lines
    // use the clock. handOver is the hand-over that the Hand over action runs.
    package init(
        actions: SessionActions, input: SessionInput, registry: RegistryService,
        apps: AppActions, terminals: TerminalLauncher, layout: WindowLayoutModel,
        selection: SelectionModel, chats: ChatTerminals?, dialogs: DialogHost,
        uiState: UIStateStore, settings: @escaping () -> Settings,
        installedApps: @escaping () -> [InstalledApp], clock: any Clock<Duration>,
        handOver: HandOver? = nil
    ) {
        self.actions = actions
        self.input = input
        self.registry = registry
        self.apps = apps
        self.terminals = terminals
        self.layout = layout
        self.selection = selection
        self.chats = chats
        self.dialogs = dialogs
        self.uiState = uiState
        self.settings = settings
        self.installedApps = installedApps
        self.handOver = handOver
        errorLine = TimedLine(time: Self.messageTime, clock: clock)
        noticeLine = TimedLine(time: Self.messageTime, clock: clock)
        if let chats {
            loader = { [weak chats] sessionId, step in
                switch step {
                case .start: chats?.startLoader(sessionId)
                case .stop: chats?.stopLoader(sessionId)
                case .finish: chats?.finishLoader(sessionId)
                }
            }
        }
    }

    // MARK: - The lines

    // The text of the last failed action, or nil. It stays until closeError or the next error.
    package var error: String? { errorLine.text }

    // The notice of an action, or nil.
    package var notice: String? {
        actions.isCheckingSessions ? Self.checkingSessionsNotice : noticeLine.text
    }

    #if DEBUG
    // The task of the timer of the notice line, or nil. A test waits for it.
    package var noticeTimer: Task<Void, Never>? { noticeLine.timerTask }
    #endif

    package func closeError() {
        errorLine.clear()
    }

    // A dialog could not open, because another dialog is open.
    package func dialogBusy() {
        notify(Self.busyNotice)
    }

    // MARK: - The context

    // The row of the session now, or nil.
    package func row(_ sessionId: String) -> SessionRow? {
        registry.rows.first { $0.sessionId == sessionId }
    }

    // The history of the dialogs and of the slash commands.
    package var history: History { uiState.state.dialogHistory }

    // The labels of the settings now.
    package var labels: LabelSet { settings().labels }

    package func context(_ sessionId: String) -> ActionContext {
        let rows = registry.rows
        let row = rows.first { $0.sessionId == sessionId }
        let settings = settings()
        // The Delete of a row with a short ID and a sharer keeps the folder (folderSharer).
        let shared = row.map { $0.shortId != nil && folderSharer(of: $0, in: rows) != nil }
        return ActionContext(
            chatOpen: chatOpen(sessionId), folderShared: shared ?? false,
            apps: installedApps().map(\.app), labels: settings.labels,
            running: isRunning(sessionId),
            slashFavourites: settings.slashCommands, slashRecent: history.recentSlash)
    }

    // True while a call of this runner on the session did not end, or while a session command
    // locks the session.
    package func isRunning(_ sessionId: String) -> Bool {
        running.contains(sessionId) || actions.isRunning(sessionId)
    }

    package var globalContext: GlobalContext {
        GlobalContext(
            resumable: registry.rows.filter(\.resumable).count,
            resumeAllRunning: resumingAll || actions.resumeAllRunning, labels: settings().labels)
    }

    // The app of Open project with no menu choice, for the key of Open project. nil when no
    // installed app can be the default (Settings.defaultProjectApp).
    package var defaultProjectApp: ProjectAppID? {
        settings().defaultProjectApp(installedApps().map(\.app))
    }

    // MARK: - The runs

    // Run the action on the session, with the choice of a menu.
    package func run(_ id: ActionID, _ sessionId: String, arg: MenuArg? = nil) {
        let row = row(sessionId)
        let ctx = context(sessionId)
        switch RunPlan.plan(id, row, ctx, arg: arg) {
        case .none:
            break
        case .openChat:
            layout.openChat(sessionId)
        case .closeChat:
            if let session = SessionID(sessionId) { layout.apply(.close(.chat(session))) }
        case .showInfo(let session):
            layout.apply(.open(.showInfo(session)))
        case .focusSend(let slash):
            selection.selectedId = sessionId
            layout.apply(.open(.selectedItem))
            focusSendBox(sessionId, slash)
        case .send(let text):
            start { [weak self] in
                do throws(ActionRefusal) {
                    try await self?.send(sessionId, text)
                } catch {
                    self?.fail(error)
                }
            }
        case .rename:
            if let row { dialogs.rename(row, runner: self) }
        case .call(let call, let confirm, let after):
            guard let row else { return }
            let shared = ctx.folderShared
            // The mark is on at once, so a second click sees the session as running. Only the
            // call that set the mark removes it.
            let owns = running.insert(sessionId).inserted
            start { [weak self] in
                await self?.runCall(
                    call, confirm: confirm, after: after, row, folderShared: shared, owns: owns)
            }
        }
    }

    package func runGlobal(_ id: GlobalActionID) {
        switch id {
        case .newSession:
            dialogs.newSession(runner: self)
        case .resumeAll:
            guard ActionModel.globalState(.resumeAll, globalContext).enabled else { return }
            resumingAll = true
            start { [weak self] in
                await self?.resumeAll()
                self?.resumingAll = false
            }
        }
    }

    // The quit: the tasks of the runs that did not end get a cancel. A command that runs stops
    // through SessionActions.stop.
    package func stop() {
        for task in tasks.values { task.cancel() }
        tasks = [:]
    }

    // Start the work of a run in a task that the runner owns. The task leaves the list at its
    // end. last: the task is the last run that a test waits for (lastTask). The open of the
    // worktree of a Delete dialog is not: the Delete itself still runs.
    private func start(last: Bool = true, _ work: @escaping @MainActor () async -> Void) {
        taskCount += 1
        let number = taskCount
        let task = Task { [weak self] in
            await work()
            self?.tasks[number] = nil
        }
        tasks[number] = task
        #if DEBUG
        if last { lastTask = task }
        #endif
    }

    // Type the text into the session. A /rename clears the local name, and a slash command goes
    // into the recent slash commands (RenameRules.afterSend).
    package func send(_ sessionId: String, _ text: String) async throws(ActionRefusal) {
        do throws(InputRefusal) {
            try await input.send(sessionId, text)
        } catch {
            throw .input(error)
        }
        let after = RenameRules.afterSend(text)
        // A failed clear changes nothing.
        if after.clearAlias { _ = registry.setAlias(sessionId, nil) }
        if after.rememberSlash { changeHistory { $0.rememberingSlash(text) } }
    }

    // Link the Overviews to the runner: a double-click on a row runs Open, a right-click shows
    // the row menu on the Bifrost menu, and the starts of New session show as Starting rows.
    package func attach(_ overviews: OverviewModel, menu: BifrostMenu) {
        overviews.open = { [weak self] in self?.run(.open, $0) }
        overviews.starting = { [weak self] in self?.starting ?? [] }
        overviews.showRowMenu = { [weak self, weak menu] row, point, view in
            guard let self, let menu else { return }
            RowMenu.show(row, at: point, in: view, runner: self, menu: menu)
        }
    }

    // MARK: - The steps of the dialogs

    // The folder check of the New session dialog.
    package func dirInfo(_ path: String) async -> DirInfo {
        await actions.dirInfo(path)
    }

    // The folders of the New session dialog.
    package var recentDirectories: [String] {
        history.recentDirectories(registry.rows)
    }

    // Start a new session and wait for its end, for Hand over. The result is the row ID of the
    // new session.
    package func startSession(_ spec: NewSessionSpec) async throws(ActionRefusal) -> String {
        guard case .created(let sessionId) = try await actions.run(.create(spec)) else {
            throw .startGaveNoId
        }
        return sessionId
    }

    // Start a new session for the New session dialog. The call ends when the start is accepted
    // (StartStep.accepted), or with the refusal before that step, so the dialog can close at
    // once. The rest of the start runs in a task of the runner (runStart).
    package func beginSession(_ spec: NewSessionSpec) async throws(ActionRefusal) {
        startCount += 1
        let number = startCount
        let result = await withCheckedContinuation { continuation in
            let acceptance = StartAcceptance(continuation)
            start { [weak self] in
                await self?.runStart(spec, number: number, acceptance)
                // A runner that went away also ends the wait. A second end does nothing.
                acceptance.end(.failure(.cancelled))
            }
        }
        try result.get()
    }

    // The start of beginSession. At the acceptance, the start goes into starting and the dialog
    // gets its end. claude --bg then gives the short ID of the start, and the Overview shows the
    // real row in place of the Starting row as soon as the session list has it. At the end, the
    // start leaves starting. A refusal before the acceptance goes to the dialog. A failure after
    // it goes to the error line.
    private func runStart(_ spec: NewSessionSpec, number: Int, _ acceptance: StartAcceptance)
        async
    {
        let sessionId: String
        do throws(ActionRefusal) {
            sessionId = try await actions.newSession(spec) { [weak self] step in
                switch step {
                case .accepted:
                    self?.starting.append(
                        StartingSession(id: number, name: spec.name, cwd: spec.cwd))
                    acceptance.end(.success(()))
                case .launched(let shortId):
                    self?.launched(number, shortId)
                }
            }
        } catch {
            starting.removeAll { $0.id == number }
            if acceptance.isWaiting {
                acceptance.end(.failure(error))
            } else {
                showError(Self.startFailedText(name: spec.name, error))
            }
            return
        }
        starting.removeAll { $0.id == number }
        sessionStarted(spec, sessionId: sessionId)
    }

    // claude --bg gave the short ID of the start with the number.
    private func launched(_ number: Int, _ shortId: ShortID) {
        guard let index = starting.firstIndex(where: { $0.id == number }) else { return }
        starting[index].shortId = shortId
    }

    // The text of the error line when a start fails after its dialog closed.
    package static func startFailedText(name: String, _ error: ActionRefusal) -> String {
        "\(name) didn't start. \(error.message)"
    }

    // After a good start: the history keeps the folder, the model and the mode, the new row is
    // selected, and its chat opens.
    private func sessionStarted(_ spec: NewSessionSpec, sessionId: String) {
        changeHistory {
            $0.remembering(cwd: spec.cwd, model: spec.model, mode: spec.permissionMode)
        }
        selection.selectedId = sessionId
        layout.openChat(sessionId)
    }

    // Set or clear the local name of the session.
    package func setAlias(_ sessionId: String, _ alias: String?) throws(ActionRefusal) {
        guard registry.setAlias(sessionId, alias) else { throw .unknownSession }
    }

    // MARK: - The calls

    // The answer of the Delete dialog: no, or yes with the counts that the dialog showed.
    private enum DeleteAnswer {
        case cancelled
        case confirmed(SeenCounts?)
    }

    // Run one call. Delete runs the check for unmerged work first and asks with its result. Take
    // control and Delete get confirmed: true only after a click on the confirm button. owns is
    // true when this call set the running mark of the session.
    private func runCall(
        _ call: ApiCall, confirm: ConfirmText?, after: AfterCall, _ row: SessionRow,
        folderShared: Bool, owns: Bool
    ) async {
        let sessionId = row.sessionId
        var deleting = false
        defer {
            if deleting {
                notices.endDelete()
                applyNotices()
            }
            if owns { running.remove(sessionId) }
        }
        do throws(ActionRefusal) {
            var confirmed = false
            var seen: SeenCounts?
            if call == .remove {
                guard case .confirmed(let counts) = await askDelete(row, folderShared: folderShared)
                else { return }
                (confirmed, seen) = (true, counts)
            } else if let confirm {
                confirmed = await dialogs.confirm(confirm, openFolder: nil) { dialogBusy() }
                guard confirmed else { return }
            }
            switch call {
            case .remove:
                notices.startDelete()
                applyNotices()
                deleting = true
                _ = try await actions.run(.remove(sessionId, confirmed: confirmed, seen: seen))
            case .handOver:
                await runHandOver(row)
            default:
                try await runOther(call, sessionId, confirmed: confirmed)
            }
            switch after {
            case .closeChat: closeChat(sessionId)
            case .restartChat: chats?.terminal(sessionId)?.restart()
            case .none: break
            }
            // The restart comes first, so an ended chat waits again. The chat does not attach while
            // Take control runs. The finish makes it attach to the moved session. Its first output
            // ends the loader.
            if call == .takeControl { loader(sessionId, .finish) }
        } catch {
            fail(error)
            // A failed Delete closes the chat when the row went (a failed deferred claude rm).
            if deleting, RunPlan.afterFailedDelete(sessionId, rows: registry.rows) == .closeChat {
                closeChat(sessionId)
            }
        }
    }

    // The check for unmerged work and the confirmation of a Delete. A folder that another
    // session uses stays, so it gets no check. The folder can stop being shared while the dialog
    // shows: the Delete then runs claude rm, so the Delete runs the check and asks again with the
    // work that the check finds.
    private func askDelete(_ row: SessionRow, folderShared: Bool) async -> DeleteAnswer {
        let sessionId = row.sessionId
        var shared = folderShared
        while true {
            var check = DeleteCheck.shared
            var seen: SeenCounts?
            if !shared {
                let checking = notices.showUntilHidden(Self.checkingNotice)
                applyNotices()
                let result = await actions.deleteCheck(sessionId)
                notices.hide(checking)
                applyNotices()
                check = result.map(DeleteCheck.checked) ?? .failed
                seen = result.flatMap(SeenCounts.init)
            }
            let now = self.row(sessionId) ?? row
            guard let text = Confirm.text(.delete(check), now, labels) else { return .cancelled }
            let openFolder: (() -> Void)? =
                text.openFolder == nil ? nil : { [weak self] in self?.openWorktree(sessionId) }
            guard await dialogs.confirm(text, openFolder: openFolder, onBusy: { dialogBusy() })
            else { return .cancelled }
            guard shared, !context(sessionId).folderShared else { return .confirmed(seen) }
            shared = false
        }
    }

    // The calls other than Delete.
    private func runOther(_ call: ApiCall, _ sessionId: String, confirmed: Bool)
        async throws(ActionRefusal)
    {
        switch call {
        case .interrupt:
            do throws(InputRefusal) {
                try await input.interrupt(sessionId)
            } catch {
                throw .input(error)
            }
        case .stop:
            _ = try await actions.run(.stop(sessionId))
        case .resume:
            _ = try await actions.run(.resume(sessionId))
        case .takeControl:
            // The chat opens at once with the loader, and the row is selected. A failure ends the
            // loader and closes the chat.
            selection.selectedId = sessionId
            loader(sessionId, .start)
            layout.openChat(sessionId)
            do throws(ActionRefusal) {
                _ = try await actions.run(.takeControl(sessionId, confirmed: confirmed))
            } catch {
                loader(sessionId, .stop)
                if let session = SessionID(sessionId) { layout.apply(.close(.chat(session))) }
                throw error
            }
        case .openInTerminal:
            if let notice = try await terminals.openInTerminal(sessionId) { notify(notice) }
        case .setPriority(let priority):
            guard registry.setPriority(sessionId, priority) else { throw .unknownSession }
        case .watchAdd(let colour):
            guard registry.watchAdd(sessionId, colour) else { throw .unknownSession }
        case .watchColour(let colour):
            guard registry.watchColour(sessionId, colour) else { throw .unknownSession }
        case .watchRemove:
            guard registry.watchRemove(sessionId) else { throw .unknownSession }
        case .copyId:
            try apps.copySessionId(sessionId)
        case .openProject(let app):
            try await apps.openProject(sessionId, app)
        // runCall runs these.
        case .handOver, .remove:
            break
        }
    }

    // Hand over (docs/behaviour/actions.md, "Hand over"). The notice line shows that the note is
    // on its way until the hand-over ends, and a failure shows its text in the error line. After
    // a good hand-over, the chat of the old session shows the new session and the new row is
    // selected. Then the hand-over confirms the real state of the old session. Only when each
    // check passes does the old session park, and then the notice line names the new session.
    // A failed check leaves the old session as it is and shows the reason in the error line.
    private func runHandOver(_ row: SessionRow) async {
        guard let handOver else { return }
        let sessionId = row.sessionId
        let writing = notices.showUntilHidden(Self.handOverNotice)
        applyNotices()
        let done: HandOverDone
        do throws(HandOverFailure) {
            done = try await handOver.run(row) { spec throws(ActionRefusal) in
                try await startSession(spec)
            }
        } catch {
            notices.hide(writing)
            applyNotices()
            showError(error.message)
            return
        }
        notices.hide(writing)
        applyNotices()
        if chatOpen(sessionId), let old = SessionID(sessionId), let new = SessionID(done.sessionId)
        {
            layout.apply(.replace(.chat(old), with: .chat(new)))
        }
        selection.selectedId = done.sessionId
        do throws(ParkRefusal) {
            try await handOver.checkPark(sessionId, after: done)
        } catch {
            showError(error.message)
            return
        }
        do throws(ActionRefusal) {
            _ = try await actions.run(.stop(sessionId))
        } catch {
            showError("\(Self.parkFailedNotice) \(error.message)")
            return
        }
        notify("Handed over to \(withoutHiddenCharacters(done.name)).")
    }

    private func resumeAll() async {
        do throws(ActionRefusal) {
            guard case .resumedAll(let result) = try await actions.run(.resumeAll) else { return }
            // With no resumed session, the failures alone say why: no "Resumed 0 sessions.".
            if result.resumed > 0 || result.failed.isEmpty {
                notify(
                    result.resumed == 1
                        ? "Resumed 1 session." : "Resumed \(result.resumed) sessions.")
            }
            if !result.failed.isEmpty {
                let lines = result.failed.map {
                    "\(withoutHiddenCharacters($0.name)): \($0.error.message)"
                }
                showError(lines.joined(separator: "; "))
            }
        } catch {
            fail(error)
        }
    }

    // Open the worktree of the session in Finder: the Open worktree button of the Delete dialog.
    // The dialog stays open.
    private func openWorktree(_ sessionId: String) {
        let apps = apps
        start(last: false) { [weak self] in
            do throws(ActionRefusal) {
                try await apps.openWorktree(sessionId)
            } catch {
                self?.fail(error)
            }
        }
    }

    // MARK: - The chat and the history

    private func chatOpen(_ sessionId: String) -> Bool {
        guard let session = SessionID(sessionId) else { return false }
        return layout.layout.frame(of: .chat(session)) != nil
    }

    // Close the chat of a session that went, and clear its selection.
    private func closeChat(_ sessionId: String) {
        if let session = SessionID(sessionId) { layout.apply(.close(.chat(session))) }
        if selection.selectedId == sessionId { selection.selectedId = nil }
    }

    private func changeHistory(_ change: (History) -> History) {
        uiState.change { $0.dialogHistory = change($0.dialogHistory) }
    }

    // MARK: - The notices and the errors

    // Show a notice for messageTime. While a Delete runs, the notice waits for its end.
    package func notify(_ text: String) {
        notices.notify(text)
        applyNotices()
    }

    private func applyNotices() {
        for effect in notices.takeEffects() {
            switch effect {
            case .show(let id, let text, let untilHidden):
                noticeLine.show(text, id: id, untilHidden: untilHidden)
            case .hide(let id):
                noticeLine.hide(id)
            }
        }
    }

    private func showError(_ text: String) {
        errorCount += 1
        errorLine.show(text, id: errorCount, untilHidden: true)
    }

    private func fail(_ refusal: ActionRefusal) {
        showError(refusal.message)
    }
}

// The wait of beginSession for the acceptance of its start. It resumes its waiter one time: at
// the acceptance, or with the refusal before it. A later end does nothing.
@MainActor
private final class StartAcceptance {
    private var waiter: CheckedContinuation<Result<Void, ActionRefusal>, Never>?

    init(_ waiter: CheckedContinuation<Result<Void, ActionRefusal>, Never>) {
        self.waiter = waiter
    }

    // True until the first end.
    var isWaiting: Bool { waiter != nil }

    func end(_ result: Result<Void, ActionRefusal>) {
        waiter?.resume(returning: result)
        waiter = nil
    }
}
