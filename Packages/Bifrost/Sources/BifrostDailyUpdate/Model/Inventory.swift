import BifrostFoundation
import Foundation

// The MCP servers of the Claude Code of the user, from the first event of a probe run
// (docs/behaviour/daily-update.md, "The run"). The event names each server and each tool. A tool
// name starts with the prefix of its server.

// One MCP server and its tools.
package struct MCPServer: Sendable, Equatable {
    package var name: String
    // The state that Claude Code gives, for example "connected", "failed" or "needs-auth".
    package var status: String
    // The prefix of the tool names of the server (Inventory.prefix).
    package var prefix: String
    // The full names of the tools: <prefix><tool>.
    package var tools: [String]

    package init(name: String, status: String, tools: [String] = []) {
        self.name = name
        self.status = status
        prefix = Inventory.prefix(name)
        self.tools = tools
    }
}

// What one probe found: the servers with their tools, and every MCP tool of the event by its full
// name. A tool whose prefix fits no listed server is in tools only, so the deny list of the run
// never depends on the name rule of a server.
package struct MCPInventory: Sendable, Equatable {
    package var servers: [MCPServer]
    // Each tool name of the event that starts with "mcp__", in the order of the event.
    package var tools: [String]

    package init(servers: [MCPServer], tools: [String]) {
        self.servers = servers
        self.tools = tools
    }

    package func server(named name: String?) -> MCPServer? {
        servers.first { $0.name == name }
    }
}

package enum Inventory {
    // The longest status of a server that goes into a failure text.
    package static let maxStatus = 60
    // The start of the name of each MCP tool.
    package static let toolMark = "mcp__"

    // The inventory of a line of the probe, for the system/init event only. Each other line
    // gives nil. A server entry with no text name is ignored. Each tool goes to the server with
    // the longest prefix that matches it. A built-in tool (no "mcp__") goes nowhere.
    package static func parseInit(_ line: String) -> MCPInventory? {
        guard let event = try? JSONDecoder().decode(JSONValue.self, from: Data(line.utf8)),
            let fields = event.object, fields["type"]?.string == "system",
            fields["subtype"]?.string == "init", let entries = fields["mcp_servers"]?.array,
            let list = fields["tools"]?.array
        else { return nil }
        var servers = entries.compactMap { entry -> MCPServer? in
            guard let object = entry.object, let name = object["name"]?.string else { return nil }
            return MCPServer(name: name, status: object["status"]?.string ?? "")
        }
        let tools = list.compactMap(\.string).filter { $0.hasPrefix(toolMark) }
        for tool in tools {
            let owners = servers.indices.filter { tool.hasPrefix(servers[$0].prefix) }
            if let owner = owners.max(by: { servers[$0].prefix.count < servers[$1].prefix.count }) {
                servers[owner].tools.append(tool)
            }
        }
        return MCPInventory(servers: servers, tools: tools)
    }

    // mcp__<name>__, with each character of the name that is not an ASCII letter, a digit, _ or -
    // changed to _.
    package static func prefix(_ server: String) -> String {
        DailySource.toolPrefix(of: server)
    }

    // Why the ticket source cannot work: "not found", or its status when it is not connected
    // ("unknown" for no status). nil with no source, or with a connected source.
    package static func problem(of source: String?, in inventory: MCPInventory) -> String? {
        guard let source else { return nil }
        guard let server = inventory.server(named: source) else { return "not found" }
        if server.status == "connected" { return nil }
        return server.status.isEmpty ? "unknown" : String(server.status.prefix(maxStatus))
    }
}
