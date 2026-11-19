// The model of the send box of the Selected Item panel (docs/behaviour/actions.md, "The send
// box"): the draft of each session, the sends that run, the last failed send, the line of the box
// and the draft of a focus of the box. A send goes through the action runner, so the session input
// types it, a /rename clears the local name and a slash command goes into the history.
//
// - The draft of each session stays when the selection changes. A good send clears the draft of
//   its session. A failed send keeps it, and its text shows as the failure of that session until
//   the next change of that draft or the next send.
// - The box is off while Send message is off for the row of now, and read-only while a send of
//   its session runs.
import BifrostFoundation
import BifrostSessions
import Observation

@MainActor
@Observable
package final class SendBoxModel {
    // The line while a send runs, and the hint of a draft that is a slash command.
    package static let sendingLine = "Sending..."
    package static let slashHint = "This runs as a slash command."

    // The last failed send: its session and the friendly text of the failure.
    private struct Failure {
        var sessionId: String
        var message: String
    }

    @ObservationIgnored package let runner: ActionRunner
    private var drafts: [String: String] = [:]
    private var sending: Set<String> = []
    private var failure: Failure?
    #if DEBUG
    // The task of the last submit of the box. A test waits for it.
    @ObservationIgnored package private(set) var lastSubmit: Task<Void, Never>?
    #endif

    package init(runner: ActionRunner) {
        self.runner = runner
    }

    // The draft of the session: an empty text when it has none.
    package func draft(_ sessionId: String) -> String {
        drafts[sessionId] ?? ""
    }

    // A change of the text in the box. It clears a failed send of the session.
    package func setDraft(_ sessionId: String, _ text: String) {
        store(sessionId, text)
        if failure?.sessionId == sessionId { failure = nil }
    }

    // True while a send of the session runs. The box is then read-only.
    package func isSending(_ sessionId: String) -> Bool {
        sending.contains(sessionId)
    }

    // The state of Send message for the row of now. The box is off while it is off.
    package func state(_ sessionId: String) -> ActionState {
        ActionModel.state(.sendMessage, runner.row(sessionId), runner.context(sessionId))
    }

    // Send the draft of the session. Nothing happens while Send message is off, while a send of
    // the session runs, and for a draft of only white space.
    package func submit(_ sessionId: String) async {
        guard let text = begin(sessionId) else { return }
        await send(sessionId, text)
    }

    // Start a submit as its own task. The key of the box uses it. The send of the session counts
    // as running at once, so a second key in the same turn starts no second send and types
    // nothing.
    package func startSubmit(_ sessionId: String) {
        guard let text = begin(sessionId) else { return }
        let task = Task { [weak self] () -> Void in await self?.send(sessionId, text) }
        #if DEBUG
        lastSubmit = task
        #else
        _ = task
        #endif
    }

    // The checks of a submit. The result is the text to send, and the send then runs.
    private func begin(_ sessionId: String) -> String? {
        guard state(sessionId).enabled, !sending.contains(sessionId) else { return nil }
        let text = draft(sessionId)
        guard !text.trimmed().isEmpty else { return nil }
        failure = nil
        sending.insert(sessionId)
        return text
    }

    private func send(_ sessionId: String, _ text: String) async {
        defer { sending.remove(sessionId) }
        do throws(ActionRefusal) {
            try await runner.send(sessionId, text)
            store(sessionId, "")
        } catch {
            failure = Failure(sessionId: sessionId, message: error.message)
        }
    }

    // The line of the box for the session, or nil. The reason why Send message is off comes
    // first, then "Sending...", then the failure of the session, then the hint of a draft that
    // starts with "/". The panel shows the line in its status icon.
    package func line(_ sessionId: String) -> (text: String, failed: Bool)? {
        let state = state(sessionId)
        if !state.enabled, let reason = state.reason { return (reason, false) }
        if sending.contains(sessionId) { return (Self.sendingLine, false) }
        if let failure, failure.sessionId == sessionId { return (failure.message, true) }
        if draft(sessionId).drop(while: \.isWhitespace).hasPrefix("/") {
            return (Self.slashHint, false)
        }
        return nil
    }

    // A click on the error icon of the panel clears the failed send.
    package func clearFailure() {
        failure = nil
    }

    // Send message (slash false) or Run slash command (slash true) focuses the box of the
    // session. The result is true when the box must take the focus. A box that is off takes no
    // focus and no text. Run slash command puts "/" in an empty draft.
    package func prepareFocus(for sessionId: String, slash: Bool) -> Bool {
        guard state(sessionId).enabled else { return false }
        if slash && draft(sessionId).isEmpty { store(sessionId, "/") }
        return true
    }

    private func store(_ sessionId: String, _ text: String) {
        drafts[sessionId] = text.isEmpty ? nil : text
    }
}
