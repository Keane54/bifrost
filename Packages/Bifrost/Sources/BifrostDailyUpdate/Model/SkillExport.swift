// The settings that the skill bifrost-daily-update reads when the user runs it by hand: the file
// settings.json in the Daily update folder (docs/behaviour/daily-update.md, "The run"). Bifrost
// owns its form, and the skill reads only this file, never the settings of Bifrost. It holds no
// secret: the areas that are on, the format, the source with its read tools, "You on the
// board", the merged PRs switch (the mode by hand reads the PRs only when it is on) and the
// version.
package struct SkillExport: Sendable, Equatable, Encodable {
    package static let version = 1

    package var areas: [WorkArea]
    package var format: DailyFormat
    package var mergedPrs: Bool
    package var source: DailySource
    package var you: String

    // A tool with a write word goes out, as it does from the input of a run
    // (ToolProposal.mayCall), so the mode by hand of the skill never gets it either.
    package init(_ settings: DailySettings) {
        areas = settings.areas.filter(\.on)
        format = settings.format
        mergedPrs = settings.mergedPrs
        if let server = settings.source.server {
            let prefix = DailySource.toolPrefix(of: server)
            source = DailySource(
                server: server,
                tools: settings.source.tools.filter { ToolProposal.mayCall($0, prefix: prefix) })
        } else {
            source = DailySource()
        }
        you = settings.you
    }

    private enum Key: String, CodingKey {
        case version, areas, format, mergedPrs, source, you
    }

    package func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: Key.self)
        try container.encode(Self.version, forKey: .version)
        try container.encode(areas, forKey: .areas)
        try container.encode(format, forKey: .format)
        try container.encode(mergedPrs, forKey: .mergedPrs)
        try container.encode(source, forKey: .source)
        try container.encode(you, forKey: .you)
    }
}
