import BifrostFoundation
import BifrostSessions

// A test can write an ID as a text literal. The literal goes through the parse of the type, so a
// literal that the parse refuses stops the test at once. The app never makes an ID from a
// literal: each ID of the app comes from a parse at the edge.

extension SessionID: ExpressibleByStringLiteral {
    public init(stringLiteral text: String) {
        guard let id = SessionID(text) else { preconditionFailure("not a session ID: \(text)") }
        self = id
    }
}

extension ShortID: ExpressibleByStringLiteral {
    public init(stringLiteral text: String) {
        guard let id = ShortID(text) else { preconditionFailure("not a short ID: \(text)") }
        self = id
    }
}
