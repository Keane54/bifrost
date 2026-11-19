// The reply reader of Hand over (docs/behaviour/actions.md, "Hand over"): the note of the reply
// to one request, read from the transcript lines after the baseline.
import BifrostFoundation
import BifrostTestSupport
import Foundation
import Testing

@testable import BifrostSessions

private let id = "ab12cd34"
private let model = HandOverLines.model
private let turnEnd = HandOverLines.turnEnd
private let typed = HandOverLines.userMessage

private func line(_ entry: JSONValue) -> String { HandOverLines.line(entry) }
private func noteReply(_ note: String) -> String { HandOverLines.reply(note) }
private let metadata = line(["type": "file-history-snapshot", "messageId": "m1"])

// The request entry. The real prompt also holds both markers, on lines of their own.
private func request(_ requestID: String = id, mode: JSONValue? = "plan") -> String {
    HandOverLines.request(requestID, mode: mode)
}

private func assistant(
    _ content: JSONValue, requestedModel: JSONValue = .null, sidechain: Bool = false
) -> String {
    line([
        "type": "assistant", "requestedModel": requestedModel, "isSidechain": .bool(sidechain),
        "message": ["role": "assistant", "model": .string(model), "content": content],
    ])
}

private func text(_ value: String) -> JSONValue { ["type": "text", "text": .string(value)] }

private func read(_ tail: String) -> HandOverReply { HandOverReply.read(tail, requestID: id) }

@Suite("the reply of Hand over")
struct HandOverReplyTests {
    // The texts of the assistant entries after the request are joined, the model is the
    // requested model of the last entry that has one, and the mode is the mode of the request.
    @Test func aNoteBetweenTheMarkersIsDone() {
        let thinking: JSONValue = [["type": "thinking", "thinking": "Plan.", "signature": "s"]]
        let tail =
            metadata + request() + assistant(thinking)
            + assistant([text("Here is the note.\n\(HandOverText.noteStart)\n# Hand-over: fix\n")])
            + assistant(
                [text("## Goal\nfix the login\n  \(HandOverText.noteEnd)  \nDone.")],
                requestedModel: "opus[1m]")
            + assistant([text("A subagent.")], sidechain: true) + metadata + turnEnd
        #expect(
            read(tail)
                == .done(note: "# Hand-over: fix\n\n## Goal\nfix the login", model: "opus[1m]",
                    mode: .known(.plan)))
        // The model of the message counts when the entry has no requested model.
        #expect(
            read(request() + noteReply("n") + turnEnd)
                == .done(note: "n", model: model, mode: .known(.plan)))
        // The request line can be any line of the user text, also after a CR LF.
        let later = line([
            "type": "user",
            "message": ["content": .string("Text.\r\nBifrost hand-over request \(id)\nMore.")],
        ])
        #expect(
            read(later + noteReply("n") + turnEnd) == .done(note: "n", model: model, mode: .absent))
    }

    // Bifrost reads only the entries after the request, so a note before it never counts: a
    // marker pair of an earlier hand-over, or the request of another ID.
    @Test func aNoteBeforeTheBaselineNeverCounts() {
        let earlier = noteReply("old note")
        #expect(read(earlier + request() + noteReply("new note") + turnEnd).note == "new note")
        #expect(read(request("ffff0000") + noteReply("other")) == .waiting)
        // A longer ID on the request line is not the request, and a turn end before the request
        // means that the baseline was in another turn.
        let earlyEnd = HandOverReply.failed("a turn ended before the hand-over request")
        #expect(read(request(id + "9") + noteReply("other") + turnEnd) == earlyEnd)
        #expect(read(turnEnd + request() + noteReply("n") + turnEnd) == earlyEnd)
    }

    // A message from the user after the request fails at once, also after the turn end. A
    // message that the user types during a turn comes as a queued command. The note of a
    // background task is also a queued command, but it is not a message from the user.
    @Test func aNewUserMessageFailsAtOnce() {
        let reason = "a new message came in during the hand-over"
        #expect(read(request() + typed) == .failed(reason))
        #expect(read(request() + noteReply("n") + turnEnd + typed) == .failed(reason))
        let queued = line([
            "type": "attachment",
            "attachment": ["type": "queued_command", "prompt": "Wait.", "commandMode": "prompt"],
        ])
        #expect(read(request() + queued) == .failed(reason))
        let task = line([
            "type": "attachment",
            "attachment": [
                "type": "queued_command", "prompt": "<task-notification>",
                "commandMode": "task-notification",
            ],
        ])
        #expect(read(request() + task + noteReply("n") + turnEnd).note == "n")
        let interrupt = line([
            "type": "user",
            "message": ["role": "user", "content": [text("[Request interrupted by user]")]],
        ])
        #expect(read(request() + interrupt) == .failed("the session was interrupted"))
        // A meta entry and the results of a tool are not messages from the user.
        let meta = line(["type": "user", "isMeta": true, "message": ["content": "x"]])
        let result = line([
            "type": "user", "message": ["content": [["type": "tool_result", "content": "ok"]]],
        ])
        #expect(read(request() + meta + result + noteReply("n") + turnEnd).note == "n")
    }

    @Test func noMarkerYetIsWaiting() {
        #expect(read("") == .waiting)
        #expect(read(metadata) == .waiting)
        #expect(read(request()) == .waiting)
        #expect(read(request() + assistant([text("Working on it.")])) == .waiting)
        // At the turn end, a reply with no markers fails.
        #expect(
            read(request() + assistant([text("No note.")]) + turnEnd)
                == .failed("the reply doesn't have both note markers"))
    }

    // The reader is strict: a form that it does not know fails, so a change of the transcript
    // format never gives a wrong note.
    @Test func aReplyOfAnUnknownFormFails() {
        let unknownLine = HandOverReply.failed("a line of the transcript has an unknown form")
        #expect(read(request() + "not json\n") == unknownLine)
        #expect(read(request() + "[1]\n") == unknownLine)
        #expect(read(request() + #"{"type":1}"# + "\n") == unknownLine)
        let image: JSONValue = [["type": "image"]]
        let unknownPart = HandOverReply.failed("the reply has a part that Bifrost doesn't know")
        #expect(read(request() + assistant(image)) == unknownPart)
        #expect(read(request() + assistant("text")) == unknownPart)
        #expect(read(request() + assistant([["type": "text"]])) == unknownPart)
        let start = HandOverText.noteStart
        let end = HandOverText.noteEnd
        let two = assistant([text("\(start)\na\n\(end)\n\(start)\nb\n\(end)")])
        #expect(read(request() + two + turnEnd) == .failed("the reply has more than one note"))
        #expect(
            read(request() + assistant([text("\(end)\na\n\(start)")]) + turnEnd)
                == .failed("the note markers are in the wrong order"))
        #expect(
            read(request() + assistant([text("\(start)\n  \n\(end)")]) + turnEnd)
                == .failed("the note is empty"))
    }

    // The request keeps three cases of its mode: no field, a mode that a new session can start
    // with, and any other value. Only no field takes the mode of the row, so a default request
    // stays default, and bypassPermissions never gives a mode.
    @Test func onlyARequestWithNoModeTakesTheModeOfTheRow() {
        let cases: [(JSONValue?, HandOverReply.RequestMode)] = [
            (nil, .absent), ("plan", .known(.plan)), ("acceptEdits", .known(.acceptEdits)),
            ("default", .other), ("bypassPermissions", .other), ("", .other), ("Plan", .other),
            (.null, .other), (3, .other),
        ]
        for (value, mode) in cases {
            #expect(read(request(mode: value) + noteReply("n") + turnEnd).mode == mode)
        }
        #expect(HandOverReply.RequestMode.other.newSessionMode(row: "acceptEdits") == nil)
        #expect(HandOverReply.RequestMode.other.newSessionMode(row: nil) == nil)
        #expect(HandOverReply.RequestMode.known(.plan).newSessionMode(row: "dontAsk") == .plan)
        #expect(HandOverReply.RequestMode.absent.newSessionMode(row: "acceptEdits") == .acceptEdits)
        #expect(HandOverReply.RequestMode.absent.newSessionMode(row: "bypassPermissions") == nil)
        #expect(HandOverReply.RequestMode.absent.newSessionMode(row: "default") == nil)
        #expect(HandOverReply.RequestMode.absent.newSessionMode(row: nil) == nil)
    }

    // After the note, a new message, a queued command or a reply starts a new turn, and so does
    // a line of an unknown form. Metadata and an empty tail do not.
    @Test func aNewMessageOrReplyStartsANewTurn() {
        #expect(!HandOverReply.startsNewTurn(""))
        #expect(!HandOverReply.startsNewTurn(metadata + "\n" + turnEnd))
        let result = line([
            "type": "user", "message": ["content": [["type": "tool_result", "content": "ok"]]],
        ])
        #expect(!HandOverReply.startsNewTurn(result))
        #expect(HandOverReply.startsNewTurn(metadata + typed))
        #expect(HandOverReply.startsNewTurn(assistant([text("More.")])))
        #expect(HandOverReply.startsNewTurn(assistant([text("Sub.")], sidechain: true)))
        let task = line([
            "type": "attachment",
            "attachment": ["type": "queued_command", "commandMode": "task-notification"],
        ])
        #expect(HandOverReply.startsNewTurn(task))
        #expect(HandOverReply.startsNewTurn("not json\n"))
    }
}

extension HandOverReply {
    // The note of a reply that is done, else nil.
    fileprivate var note: String? {
        if case .done(let note, _, _) = self { note } else { nil }
    }

    // The mode of a reply that is done, else nil.
    fileprivate var mode: RequestMode? {
        if case .done(_, _, let mode) = self { mode } else { nil }
    }
}
