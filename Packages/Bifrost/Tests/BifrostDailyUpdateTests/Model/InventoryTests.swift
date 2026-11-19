import BifrostFoundation
import Foundation
import Testing

@testable import BifrostDailyUpdate

// The MCP servers of the probe (docs/behaviour/daily-update.md, "The run").
@Suite("the inventory of the MCP servers")
struct InventoryTests {
    @Test func theInitEventGivesTheServersAndTools() throws {
        let found = try #require(Inventory.parseInit(initLine))
        #expect(found == inventory)
        // A built-in tool is no MCP tool.
        #expect(!found.tools.contains("Task"))
    }

    @Test func eachOtherLineGivesNoServers() {
        #expect(Inventory.parseInit(#"{"type":"assistant","message":{}}"#) == nil)
        #expect(Inventory.parseInit(#"{"type":"system","subtype":"hook"}"#) == nil)
        #expect(Inventory.parseInit("not JSON") == nil)
        #expect(Inventory.parseInit(#"{"type":"system","subtype":"init","tools":[]}"#) == nil)
    }

    // A tool goes to the server with the longest prefix that it starts with.
    @Test func eachToolGoesToItsLongestPrefix() throws {
        let line = """
            {"type":"system","subtype":"init","tools":["mcp__a__list","mcp__a__b__list"],\
            "mcp_servers":[{"name":"a","status":"connected"},{"name":"a__b"},{"status":"x"}]}
            """
        let found = try #require(Inventory.parseInit(line))
        #expect(
            found.servers == [
                MCPServer(name: "a", status: "connected", tools: ["mcp__a__list"]),
                MCPServer(name: "a__b", status: "", tools: ["mcp__a__b__list"]),
            ])
    }

    @Test func thePrefixRule() {
        #expect(Inventory.prefix("claude.ai Claude Docs") == "mcp__claude_ai_Claude_Docs__")
        #expect(Inventory.prefix("plugin:slack:slack") == "mcp__plugin_slack_slack__")
        #expect(Inventory.prefix("my-board_2") == "mcp__my-board_2__")
        // A connector of claude.ai: each run of _ becomes one _, and the _ at the ends go.
        #expect(Inventory.prefix("claude.ai Atlassian (Jira)") == "mcp__claude_ai_Atlassian_Jira__")
        #expect(Inventory.prefix("claude.ai A & B.") == "mcp__claude_ai_A_B__")
        // Another name keeps each _.
        #expect(Inventory.prefix("my (board)") == "mcp__my__board___")
    }

    // A tool whose prefix fits no server stays in the tools of the inventory, so the run can
    // deny it by its full name.
    @Test func aToolOfNoServerIsKept() throws {
        let line = initEvent(
            servers: [("board", "connected")], tools: ["mcp__board__list_items", "mcp__x_y__send"])
        let found = try #require(Inventory.parseInit(line))
        #expect(found.tools == ["mcp__board__list_items", "mcp__x_y__send"])
        #expect(found.servers.flatMap(\.tools) == ["mcp__board__list_items"])
    }

    @Test func aSourceThatIsNotConnectedHasAProblem() {
        #expect(Inventory.problem(of: nil, in: inventory) == nil)
        #expect(Inventory.problem(of: "board", in: inventory) == nil)
        #expect(Inventory.problem(of: "claude.ai Claude Docs", in: inventory) == "needs-auth")
        #expect(Inventory.problem(of: "gone", in: inventory) == "not found")
        let quiet = MCPInventory(servers: [MCPServer(name: "quiet", status: "")], tools: [])
        #expect(Inventory.problem(of: "quiet", in: quiet) == "unknown")
    }
}
