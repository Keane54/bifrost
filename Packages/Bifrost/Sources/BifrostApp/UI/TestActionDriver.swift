// The session actions of the debug test port (docs/behaviour/shell.md, "The test port"). An action
// request runs its action through the action runner, as a click on its button does, and answers
// each dialog of the run:
// - A confirmation answers yes with the confirm field, else no. A confirmation that asks twice
//   shows the step again after the first click. It gets its second click after Confirm.againWait
//   on the clock of the dialogs, as a person must wait.
// - Rename saves the name of the request. New session starts the session in the folder of the
//   request, with the name of the request or the suggested name. Its dialog closes when the start
//   is accepted (ActionRunner.beginSession), and the answer comes at the end of the start, so the
//   state then has the new row.
// An action that is off for the row of now, or a dialog that is open before the run, gives its
// reason and runs nothing. The result comes at the end of the run (or after the time limit): nil,
// or a reason. The notice line and the error line show the result of the action, as in the
// window, and the state of the test port gives them.
//
// A send types the text into the session through the runner, as the send box does, after the
// check of Send message.
#if DEBUG
import BifrostFoundation
import BifrostSessions
import BifrostWindows
import Observation

@MainActor
enum TestActionDriver {
    // The longest run. The test port gives up a request after 30 s.
    static let timeLimit = Duration.seconds(25)

    // clock: the clock of the dialogs, which the wait for the second click of a confirmation uses.
    static func run(
        _ action: TestAction, on runner: ActionRunner, clock: any Clock<Duration>
    ) async -> String? {
        if runner.dialogs.isOpen { return "a dialog is open" }
        let before = runner.lastTask
        switch action.target {
        case .session(let id, let session):
            let sessionId = session.text
            guard let row = runner.row(sessionId) else { return "no such session" }
            let state = ActionModel.state(id, row, runner.context(sessionId))
            guard state.enabled else { return state.reason ?? "the action is off" }
            runner.run(id, sessionId)
        case .global(let id):
            let state = ActionModel.globalState(id, runner.globalContext)
            guard state.enabled else { return state.reason ?? "the action is off" }
            runner.runGlobal(id)
        }
        let task = runner.lastTask == before ? nil : runner.lastTask
        let reason = await follow(task, action, runner.dialogs, clock)
        // The rest of an accepted New session start runs in a task of the runner.
        guard reason == nil, case .global(.newSession) = action.target,
            let start = runner.lastTask, start != before, start != task
        else { return reason }
        return await follow(start, action, runner.dialogs, clock)
    }

    static func send(_ text: String, to session: SessionID, on runner: ActionRunner) async
        -> String?
    {
        let sessionId = session.text
        guard let row = runner.row(sessionId) else { return "no such session" }
        let state = ActionModel.state(.sendMessage, row, runner.context(sessionId))
        guard state.enabled else { return state.reason ?? "the action is off" }
        do throws(ActionRefusal) {
            try await runner.send(sessionId, text)
        } catch {
            return error.message
        }
        return nil
    }

    // Answer each dialog that shows until the task of the run ends. A run with no task (Rename,
    // New session) ends when its dialog closes.
    private static func follow(
        _ task: Task<Void, Never>?, _ action: TestAction, _ dialogs: DialogHost,
        _ clock: any Clock<Duration>
    ) async -> String? {
        let watch = RunWatch()
        Task { [weak watch] in
            await task?.value
            watch?.ended = true
        }
        // A cancel of the timer ends it with no time out.
        let timer = Task { [weak watch] in
            guard (try? await Task.sleep(for: timeLimit)) != nil else { return }
            watch?.timedOut = true
        }
        defer { timer.cancel() }
        let changes = Observations { (dialogs.isOpen, watch.ended, watch.timedOut) }
        for await (open, ended, timedOut) in changes {
            if timedOut {
                dialogs.escape()
                return "the action did not end in \(timeLimit)"
            }
            if open {
                if let reason = await answer(dialogs, action, clock) { return reason }
            } else if ended {
                return nil
            }
        }
        return nil
    }

    // Answer the dialog that shows. The result is the reason of a dialog that did not save or
    // start, after its cancel, else nil.
    private static func answer(
        _ dialogs: DialogHost, _ action: TestAction, _ clock: any Clock<Duration>
    ) async -> String? {
        switch dialogs.dialog {
        case .confirm(let model):
            guard action.confirm else {
                model.cancel()
                return nil
            }
            model.pressConfirm()
            // A confirmation that asks twice is in the step again after the first click, and
            // takes the second click only after the wait. The wait is on the clock of the model.
            for _ in 0..<3 where shows(model, in: dialogs) && model.step == .again {
                guard (try? await clock.sleep(for: Confirm.againWait)) != nil else { return nil }
                model.pressConfirm()
            }
            return nil
        case .rename(let model):
            model.name = action.name ?? model.name
            await model.submit()
            guard shows(model, in: dialogs) else { return nil }
            let reason = model.reason ?? "the name did not save"
            model.cancel()
            return reason
        case .newSession(let model):
            guard let folder = action.folder else {
                model.cancel()
                return "New session needs a folder"
            }
            model.apply(.cwd(folder))
            if let name = action.name { model.apply(.name(name)) }
            await model.submit()
            guard shows(model, in: dialogs) else { return nil }
            let reason = model.reason ?? "the session did not start"
            model.cancel()
            return reason
        case .setup:
            // The Setup dialog is no dialog of an action, so the port does not answer it.
            return "the Setup dialog is open"
        case .releaseNotes:
            return "the release notes dialog is open"
        case nil:
            return nil
        }
    }

    // True while the dialog of the model shows.
    private static func shows(_ model: AnyObject, in dialogs: DialogHost) -> Bool {
        switch dialogs.dialog {
        case .confirm(let shown): shown === model
        case .rename(let shown): shown === model
        case .newSession(let shown): shown === model
        case .setup(let shown): shown === model
        case .releaseNotes(let shown): shown === model
        case nil: false
        }
    }
}

// The end of the task of a run, and the time limit, as values that an observation reads.
@MainActor
@Observable
private final class RunWatch {
    var ended = false
    var timedOut = false
}
#endif
