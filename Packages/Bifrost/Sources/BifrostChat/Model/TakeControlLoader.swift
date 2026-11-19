// The rules of the Take control loader of a chat window (docs/behaviour/chat.md, "The Take control
// loader"). The loader shows while Take control runs, and after a good Take control until the
// terminal shows Claude. The loaders are keyed by the row ID of the session: a /clear gives the row
// a new current ID, but its row ID and its chat window stay. Pure value code.
import BifrostSessions

package struct TakeControlLoader: Sendable, Equatable {
    // The time limit of a loader that waits only for the first output, after a good Take
    // control. Then the window shows the terminal, with its note when it cannot attach.
    package static let timeLimit = Duration.seconds(20)

    // The loader of one session. running: Take control runs. shown: the terminal showed Claude
    // while Take control ran.
    private struct State: Sendable, Equatable {
        var running: Bool
        var shown: Bool
    }

    private var states: [String: State] = [:]

    package init() {}

    // Take control starts: the loader shows.
    package mutating func start(_ sessionId: String) {
        states[sessionId] = State(running: true, shown: false)
    }

    // Take control failed: the loader goes.
    package mutating func stop(_ sessionId: String) {
        states[sessionId] = nil
    }

    // Take control worked. The loader goes when the terminal showed Claude already. Else it
    // waits for the terminal.
    package mutating func finish(_ sessionId: String) {
        guard let state = states[sessionId], !state.shown else {
            states[sessionId] = nil
            return
        }
        states[sessionId] = State(running: false, shown: false)
    }

    // The terminal shows Claude, or it shows why it ended. After a good Take control the loader
    // goes. While Take control runs, the loader stays until the finish.
    package mutating func shown(_ sessionId: String) {
        guard let state = states[sessionId], state.running else {
            states[sessionId] = nil
            return
        }
        states[sessionId] = State(running: true, shown: true)
    }

    // The time limit of a loader that waits only for the first output passed: the loader goes.
    // A loader of a Take control that runs stays.
    package mutating func timeLimitPassed(_ sessionId: String) {
        if waits(sessionId) { states[sessionId] = nil }
    }

    // True while the chat window of the session shows the loader.
    package func shows(_ sessionId: String) -> Bool {
        states[sessionId] != nil
    }

    // True when the loader waits only for the first output: the time limit then runs.
    package func waits(_ sessionId: String) -> Bool {
        states[sessionId].map { !$0.running } ?? false
    }

    // True while Take control of the session runs. The chat window of the session does not
    // attach then, so its first attach comes after the move.
    package func runs(_ sessionId: String) -> Bool {
        states[sessionId]?.running ?? false
    }

    // The session IDs with a loader, in order.
    package var sessionIds: [String] { states.keys.sorted() }

    // The line of the loader: the name of the session with no hidden character, or no name.
    package static func text(name: String?) -> String {
        let shown = withoutHiddenCharacters(name ?? "")
        guard !shown.isEmpty else { return "Taking control..." }
        return "Taking control of \(shown)..."
    }
}
