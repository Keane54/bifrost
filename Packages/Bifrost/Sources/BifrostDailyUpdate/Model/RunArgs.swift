import BifrostFoundation
import BifrostSessions
import Foundation

// The arguments of the two claude runs of the Daily update (docs/behaviour/daily-update.md, "The
// run"): the probe of the MCP servers, and the print-mode run that writes the drafts. The run has
// no tool that writes. It may call only the read tools of the ticket source that the user chose,
// and the arguments deny each other MCP tool that the probe found, by its full name.
package enum RunArgs {
    // The time limit of the probe.
    package static let inventoryLimit = Duration.seconds(30)

    // The probe: no built-in tools, no hooks and no saved session. The probe stops at its first
    // event (the init event), before a call of the model. A probe that misses the stop asks the
    // small model for a short answer and asks for no permission, so it stays small and harmless.
    package static func inventory() -> [String] {
        [
            "-p", "--output-format", "stream-json", noSession, "--verbose", "--tools", "",
            "--model", "haiku", "--permission-mode", "dontAsk", "--settings",
            #"{"disableAllHooks":true}"#, "Reply with OK only.",
        ]
    }

    // The flag that keeps a print run out of the sessions of Claude Code: claude then writes no
    // transcript under ~/.claude/projects. Each run has a new folder, so each saved run would add
    // a project there that nothing removes.
    static let noSession = "--no-session-persistence"

    // The prompt of the run: the skill, with the path of the input file.
    package static func prompt(input: URL) -> String {
        "/bifrost-daily-update bifrost-input=\(path(input))"
    }

    // The tools that the run may call: the chosen tools that the source has now, with no tool
    // that has a write word, also when the user chose it (ToolProposal.mayCall).
    package static func allowed(_ settings: DailySettings, inventory: MCPInventory) -> [String] {
        guard let source = chosenServer(settings, inventory) else { return [] }
        return settings.source.tools.filter {
            source.tools.contains($0) && ToolProposal.mayCall($0, prefix: source.prefix)
        }
    }

    // The deny list: each MCP tool of the probe by its full name, except the allowed tools. This
    // covers each other server, a tool that fits no server and a connector of claude.ai, with no
    // trust in the name rule of a server. Then the rule of each server that is not the source
    // (its prefix with no "__" at the end), for a tool that comes after the probe.
    package static func denied(
        _ settings: DailySettings, inventory: MCPInventory, allowed: [String]
    ) -> [String] {
        let source = chosenServer(settings, inventory)
        var deny = inventory.tools.filter { !allowed.contains($0) }
        for server in inventory.servers where server.name != source?.name {
            let rule = rule(server)
            if !deny.contains(rule) { deny.append(rule) }
        }
        return deny
    }

    // The run of the drafts. input is the input file in folder. folder and skills are real paths
    // (no link), so the Read rules match the paths that claude reads. A Read rule of an absolute
    // path has the form Read(//path/**). The order matters: each flag with a list ends at the next
    // flag, and the prompt comes last, after a flag with one value.
    package static func run(
        input: URL, folder: URL, skills: URL, settings: DailySettings, inventory: MCPInventory
    ) -> [String] {
        let allowed = allowed(settings, inventory: inventory)
        let deny = denied(settings, inventory: inventory, allowed: allowed)
        var args = [
            "-p", "--output-format", "json", noSession, "--tools", "Read,Skill",
            "--permission-mode", "dontAsk", "--plugin-dir", path(skills), "--add-dir", path(folder),
            "--allowedTools",
        ]
        args += allowed
        args += ["Skill", "Read(/\(path(folder))/**)", "Read(/\(path(skills))/**)"]
        if !deny.isEmpty { args += ["--disallowedTools"] + deny }
        args += ["--settings", #"{"disableAllHooks":true}"#]
        if settings.model != .standard { args += ["--model", settings.model.rawValue] }
        args.append(prompt(input: input))
        return args
    }

    // The source of the settings in the inventory, or nil: no source, a source that the
    // inventory does not have.
    private static func chosenServer(_ settings: DailySettings, _ inventory: MCPInventory)
        -> MCPServer?
    {
        inventory.server(named: settings.source.server)
    }

    // The rule of a whole server: mcp__<name>.
    private static func rule(_ server: MCPServer) -> String {
        String(server.prefix.dropLast(2))
    }

    // The path of a file URL with no "/" at its end.
    private static func path(_ url: URL) -> String {
        let text = url.path(percentEncoded: false)
        return text.count > 1 && text.hasSuffix("/") ? String(text.dropLast()) : text
    }
}
