import Foundation

// The input file of one run, input.json in the folder of the run. The skill
// bifrost-daily-update reads it, so the field names are those of the skill. The times are ISO 8601
// text in UTC with milliseconds, and timeZone names the zone of the user.
package struct RunInput: Sendable, Equatable, Encodable {
    // One area that is on. since is the start of the period of the area: the area gets only the
    // work after it.
    package struct Area: Sendable, Equatable, Encodable {
        package var id: String
        package var name: String
        package var description: String
        package var takesRest: Bool
        package var since: Date

        private enum Key: String, CodingKey {
            case id, name, description, takesRest, since
        }

        package func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: Key.self)
            try container.encode(id, forKey: .id)
            try container.encode(name, forKey: .name)
            try container.encode(description, forKey: .description)
            try container.encode(takesRest, forKey: .takesRest)
            try container.encode(InputTime.text(since), forKey: .since)
        }
    }

    package static let version = 1

    package var now: Date
    package var timeZone: String
    // The user on the board: a name, an email or an ID. It can be empty.
    package var you: String
    package var areas: [Area]
    package var format: DailyFormat
    package var prs: [MergedPR]
    // The server of the board ("server": null with no board) and the tools that the run may call.
    package var source: DailySource

    // The input of a run at now: each area that is on, with its period (DailySchedule.since),
    // the format, the PRs, and the source with the tools that the run may call now.
    package init(
        settings: DailySettings, state: DailyState, now: Date, calendar: Calendar,
        prs: [MergedPR], tools: [String]
    ) {
        self.now = now
        timeZone = calendar.timeZone.identifier
        you = settings.you
        areas = settings.areas.filter(\.on).map { area in
            Area(
                id: area.id, name: area.name, description: area.description,
                takesRest: area.takesRest,
                since: DailySchedule.since(
                    now: now, days: settings.days, lastSent: state.lastSent[area.id],
                    calendar: calendar))
        }
        format = settings.format
        self.prs = prs
        source = DailySource(server: settings.source.server, tools: tools)
    }

    // The earliest start of the areas: the PRs merged after it go into the input. With no area,
    // now.
    package static func earliestSince(
        _ settings: DailySettings, state: DailyState, now: Date, calendar: Calendar
    ) -> Date {
        RunInput(settings: settings, state: state, now: now, calendar: calendar, prs: [], tools: [])
            .areas.map(\.since).min() ?? now
    }

    // The start of each area, by its ID.
    package var since: [String: Date] {
        Dictionary(areas.map { ($0.id, $0.since) }, uniquingKeysWith: { first, _ in first })
    }

    private enum Key: String, CodingKey {
        case version, now, timeZone, you, areas, format, prs, source
    }

    package func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: Key.self)
        try container.encode(Self.version, forKey: .version)
        try container.encode(InputTime.text(now), forKey: .now)
        try container.encode(timeZone, forKey: .timeZone)
        try container.encode(you, forKey: .you)
        try container.encode(areas, forKey: .areas)
        try container.encode(format, forKey: .format)
        try container.encode(prs, forKey: .prs)
        try container.encode(source, forKey: .source)
    }
}
