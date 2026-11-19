import BifrostFoundation
import BifrostSessions
import Foundation
import Testing

@testable import BifrostDailyUpdate

// The strict check of the result of a run (docs/behaviour/daily-update.md, "The run"): for each
// rule one good and one bad output. Anything unknown fails.

// A result with one area (area-1) whose items and draft are given, and the unplaced items.
private func result(
    items: String = "[]", draft: String = #""Hi""#, unplaced: String = "[]",
    area extra: String = "", top: String = ""
) -> String {
    let area = #"{"id":"area-1","moved":false,"items":\#(items),"draft":\#(draft)\#(extra)}"#
    return #"{"version":1,"areas":[\#(area)],"unplaced":\#(unplaced)\#(top)}"#
}

// An item of the result.
private func item(
    kind: String = "ticket", id: String = "T-1", title: String = "A ticket", extra: String = ""
) -> String {
    #"{"kind":"\#(kind)","id":"\#(id)","title":"\#(title)"\#(extra)}"#
}

private func long(_ count: Int) -> String { String(repeating: "x", count: count) }

// The JSON output of claude -p with only these fields.
private func replyFields(_ fields: [String: JSONValue]) -> Data {
    (try? JSONEncoder().encode(JSONValue.object(fields))) ?? Data()
}

private let noUser = #"{"version":1,"failure":"no-user"}"#

// One output and what the check gives.
struct ResultCase: Sendable, CustomTestStringConvertible {
    let name: String
    let data: Data
    let failure: RunFailure?

    // The text goes between the two markers of a good reply.
    init(_ name: String, _ text: String, fails failure: RunFailure? = nil) {
        self.init(name, output: output(text), fails: failure)
    }

    init(_ name: String, output data: Data, fails failure: RunFailure? = nil) {
        self.name = name
        self.data = data
        self.failure = failure
    }

    var testDescription: String { name }
}

private let bad = RunFailure.badResult
private let longState = item(extra: ",\"to\":\"\(long(61))\"")
private let everyField = item(extra: #","from":"To do","to":"Done","url":"https://x.example/1""#)

private let cases: [ResultCase] = [
    // The output of claude.
    ResultCase("a good result", goodResult),
    ResultCase("an error reply", output: output(goodResult, isError: true), fails: bad),
    ResultCase("output that is not JSON", output: Data("not JSON".utf8), fails: bad),
    ResultCase(
        "a reply with no is_error",
        output: replyFields([
            "result": .string("\(RunResult.begin)\n\(noUser)\n\(RunResult.end)")
        ]), fails: bad),
    ResultCase("a reply with no result", output: replyFields(["is_error": false]), fails: bad),
    ResultCase(
        "output over 1 MiB",
        output: reply("\(RunResult.begin)\n\(goodResult)\n\(RunResult.end)\n\(long(1_048_576))"),
        fails: bad),
    // The markers.
    ResultCase(
        "the last begin marker counts",
        output: reply(
            "\(RunResult.begin)\nnot JSON\n\(RunResult.end)\n  \(RunResult.begin)\r\n\(goodResult)"
                + "\r\n\(RunResult.end)  \nDone.")),
    ResultCase(
        "no end marker", output: reply("\(RunResult.begin)\n\(goodResult)"), fails: bad),
    // The version and the top fields.
    ResultCase("another version", goodResult.replacing(#""version":1"#, with: #""version":2"#),
        fails: bad),
    ResultCase("an unknown top field", result(top: #","note":"x""#), fails: bad),
    ResultCase(
        "no unplaced list", #"{"version":1,"areas":[{"id":"area-1","moved":false,"items":[],"#
            + #""draft":"Hi"}]}"#, fails: bad),
    // A failure of the skill.
    ResultCase("a failure of the skill", #"{"version":1,"failure":"no-user"}"#, fails: .noUser),
    ResultCase(
        "a tool failure of the skill", #"{"version":1,"failure":"tool-denied"}"#,
        fails: .toolDenied),
    ResultCase(
        "a source failure names the source", #"{"version":1,"failure":"source-unavailable"}"#,
        fails: .sourceUnavailable(server: nil, status: nil)),
    ResultCase("an unknown failure", #"{"version":1,"failure":"busy"}"#, fails: bad),
    ResultCase(
        "a failure with another field", #"{"version":1,"failure":"no-user","areas":[]}"#,
        fails: bad),
    // Each area of the input exactly once.
    ResultCase("no area", #"{"version":1,"areas":[],"unplaced":[]}"#, fails: bad),
    ResultCase(
        "an area twice",
        #"{"version":1,"areas":[{"id":"area-1","moved":false,"items":[],"draft":"a"},"#
            + #"{"id":"area-1","moved":false,"items":[],"draft":"b"}],"unplaced":[]}"#,
        fails: bad),
    ResultCase(
        "an unknown area", result().replacing(#""id":"area-1""#, with: #""id":"area-9""#),
        fails: bad),
    // The fields of an area.
    ResultCase("an unknown area field", result(area: #","note":"x""#), fails: bad),
    ResultCase("moved that is not a Bool", result().replacing("false", with: "0"), fails: bad),
    ResultCase("a draft of 8,000 characters", result(draft: "\"\(long(8000))\"")),
    ResultCase("an empty draft", result(draft: #""""#), fails: bad),
    ResultCase("a draft over 8,000 characters", result(draft: "\"\(long(8001))\""), fails: bad),
    // The fields of an item.
    ResultCase("an item with every field", result(items: "[\(everyField)]")),
    ResultCase("an unknown kind", result(items: "[\(item(kind: "issue"))]"), fails: bad),
    ResultCase(
        "an unknown item field", result(items: "[\(item(extra: #","owner":"x""#))]"), fails: bad),
    ResultCase("an ID of 101 characters", result(items: "[\(item(id: long(101)))]"), fails: bad),
    ResultCase(
        "a title of 301 characters", result(items: "[\(item(title: long(301)))]"), fails: bad),
    ResultCase("a state of 61 characters", result(items: "[\(longState)]"), fails: bad),
    ResultCase(
        "a link that is not https",
        result(items: "[\(item(extra: #","url":"http://x.example/1""#))]"), fails: bad),
    ResultCase(
        "a null field", result(items: "[\(item(extra: #","from":null"#))]"), fails: bad),
    // One list holds each item once.
    ResultCase(
        "the same ID with another kind", result(items: "[\(item()),\(item(kind: "pr"))]")),
    ResultCase("an item twice", result(items: "[\(item()),\(item())]"), fails: bad),
    ResultCase(
        "100 items",
        result(unplaced: "[" + (1...100).map { item(id: "T-\($0)") }.joined(separator: ",") + "]")),
    ResultCase(
        "101 items",
        result(unplaced: "[" + (1...101).map { item(id: "T-\($0)") }.joined(separator: ",") + "]"),
        fails: bad),
]

@Suite("the check of the result")
struct RunResultTests {
    @Test(arguments: cases)
    func eachRuleHasAGoodAndABadOutput(_ test: ResultCase) {
        var settings = settings()
        settings.source = DailySource(server: "board", tools: [])
        let input = runInput(settings)
        let checked = RunResult.check(test.data, input: input)
        switch (checked, test.failure) {
        case (.success, nil): break
        case (.failure(let failure), let expected?) where failure == expected: break
        case (.failure(.sourceUnavailable(let server, _)), .sourceUnavailable?):
            // The skill does not name the source, so the check takes it from the input.
            #expect(server == "board")
        default:
            let expected = String(describing: test.failure)
            Issue.record("\(test.name): \(checked), expected \(expected)")
        }
    }

    @Test func aGoodResultKeepsTheItemsDraftAndPeriod() throws {
        let input = runInput()
        let checked = try RunResult.check(output(goodResult), input: input).get()
        let ticket = DailyItem(
            kind: .ticket, id: "T-1", title: "Add refunds", from: "In progress", to: "In review",
            url: "https://board.example.com/T-1")
        #expect(
            checked.areas == [
                DailyAreaResult(
                    id: "area-1", moved: true, items: [ticket], draft: "**Daily update**\nDone.")
            ])
        #expect(checked.unplaced.isEmpty)
        #expect(checked.since == input.since)
        #expect(checked.since["area-1"] != nil)
    }

    // The reason of an error reply is its first line that is not empty, cut to 200 characters.
    @Test func anErrorReplyGivesItsFirstLine() {
        let error = RunResult.reply(reply("\n  API Error: overloaded  \nmore", isError: true))
        #expect(RunResult.errorLine(error) == "API Error: overloaded")
        let longError = RunResult.reply(reply(long(300), isError: true))
        #expect(RunResult.errorLine(longError)?.count == 200)
        #expect(RunResult.errorLine(RunResult.reply(output(goodResult))) == nil)
    }

    @Test func theDenialsAreCounted() {
        #expect(RunResult.reply(output(goodResult, denials: 3))?.denials == 3)
        #expect(RunResult.reply(Data(#"{"result":"x"}"#.utf8))?.denials == 0)
    }
}
