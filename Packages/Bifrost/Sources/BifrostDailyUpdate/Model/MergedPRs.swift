import BifrostFoundation
import Foundation

// The PRs of the user that merged after a time, from the GitHub CLI (gh). They go into the input
// of the run, so a draft can name them. The run reads the title and the description of each PR:
// a PR that names a ticket goes in the area of that ticket (docs/behaviour/daily-update.md, "The
// run"). The run gets no gh and no shell: Bifrost reads the PRs.

// One merged PR, in the form of the input file.
package struct MergedPR: Sendable, Equatable, Encodable {
    // The repository, as owner/name.
    package var repo: String
    package var number: Int
    package var title: String
    package var url: String
    package var mergedAt: Date
    // The description, cut to MergedPRs.maxBody characters. A PR with no description has "".
    package var body: String

    package init(
        repo: String, number: Int, title: String, url: String, mergedAt: Date, body: String
    ) {
        self.repo = repo
        self.number = number
        self.title = title
        self.url = url
        self.mergedAt = mergedAt
        self.body = body
    }

    private enum Key: String, CodingKey {
        case repo, number, title, url, mergedAt, body
    }

    package func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: Key.self)
        try container.encode(repo, forKey: .repo)
        try container.encode(number, forKey: .number)
        try container.encode(title, forKey: .title)
        try container.encode(url, forKey: .url)
        try container.encode(InputTime.text(mergedAt), forKey: .mergedAt)
        try container.encode(body, forKey: .body)
    }
}

// Why gh gave no PRs. The run goes on with no PRs, and the Event log gets the message.
package enum MergedPRsError: Error, Sendable, Equatable {
    case notStarted
    case timedOut
    // gh ended with an error: the first line of its error text, or nil when it has none.
    case failed(String?)
    // The answer of gh is not a list of JSON objects.
    case badAnswer

    package var message: String {
        switch self {
        case .notStarted: "GitHub CLI (gh) isn't installed, or Bifrost couldn't start it."
        case .timedOut: "GitHub CLI (gh) took too long to answer."
        case .failed(let line?): "GitHub CLI (gh) said: \(line)"
        case .failed(nil): "GitHub CLI (gh) stopped with an error."
        case .badAnswer: "GitHub CLI (gh) gave an answer that Bifrost couldn't read."
        }
    }
}

package enum MergedPRs {
    // The longest description of a PR in the input, in characters.
    package static let maxBody = 2000
    // The end of a description that Bifrost cut. The skill knows this text.
    package static let cutMark = "\n[Bifrost cut this text.]"
    // The longest error line of gh in a message.
    package static let maxReason = 200

    // gh search prs for the PRs of the user that merged at the time or later. The time is UTC to
    // the second, rounded down, so the search does not miss a PR of that second. For a merged
    // PR, closedAt is the merge time: the search answer has no mergedAt.
    package static func args(since: Date) -> [String] {
        [
            "search", "prs", "--author=@me", "--merged-at=>=\(isoSeconds(since))", "--limit",
            "100", "--json", "number,title,url,repository,closedAt,body",
        ]
    }

    // The UTC time with no fraction of a second, for example 2026-11-11T09:30:00Z.
    package static func isoSeconds(_ date: Date) -> String {
        let seconds = (date.timeIntervalSince1970).rounded(.down)
        return Date(timeIntervalSince1970: seconds).formatted(
            Date.ISO8601FormatStyle(includingFractionalSeconds: false))
    }

    // The PRs of the answer of gh. An item with a missing field or a field of the wrong type is
    // dropped. An answer that is not a JSON list fails.
    package static func parse(_ answer: String) -> Result<[MergedPR], MergedPRsError> {
        guard let value = try? JSONDecoder().decode(JSONValue.self, from: Data(answer.utf8)),
            let items = value.array
        else { return .failure(.badAnswer) }
        return .success(items.compactMap(pr))
    }

    // The text with at most maxBody characters, and the cut mark after a cut.
    package static func cut(_ text: String) -> String {
        text.count <= maxBody ? text : String(text.prefix(maxBody)) + cutMark
    }

    private static func pr(_ item: JSONValue) -> MergedPR? {
        guard let fields = item.object, let number = fields["number"]?.wholeNumber,
            let title = fields["title"]?.string, let url = fields["url"]?.string,
            let closed = fields["closedAt"]?.string.flatMap(InputTime.date),
            let repo = fields["repository"]?.object?["nameWithOwner"]?.string, !repo.isEmpty
        else { return nil }
        let body: String
        switch fields["body"] {
        case nil, .null?: body = ""
        case .string(let text)?: body = cut(text)
        default: return nil
        }
        return MergedPR(
            repo: repo, number: number, title: title, url: url, mergedAt: closed, body: body)
    }
}

// The times of the input file and of gh: ISO 8601 text. The input has milliseconds, as the skill
// expects: 2026-11-11T09:30:00.000Z.
package enum InputTime {
    package static func text(_ date: Date) -> String {
        date.formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: true))
    }

    // The time of an ISO 8601 text, with or without a fraction of a second, or nil.
    package static func date(_ text: String) -> Date? {
        (try? Date.ISO8601FormatStyle(includingFractionalSeconds: false).parse(text))
            ?? (try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(text))
    }
}
