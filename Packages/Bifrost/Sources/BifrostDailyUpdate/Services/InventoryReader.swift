import BifrostFoundation
import BifrostSessions
import Foundation

// Reads the MCP servers of the Claude Code of the user and their tools: the probe of RunArgs, with
// the env of the claude runs, stopped at its first system/init event (ProcessLines). The probe
// gets SIGTERM, so claude can end its MCP servers, and SIGKILL 2 s later if it still runs. The run
// of the drafts reads the servers before its claude run, and Settings reads them for the ticket
// source picker.
package struct InventoryReader: Sendable {
    // The time from the SIGTERM of the probe to its SIGKILL.
    package static let grace = Duration.seconds(2)

    package let claude: ClaudeRunner

    package init(claude: ClaudeRunner) {
        self.claude = claude
    }

    // The probe in the folder. The folder must exist.
    package func command(in folder: URL) -> Command {
        Command(
            claude.path, RunArgs.inventory(), directory: folder.path(percentEncoded: false),
            environment: claude.environment, timeout: RunArgs.inventoryLimit,
            killSignal: .terminate, terminateGrace: Self.grace)
    }

    // The servers and the tools, or nil when the probe ended with no init event (claude failed,
    // or the time limit came first).
    @concurrent package func read(in folder: URL) async -> MCPInventory? {
        let line = await ProcessLines.firstLine(command(in: folder)) {
            Inventory.parseInit($0) != nil
        }
        return line.flatMap(Inventory.parseInit)
    }
}
