// A GitHub read, and the error of a GitHub call (docs/behaviour/reviews.md, "Safety"). A read is a
// GraphQL query only: the gh runner refuses a text that holds the word "mutation" before gh
// starts, so a read can never change GitHub. The writes are the closed set of GitHubWrite.
import BifrostFoundation
import Foundation

// One GraphQL read. The name identifies the read in the log and in the fake of the tests. Each
// value goes in a variable, never in the text.
package struct GitHubQuery: Sendable, Equatable {
    package let name: String
    package let text: String
    package let variables: [String: GraphQLValue]

    package init(name: String, text: String, variables: [String: GraphQLValue]) {
        self.name = name
        self.text = text
        self.variables = variables
    }

    // The argv of gh for a read: the body goes on stdin.
    package static let arguments = ["api", "graphql", "--input", "-"]

    // False when a GraphQL name of the text is the word "mutation", in any case. A GraphQL name
    // is a run of letters, digits and "_", so clientMutationId is no match. A comment counts
    // too: a text that only names the word in a comment is no read either.
    package var isRead: Bool {
        !text.split(whereSeparator: { !Self.isNameCharacter($0) }).contains {
            $0.lowercased() == "mutation"
        }
    }

    // The JSON on the stdin of gh: the text and the variables.
    package var input: Data {
        let body: JSONValue = [
            "query": .string(text), "variables": .object(variables.mapValues(\.json)),
        ]
        return GitHubJSON.encode(body)
    }

    private static func isNameCharacter(_ character: Character) -> Bool {
        character.isASCII && (character.isLetter || character.isNumber || character == "_")
    }
}

// The value of a variable of a read.
package enum GraphQLValue: Sendable, Equatable {
    case string(String), int(Int), bool(Bool), null

    var json: JSONValue {
        switch self {
        case .string(let text): .string(text)
        case .int(let number): .int(number)
        case .bool(let flag): .bool(flag)
        case .null: .null
        }
    }
}

// The JSON form of the bodies of gh: sorted keys, so a body is the same for the same values.
enum GitHubJSON {
    static func encode(_ value: JSONValue) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        // A JSONValue made of strings, whole numbers and null always has a JSON form. An empty
        // body makes gh fail, so a failure can never send a part of a body.
        return (try? encoder.encode(value)) ?? Data()
    }
}

// Why a GitHub call failed. For a write, the case also says whether GitHub can have made the
// change (writeMayHaveHappened): Bifrost never sends such a write again by itself. Each text is
// friendly and plain; the raw line of gh goes only to the Event log.
package enum GitHubError: Error, Sendable, Equatable {
    // gh is not on the PATH, or it cannot start. Nothing reached GitHub.
    case notInstalled
    // gh exited with code 4, or it told the user to log in. Nothing reached GitHub.
    case notLoggedIn
    // Bifrost did not send the call: a read whose text holds a mutation.
    case notSent
    // GitHub answered and refused the call, and the answer proves that a write did not happen:
    // an HTTP 4xx status, or GraphQL errors with no result and no sign that GitHub stopped on
    // the way. The text is the error of GitHub (or the line of gh), without hidden characters,
    // 200 characters at most; it can be empty.
    case refused(String)
    // gh did not end within its time limit. A write may have happened.
    case timedOut
    // The answer was over the output limit. A write may have happened.
    case badAnswer
    // gh failed in a way that does not say what GitHub did: a network error, an HTTP 5xx
    // status, a signal, a stop, GraphQL errors next to a result, or an error that says that
    // GitHub timed out or that something went wrong. A write may have happened. The text is the
    // first line of the error, without hidden characters, 200 characters at most; it can be
    // empty.
    case unknownOutcome(String)

    // True when a write can have reached GitHub and made its change. The caller then checks
    // GitHub before it sends the write again, and never sends it again by itself.
    package var writeMayHaveHappened: Bool {
        switch self {
        case .timedOut, .badAnswer, .unknownOutcome: true
        case .notInstalled, .notLoggedIn, .notSent, .refused: false
        }
    }

    package var message: String {
        switch self {
        case .notInstalled:
            "GitHub CLI (gh) isn't installed. Install it with Homebrew (brew install gh), log in "
                + "with gh auth login, then click Refresh."
        case .notLoggedIn:
            "GitHub CLI (gh) isn't logged in. Run gh auth login in a terminal, then click Refresh."
        case .notSent: "Bifrost didn't send this request, because it would change GitHub."
        case .refused(let line):
            line.isEmpty ? "GitHub refused the request." : "GitHub refused the request: \(line)"
        case .timedOut: "GitHub didn't answer in time."
        case .badAnswer: "GitHub gave an answer that Bifrost can't read."
        case .unknownOutcome(let line):
            line.isEmpty ? "GitHub CLI (gh) couldn't reach GitHub." : "GitHub CLI (gh): \(line)"
        }
    }
}
