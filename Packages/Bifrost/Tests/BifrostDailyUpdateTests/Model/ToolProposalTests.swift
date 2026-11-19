import Testing

@testable import BifrostDailyUpdate

// The read tools that Settings proposes (docs/behaviour/daily-update.md, "The run").
@Suite("the proposed read tools")
struct ToolProposalTests {
    private let prefix = "mcp__board__"

    @Test func aWriteWordRemovesAReadTool() {
        #expect(ToolProposal.proposed(board) == ["mcp__board__list_items", "mcp__board__get_item"])
        let markRead = "mcp__board__work_items_mark_comment_read"
        #expect(ToolProposal.hasWriteWord(markRead, prefix: prefix))
    }

    // Each verb of a write removes a tool with a read word. A noun that read tools use stays.
    @Test func eachWriteVerbRemovesATool() {
        let writes = [
            "cancel_query", "start_search_job", "get_and_reset_counter", "find_and_resolve",
            "getShareLink", "list_and_save", "rename_list", "deploy_search", "unpublish_list",
            "transitionIssue_get", "searchAndDismiss",
        ].map { prefix + $0 }
        let reads = ["work_items_list_comment_reactors", "getIssueLinkTypes", "list_runs"]
            .map { prefix + $0 }
        let server = MCPServer(name: "board", status: "connected", tools: writes + reads)
        #expect(ToolProposal.proposed(server) == reads)
    }

    @Test func aToolWithNoReadWordIsNotProposed() {
        let server = MCPServer(
            name: "board", status: "connected", tools: ["mcp__board__whoami", "mcp__board__ping"])
        #expect(ToolProposal.proposed(server).isEmpty)
    }

    // The words split at "_", at "-" and at each camelCase boundary.
    @Test func theWordsOfAToolName() {
        #expect(ToolProposal.words(of: "mcp__board__getIssueID", prefix: prefix)
            == ["get", "issue", "id"])
        #expect(ToolProposal.words(of: "mcp__board__HTMLParser", prefix: prefix)
            == ["html", "parser"])
        #expect(ToolProposal.words(of: "mcp__board__list-work_items", prefix: prefix)
            == ["list", "work", "items"])
        let tools = ["mcp__board__searchIssues", "mcp__board__createIssue"]
        let server = MCPServer(name: "board", status: "", tools: tools)
        #expect(ToolProposal.proposed(server) == ["mcp__board__searchIssues"])
    }
}
