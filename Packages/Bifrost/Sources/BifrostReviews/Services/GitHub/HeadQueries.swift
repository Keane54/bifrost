// The fresh read of the head of a PR (docs/behaviour/reviews.md, "The GitHub data"): its state,
// its branches and commits, its merge state and the first 50 checks of its newest commit. A
// conflict or CI round reads it before it acts, because the poll can be old. The values go in
// variables, never in the text, and the checks have the fields of the poll.
import BifrostFoundation
import Foundation
import OSLog

@MainActor
package enum HeadQueries {
    package static let name = "pr-head"

    private static let logger = Logger(bifrost: "reviews")

    static let text = """
        query PRHead($owner: String!, $repo: String!, $number: Int!) {
          repository(owner: $owner, name: $repo) {
            pullRequest(number: $number) {
              state
              author { login }
              repository { defaultBranchRef { name } }
              \(PollQuery.mergeState)
              \(PollQuery.checks(PollQuery.mineChecksLimit))
            }
          }
        }
        """

    static func query(_ pr: PRKey) -> GitHubQuery {
        GitHubQuery(
            name: name, text: text,
            variables: [
                "owner": .string(pr.repo.owner), "repo": .string(pr.repo.name),
                "number": .int(pr.number),
            ])
    }

    // The head of the PR. An answer with no known state, no head commit or no fork flag fails:
    // the refusal of GitHub when the answer has errors, else a bad answer. Errors next to usable
    // data and the fields that read as missing go to the log.
    package static func read(_ pr: PRKey, client: GitHubClient) async throws(GitHubError)
        -> HeadRead
    {
        let answer = try HeadAnswer.decode(await client.read(query(pr))).get()
        for message in answer.errors {
            logger.error("GitHub gave an error to a head read. \(message, privacy: .private)")
        }
        client.logFaults(answer.faults, read: name)
        return answer.read
    }
}
