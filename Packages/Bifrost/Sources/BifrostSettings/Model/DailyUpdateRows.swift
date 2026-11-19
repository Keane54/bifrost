// The rows of Settings > Daily update (docs/behaviour/daily-update.md, "Settings > Daily update")
// and the rules of the section. This file is the one source of the labels: each row shows its
// label, and the search finds a row by it. The rules are pure: the check of a change with its
// reason, the choices of the ticket source, the rows of the tools, the days and the work areas.
import BifrostDailyUpdate
import BifrostSessions
import Foundation

// The rows of the section, in order. The raw value is the label of the row.
package enum DailyUpdateRow: String, Sendable, CaseIterable {
    case source = "Ticket source"
    case tools = "Tools the run can use"
    case you = "You on the board"
    case mergedPrs = "Use merged PRs"
    case draftTime = "Draft and first reminder"
    case deadline = "Deadline"
    case days = "Days"
    case model = "Model"
    case format = "Format"
    case examples = "Examples of your updates"
    case areas = "Work areas"
    case panel = "Daily update panel"
}

// One server of the ticket source picker. A server that is not connected shows its status, and
// the user cannot choose it.
package struct ServerChoice: Sendable, Equatable {
    package var name: String
    package var label: String
    package var enabled: Bool
}

// One tool of the tools list of the ticket source.
package struct ToolRow: Sendable, Equatable, Identifiable {
    // The full name: mcp__<server>__<tool>.
    package var id: String
    // The name after the prefix of the server.
    package var name: String
    // True when the box is ticked.
    package var on: Bool
    // True when the name has a write word: the run never gets the tool, so its box is off.
    package var write: Bool
    // True when the name has a read word and no write word.
    package var proposed: Bool

    // The note beside the tool, or nil for a tool that only reads.
    package var note: String? {
        if write { return DailyUpdateRows.neverUsed }
        return proposed ? nil : DailyUpdateRows.mayChange
    }
}

// One example box of the section: the identity of the box, the place of its example in the
// list and its text. The identity lives only in the section, never in the settings file. A box
// keeps the text of the user that a save refused, so the box and that text go with their example.
package struct ExampleItem: Sendable, Equatable, Identifiable {
    package var id: String
    package var index: Int
    package var text: String
}

// The read tools that Bifrost proposed for the server that the user chose. They wait until the
// user confirms them (DailyUpdateRows.useToolsButton).
package struct ToolProposalDraft: Sendable, Equatable {
    package var server: String
    package var tools: [String]

    package init(server: String, tools: [String]) {
        self.server = server
        self.tools = tools
    }
}

package enum DailyUpdateRows {
    // MARK: - The texts

    package static let sourceHint = "An MCP server from your Claude Code setup."
    package static let noSource = "No ticket source"
    package static let findServersButton = "Find servers"
    package static let readingLine = "Looking for your MCP servers…"
    package static let noClaude = "Bifrost couldn't find Claude Code."
    package static let readFailed = "Bifrost couldn't read your MCP servers. Please try again."
    package static let toolsHint =
        "Bifrost ticks the tools that only read. The run can't use any other tool."
    package static let proposalHint =
        "Bifrost ticked the tools that only read. Check the list, then use it."
    package static let useToolsButton = "Use these tools"
    package static let noSourceTools = "Choose a ticket source to pick its tools."
    package static let findToSeeTools = "Find servers to see all the tools of this source."
    package static let mayChange = "May change things"
    package static let neverUsed = "Bifrost never lets the run use this tool"
    package static let youHint =
        "Your name, email or ID. Leave it empty to use the account that the server signs in with."
    package static let deadlineHint = "The second reminder comes 10 minutes before."
    package static let formatHint = "Your headings. Bold is **text**."
    package static let examplesHint = "Up to 3. Claude copies their voice."
    package static let addExampleButton = "Add example"
    package static let addAreaButton = "Add work area"
    package static let removeButton = "Remove"
    package static let panelButton = "Open"
    package static let nameLabel = "Name"
    package static let channelLabel = "Channel"
    package static let descriptionLabel = "Which work goes here"
    package static let takesRestLabel = "Takes all other work"

    // The reasons of a refused change. Each one says what is wrong and the limit.
    package static let timeReason = "Enter each time as HH:MM, for example 09:30."
    package static let gapReason = "The deadline must be 10 minutes or more after the draft time."
    package static let daysReason = "Pick at least one day."
    package static let formatReason = "The format needs 1 to 2,000 characters."
    package static let examplesReason =
        "You can add up to 3 examples, each up to 4,000 characters."
    package static let areasReason = "You can have up to \(DailySettings.maxAreas) work areas."
    package static let noNameReason = "Each work area needs a name."
    package static let nameReason = "A name can have up to \(DailySettings.maxName) characters."
    package static let channelReason =
        "A channel can have up to \(DailySettings.maxChannel) characters."
    package static let descriptionReason =
        "\"Which work goes here\" can have up to \(DailySettings.maxDescription) characters."
    package static let restReason = "Only one work area can take all other work."
    package static let youReason =
        "Your name, email or ID can have up to \(DailySettings.maxYou) characters."
    package static let toolsReason = "Choose up to 500 tools, all from the ticket source."
    package static let settingsReason = "Bifrost couldn't save these settings."

    // The text of a server that the user cannot choose.
    package static func notConnected(_ server: MCPServer) -> String {
        "\(server.name) \(statusWords(server.status)). Connect it in Claude Code with /mcp first."
    }

    // The confirm before Remove of a work area.
    package static func removeText(_ area: WorkArea) -> ConfirmText {
        ConfirmText(
            title: "Remove \(area.name)?",
            body: "Bifrost forgets its name, channel and description.", confirm: "Remove")
    }

    // MARK: - The check

    // Why the settings cannot be saved, or nil. The checks of DailySettings.isValid, each with
    // its own text.
    package static func reason(_ settings: DailySettings) -> String? {
        if settings.you.count > DailySettings.maxYou { return youReason }
        if settings.deadline.minutes - settings.draftTime.minutes < DailySettings.minGap {
            return gapReason
        }
        if settings.days.isEmpty { return daysReason }
        if !(1...DailySettings.maxTemplate).contains(settings.format.template.count) {
            return formatReason
        }
        let examples = settings.format.examples
        if examples.count > DailySettings.maxExamples
            || examples.contains(where: { $0.count > DailySettings.maxExample })
        {
            return examplesReason
        }
        if settings.areas.count > DailySettings.maxAreas { return areasReason }
        for area in settings.areas {
            if area.name.isEmpty { return noNameReason }
            if area.name.count > DailySettings.maxName { return nameReason }
            if area.channel.count > DailySettings.maxChannel { return channelReason }
            if area.description.count > DailySettings.maxDescription { return descriptionReason }
        }
        if settings.areas.filter(\.takesRest).count > 1 { return restReason }
        if settings.source.tools.count > DailySettings.maxTools { return toolsReason }
        return settings.isValid ? nil : settingsReason
    }

    // MARK: - The ticket source

    // The words for the status of a server.
    package static func statusWords(_ status: String) -> String {
        switch status {
        case "connected": "connected"
        case "needs-auth": "needs sign-in"
        case "failed": "could not connect"
        case "pending": "still connecting"
        case "disabled": "is turned off"
        default: status.isEmpty ? "has no status" : status
        }
    }

    // Each server of the inventory, in its order. Every server is offered, also a Slack server
    // (user decision, 2026-11-18). A server that is not connected shows its status and is off.
    package static func serverChoices(_ inventory: MCPInventory?) -> [ServerChoice] {
        (inventory?.servers ?? []).map { server in
            let connected = server.status == "connected"
            return ServerChoice(
                name: server.name,
                label: connected ? server.name : "\(server.name) (\(statusWords(server.status)))",
                enabled: connected)
        }
    }

    // The tools to show for the source. With an inventory, each tool of the server, then each
    // saved tool that the inventory does not list. With no inventory, the saved tools. A
    // proposal for the server gives the ticks; else the saved tools give them. A tool with a
    // write word is never ticked.
    package static func toolRows(
        _ inventory: MCPInventory?, _ source: DailySource, proposal: ToolProposalDraft?
    ) -> [ToolRow] {
        guard let server = source.server else { return [] }
        let prefix = DailySource.toolPrefix(of: server)
        let listed = inventory?.server(named: server)?.tools ?? []
        let names = listed + source.tools.filter { !listed.contains($0) }
        let ticked = Set(proposal?.server == server ? proposal?.tools ?? [] : source.tools)
        return names.map { name in
            let words = ToolProposal.words(of: name, prefix: prefix)
            let write = ToolProposal.hasWriteWord(name, prefix: prefix)
            let short = name.hasPrefix(prefix) ? String(name.dropFirst(prefix.count)) : name
            return ToolRow(
                id: name, name: short, on: !write && ticked.contains(name), write: write,
                proposed: !write && words.contains(where: ToolProposal.readWords.contains))
        }
    }

    // Add or remove one tool. The order of the list stays.
    package static func toggled(_ tools: [String], _ name: String, on: Bool) -> [String] {
        let rest = tools.filter { $0 != name }
        return on ? rest + [name] : rest
    }

    // MARK: - The examples

    // The example boxes of the list: each ID goes with the example at its place. When the list
    // has another count than the IDs (a change from outside the section, until the section takes
    // the new count), each box gets a new identity, so no kept text moves to another example.
    package static func exampleItems(_ examples: [String], ids: [UUID]) -> [ExampleItem] {
        guard ids.count == examples.count else {
            return examples.enumerated().map { index, text in
                ExampleItem(id: "new-\(examples.count)-\(index)", index: index, text: text)
            }
        }
        return zip(ids, examples).enumerated().map { index, pair in
            ExampleItem(id: pair.0.uuidString, index: index, text: pair.1)
        }
    }

    // MARK: - The days

    // The days as buttons, from Monday to Sunday. The number is DailySchedule.dayNumber: 0 is
    // Sunday.
    package static let dayChoices: [(day: Int, label: String)] = [
        (1, "Mon"), (2, "Tue"), (3, "Wed"), (4, "Thu"), (5, "Fri"), (6, "Sat"), (0, "Sun"),
    ]

    // MARK: - The work areas

    // A new work area, on, with a name that no other area has: "Work area 2" for the second.
    package static func newArea(after areas: [WorkArea], id: String) -> WorkArea {
        let names = Set(areas.map(\.name))
        var number = areas.count + 1
        while names.contains("Work area \(number)") { number += 1 }
        return WorkArea(id: id, name: "Work area \(number)")
    }

    // The areas with the "takes all other work" flag of one area changed. Only one area can have
    // it: a second one is refused with restReason.
    package static func settingTakesRest(
        _ areas: [WorkArea], _ id: String, on: Bool
    ) -> Result<[WorkArea], RestRefusal> {
        if on, areas.contains(where: { $0.takesRest && $0.id != id }) {
            return .failure(RestRefusal())
        }
        return .success(areas.map { area in
            var area = area
            if area.id == id { area.takesRest = on }
            return area
        })
    }

    // A second area that takes all other work.
    package struct RestRefusal: Error, Equatable {
        package var message: String { DailyUpdateRows.restReason }
    }
}
