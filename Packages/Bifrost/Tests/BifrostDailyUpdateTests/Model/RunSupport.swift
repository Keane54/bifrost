import BifrostFoundation
import Foundation
import Testing

@testable import BifrostDailyUpdate

// The shared values of the tests of the run. The names are neutral: a board server, a docs server
// and the Slack plugin, with the tool names in the form of Claude Code.

let boardTools = [
    "mcp__board__list_items", "mcp__board__get_item", "mcp__board__update_item",
    "mcp__board__work_items_mark_comment_read",
]
let slackTools = [
    "mcp__plugin_slack_slack__slack_read_channel", "mcp__plugin_slack_slack__slack_send_message",
]
let docsTools = ["mcp__claude_ai_Claude_Docs__read", "mcp__claude_ai_Claude_Docs__create"]

// The init event of a probe: three servers, and built-in tools that belong to no server.
let initLine: String = {
    let tools = ["Task", "Read"] + boardTools + slackTools + docsTools
    let event: JSONValue = [
        "type": "system", "subtype": "init", "cwd": "/nonexistent", "session_id": "s",
        "tools": .array(tools.map(JSONValue.string)),
        "mcp_servers": [
            ["name": "board", "status": "connected"],
            ["name": "plugin:slack:slack", "status": "connected"],
            ["name": "claude.ai Claude Docs", "status": "needs-auth"],
        ],
    ]
    let data = (try? JSONEncoder().encode(event)) ?? Data()
    return String(decoding: data, as: UTF8.self)
}()

let board = MCPServer(name: "board", status: "connected", tools: boardTools)
let slack = MCPServer(name: "plugin:slack:slack", status: "connected", tools: slackTools)
let docs = MCPServer(name: "claude.ai Claude Docs", status: "needs-auth", tools: docsTools)
let servers = [board, slack, docs]

// What the probe of initLine gives: the three servers, and each MCP tool by its full name.
let inventory = MCPInventory(servers: servers, tools: boardTools + slackTools + docsTools)

// The init event of a probe with these servers ({"name", "status"}) and tools.
func initEvent(servers: [(String, String)], tools: [String]) -> String {
    let event: JSONValue = [
        "type": "system", "subtype": "init",
        "tools": .array((["Task", "Read"] + tools).map(JSONValue.string)),
        "mcp_servers": .array(
            servers.map { name, status in ["name": .string(name), "status": .string(status)] }),
    ]
    let data = (try? JSONEncoder().encode(event)) ?? Data()
    return String(decoding: data, as: UTF8.self)
}

// The settings of a run with the board as the source. The user chose two read tools and one
// write tool.
func boardSettings(areas: [WorkArea] = [areaOne]) -> DailySettings {
    var settings = settings(areas: areas)
    settings.source = DailySource(
        server: "board",
        tools: ["mcp__board__list_items", "mcp__board__get_item", "mcp__board__update_item"])
    return settings
}

// The JSON output of claude -p whose final reply holds the text between the two markers.
func output(_ text: String, isError: Bool = false, denials: Int = 0) -> Data {
    let result = "\(RunResult.begin)\n\(text)\n\(RunResult.end)"
    return reply(result, isError: isError, denials: denials)
}

// The JSON output of claude -p with this final reply.
func reply(_ result: String, isError: Bool = false, denials: Int = 0) -> Data {
    let denied = Array(repeating: JSONValue.object(["tool_name": "x"]), count: denials)
    let value: JSONValue = [
        "type": "result", "is_error": .bool(isError), "result": .string(result),
        "permission_denials": .array(denied),
    ]
    return (try? JSONEncoder().encode(value)) ?? Data()
}

// The result text of one area with one ticket.
let goodResult = """
    {"version":1,"areas":[{"id":"area-1","moved":true,"items":[{"kind":"ticket","id":"T-1",\
    "title":"Add refunds","from":"In progress","to":"In review",\
    "url":"https://board.example.com/T-1"}],"draft":"**Daily update**\\nDone."}],"unplaced":[]}
    """

// The input of a run at 09:30 on Wednesday with the areas of the settings.
func runInput(_ settings: DailySettings = settings()) -> RunInput {
    RunInput(
        settings: settings, state: .empty, now: wednesday(9, 30), calendar: calendar(), prs: [],
        tools: [])
}
