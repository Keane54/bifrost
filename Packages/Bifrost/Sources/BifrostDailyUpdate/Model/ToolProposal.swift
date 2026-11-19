// The read tools that Settings proposes for the ticket source, and the check that keeps every tool
// that can change the board out of the run (docs/behaviour/daily-update.md, "The run"). The rule
// reads the words of a tool name after the prefix of its server: getIssue gives "get" and
// "issue", list_work_items gives "list", "work" and "items".
package enum ToolProposal {
    // A tool with one of these words only reads.
    package static let readWords = [
        "list", "get", "search", "query", "read", "find", "diff", "aggregate",
    ]

    // A tool with one of these words can change things. The run never gets such a tool, also
    // when it has a read word too (work_items_mark_comment_read). The list has the verbs of
    // writes. A word that read tools also use as a noun ("comment" in list_comment_reactors,
    // "link" in get_issue_link_types, "schedule" in get_schedule) is not in it: a write tool of
    // such a thing also has a verb of the list (add_comment, create_link).
    package static let writeWords = [
        "add", "create", "update", "delete", "replace", "remove", "move", "mark", "reorder",
        "batch", "set", "import", "execute", "send", "post", "assign", "close", "archive",
        "restore", "publish", "regenerate", "approve", "confirm", "convert", "revert", "complete",
        "tick", "run", "write", "edit", "upload", "merge", "sync", "cancel", "start", "stop",
        "kill", "reset", "share", "reject", "resolve", "reopen", "save", "rename", "deploy",
        "unpublish", "submit", "enable", "disable", "install", "uninstall", "push", "lock",
        "unlock", "dismiss", "revoke", "grant", "invoke", "trigger", "insert", "upsert", "patch",
        "drop", "purge", "clear", "transition", "unassign", "unarchive", "duplicate", "clone",
        "attach", "detach", "invite", "reply", "subscribe", "unsubscribe", "watch", "unwatch",
        "follow", "unfollow", "vote", "react", "pin", "unpin", "star", "unstar", "fork",
        "rollback", "restart", "pause", "resume", "notify", "decline", "accept", "unlink",
    ]

    // The read tools of a server: each tool with a read word that the run may call.
    package static func proposed(_ server: MCPServer) -> [String] {
        return server.tools.filter { tool in
            words(of: tool, prefix: server.prefix).contains(where: readWords.contains)
                && mayCall(tool, prefix: server.prefix)
        }
    }

    // True when the run may call the tool: it has no write word.
    package static func mayCall(_ tool: String, prefix: String) -> Bool {
        !hasWriteWord(tool, prefix: prefix)
    }

    // True when a word of the tool name can change things.
    package static func hasWriteWord(_ tool: String, prefix: String) -> Bool {
        words(of: tool, prefix: prefix).contains(where: writeWords.contains)
    }

    // The words of a tool name after the prefix, in lower case. The name splits at "_", at "-",
    // at white space and at each camelCase boundary: getIssueID gives get, issue and id, and
    // HTMLParser gives html and parser.
    package static func words(of tool: String, prefix: String) -> [String] {
        let name = tool.hasPrefix(prefix) ? String(tool.dropFirst(prefix.count)) : tool
        let spaced =
            name
            .replacing(/([a-z0-9])([A-Z])/) { "\($0.output.1) \($0.output.2)" }
            .replacing(/([A-Z]+)([A-Z][a-z])/) { "\($0.output.1) \($0.output.2)" }
        return
            spaced
            .split { $0 == "_" || $0 == "-" || $0.isWhitespace }
            .map { $0.lowercased() }
    }
}
