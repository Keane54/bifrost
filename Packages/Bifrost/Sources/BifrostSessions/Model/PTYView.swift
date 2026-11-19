import BifrostFoundation

// The view of a PTY: what the PTY is for. The manager keeps one PTY for each view.
package enum PTYView: Sendable, Hashable, Comparable {
    // The attach of the chat window of the session. Only a chat panel has one, so its session
    // is a SessionID.
    case chat(SessionID)
    // The hidden attach of the session input: a send or an Interrupt with no chat window. The
    // value is the row ID of the session. Only the session input opens it.
    case input(String)

    // The row ID of the session of the view.
    package var session: String {
        switch self {
        case .chat(let session): session.text
        case .input(let session): session
        }
    }
}
