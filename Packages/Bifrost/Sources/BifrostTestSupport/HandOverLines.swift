import BifrostFoundation
import BifrostSessions
import Foundation
import Testing

// The transcript lines of a hand-over for a test, in the form that Claude Code writes them: a
// user message, the request of the prompt that Bifrost typed, a reply with the note and the turn
// end. A test writes them to the transcript of the session after the send.
package enum HandOverLines {
    // The model of the reply.
    package static let model = "claude-opus-5-5"

    // The end of a turn.
    package static let turnEnd = line([
        "type": "system", "subtype": "turn_duration", "durationMs": 1200,
    ])

    // A message that the user typed.
    package static let userMessage = line([
        "type": "user", "message": ["role": "user", "content": "Reply with OK."],
    ])

    // One transcript line: the entry as JSON, then a line break.
    package static func line(_ entry: JSONValue) -> String {
        let data = (try? JSONEncoder().encode(entry)) ?? Data()
        return String(decoding: data, as: UTF8.self) + "\n"
    }

    // The request ID of the prompt in the text that the session got, or nil.
    package static func requestID(in typed: String) -> String? {
        let pattern = /Bifrost hand-over request ([0-9a-f]{8})/
        return (try? pattern.firstMatch(in: typed)).map { String($0.output.1) }
    }

    // Wait until the paste of the request is in the text that the session got, move the clock of
    // the session input past the gap before the CR, and give the request ID of the prompt. The
    // text comes from a real process, so the waits use the wide default limit of waitUntil.
    @MainActor
    package static func typedRequest(
        _ typed: () -> String, inputClock: ManualClock,
        sourceLocation: SourceLocation = #_sourceLocation
    ) async -> String? {
        await waitUntil(sourceLocation: sourceLocation) {
            typed().contains(InputPlan.pasteEnd)
        }
        await inputClock.waitForSleepers(1, sourceLocation: sourceLocation)
        inputClock.advance(by: InputPlan.pasteCRDelay)
        await waitUntil(sourceLocation: sourceLocation) {
            typed().hasSuffix("\r")
        }
        return requestID(in: typed())
    }

    // The user entry of the request, with the permission mode of the session. A mode of nil
    // gives an entry with no permissionMode field.
    package static func request(_ requestID: String, mode: JSONValue? = "plan") -> String {
        let prompt = HandOverText.prompt(rules: "The rules.", requestID: requestID)
        var entry: [String: JSONValue] = [
            "type": "user", "message": ["role": "user", "content": .string(prompt)],
        ]
        entry["permissionMode"] = mode
        return line(.object(entry))
    }

    // An assistant entry with the note between the markers.
    package static func reply(_ note: String) -> String {
        let text = "Here is the note.\n\(HandOverText.noteStart)\n\(note)\n\(HandOverText.noteEnd)"
        return line([
            "type": "assistant",
            "message": [
                "role": "assistant", "model": .string(model),
                "content": [["type": "text", "text": .string(text)]],
            ],
        ])
    }
}
