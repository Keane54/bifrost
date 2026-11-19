import BifrostFoundation
import BifrostSessions
import BifrostTestSupport
import Foundation
import Testing

@testable import BifrostDailyUpdate

// The arguments of the probe and of the run (docs/behaviour/daily-update.md, "The run"). The run
// has no tool that writes, may call only the allowed read tools of the source, and denies each
// other tool of each MCP server.

private let folder = URL(
    filePath: "/nonexistent/runs/20261118-093000", directoryHint: .isDirectory)
private let skills = URL(filePath: "/nonexistent/bifrost-skills", directoryHint: .isDirectory)
private let input = folder.appending(path: "input.json")

private func args(_ settings: DailySettings, inventory found: MCPInventory = inventory)
    -> [String]
{
    RunArgs.run(input: input, folder: folder, skills: skills, settings: settings, inventory: found)
}

// The values of a list flag: the arguments after it up to the next flag.
private func values(of flag: String, in args: [String]) -> [String] {
    guard let start = args.firstIndex(of: flag) else { return [] }
    return Array(args[(start + 1)...].prefix { !$0.hasPrefix("--") })
}

@Suite("the arguments of the run")
struct RunArgsTests {
    @Test func theRunHasNoWriteTool() {
        let run = args(boardSettings())
        #expect(values(of: "--tools", in: run) == ["Read,Skill"])
        #expect(values(of: "--permission-mode", in: run) == ["dontAsk"])
        let allowed = values(of: "--allowedTools", in: run)
        // The user chose the write tool update_item, but the run never gets it.
        #expect(
            allowed == [
                "mcp__board__list_items", "mcp__board__get_item", "Skill",
                "Read(//nonexistent/runs/20261118-093000/**)",
                "Read(//nonexistent/bifrost-skills/**)",
            ])
        #expect(values(of: "--disallowedTools", in: run).contains("mcp__board__update_item"))
    }

    @Test func theRunHasItsWholeArgumentList() {
        var settings = boardSettings()
        settings.model = .sonnet
        // Each other MCP tool by its full name, then the rule of each other server.
        let deny = [
            "mcp__board__update_item", "mcp__board__work_items_mark_comment_read",
            "mcp__plugin_slack_slack__slack_read_channel",
            "mcp__plugin_slack_slack__slack_send_message", "mcp__claude_ai_Claude_Docs__read",
            "mcp__claude_ai_Claude_Docs__create", "mcp__plugin_slack_slack",
            "mcp__claude_ai_Claude_Docs",
        ]
        let expected =
            [
                "-p", "--output-format", "json", "--no-session-persistence", "--tools",
                "Read,Skill", "--permission-mode", "dontAsk", "--plugin-dir",
                "/nonexistent/bifrost-skills", "--add-dir",
                "/nonexistent/runs/20261118-093000", "--allowedTools", "mcp__board__list_items",
                "mcp__board__get_item", "Skill", "Read(//nonexistent/runs/20261118-093000/**)",
                "Read(//nonexistent/bifrost-skills/**)", "--disallowedTools",
            ] + deny + [
                "--settings", #"{"disableAllHooks":true}"#, "--model", "sonnet",
                "/bifrost-daily-update bifrost-input=/nonexistent/runs/20261118-093000/input.json",
            ]
        #expect(args(settings) == expected)
    }

    @Test func everyOtherServerIsDenied() {
        let deny = values(of: "--disallowedTools", in: args(boardSettings()))
        // Each tool of the source that the run may not call.
        #expect(deny.contains("mcp__board__update_item"))
        #expect(deny.contains("mcp__board__work_items_mark_comment_read"))
        #expect(!deny.contains("mcp__board__list_items"))
        // Each tool of each other server by its full name, and the rule of the server.
        #expect(docsTools.allSatisfy(deny.contains))
        #expect(deny.contains("mcp__claude_ai_Claude_Docs"))
        #expect(deny.contains("mcp__plugin_slack_slack"))
        #expect(!deny.contains("mcp__board"))
        // With no source, every server is denied.
        var none = settings()
        none.source = DailySource()
        let all = values(of: "--disallowedTools", in: args(none))
        #expect(all.contains("mcp__board"))
        #expect(values(of: "--allowedTools", in: args(none)).first == "Skill")
    }

    @Test func aToolOfNoServerIsDenied() throws {
        let line = initEvent(
            servers: [("board", "connected")], tools: boardTools + ["mcp__x_y__send"])
        let found = try #require(Inventory.parseInit(line))
        let deny = values(of: "--disallowedTools", in: args(boardSettings(), inventory: found))
        #expect(deny.contains("mcp__x_y__send"))
    }

    // A connector of claude.ai with an odd name: its tools are denied by their full names,
    // also when Claude Code gives them a prefix that fits no server.
    @Test func aConnectorWithAnOddNameIsDenied() throws {
        let tools = [
            "mcp__claude_ai_Slack_Enterprise__slack_send_message",
            "mcp__claude_ai_Slack__Grid__slack_read_channel",
        ]
        let line = initEvent(
            servers: [("board", "connected"), ("claude.ai Slack (Enterprise)", "connected")],
            tools: boardTools + tools)
        let found = try #require(Inventory.parseInit(line))
        // The fixed prefix rule maps the first tool to the connector.
        #expect(found.servers.last?.tools == [tools[0]])
        let run = args(boardSettings(), inventory: found)
        let deny = values(of: "--disallowedTools", in: run)
        #expect(tools.allSatisfy(deny.contains))
        #expect(deny.contains("mcp__claude_ai_Slack_Enterprise"))
        #expect(!values(of: "--allowedTools", in: run).contains { $0.contains("Slack") })
    }

    @Test func theModelIsAddedOnlyWhenSet() {
        let standard = args(boardSettings())
        #expect(!standard.contains("--model"))
        var settings = boardSettings()
        settings.model = .haiku
        let run = args(settings)
        let model = run.firstIndex(of: "--model").map { run[$0 + 1] }
        #expect(model == "haiku")
        // The prompt stays the last argument.
        #expect(run.last?.hasPrefix("/bifrost-daily-update bifrost-input=") == true)
    }

    @Test func theInventoryArgvIsTheProbeWithItsPromptModelAndMode() {
        #expect(
            RunArgs.inventory() == [
                "-p", "--output-format", "stream-json", "--no-session-persistence", "--verbose",
                "--tools", "", "--model", "haiku", "--permission-mode", "dontAsk", "--settings",
                #"{"disableAllHooks":true}"#, "Reply with OK only.",
            ])
    }

    @Test func theInventoryStopsAt30Seconds() {
        let claude = ClaudeRunner(
            path: "/nonexistent/claude", baseEnvironment: ["PATH": "/usr/bin:/bin"],
            runner: ProcessRunner())
        let command = InventoryReader(claude: claude).command(in: folder)
        #expect(command.timeout == .seconds(30))
        #expect(command.executable == "/nonexistent/claude")
        #expect(command.arguments == RunArgs.inventory())
        #expect(command.directory == folder.path(percentEncoded: false))
        #expect(command.environment == claude.environment)
        // SIGTERM first, so claude can end its MCP servers, then SIGKILL after 2 s.
        #expect(command.killSignal == .terminate)
        #expect(command.terminateGrace == .seconds(2))
        #expect(command.input == nil)
    }
}
