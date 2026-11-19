// The reads of a review round on GitHub (docs/behaviour/reviews.md, "Review rounds"). Each read
// is a GitHubQuery: a GraphQL query with its values in variables, never in the text. The context
// read pages through the reviews of the viewer, and the threads read pages through the threads
// of the PR, at most maxPages pages each. The decode is in ReviewAnswer.
import BifrostFoundation
import Foundation

@MainActor
package enum ReviewQueries {
    package static let maxPages = 10
    package static let contextName = "reviewContext"
    package static let threadsName = "reviewThreads"
    package static let reviewName = "pendingReview"

    // The PR, its pending reviews, and the reviews of the viewer. Page 1 reads the PR fields;
    // the later pages read only the reviews.
    static let contextText = """
        query ReviewContext(
          $owner: String!, $repo: String!, $number: Int!, $login: String!, $after: String,
          $head: Boolean!
        ) {
          repository(owner: $owner, name: $repo) {
            pullRequest(number: $number) {
              title @include(if: $head)
              body @include(if: $head)
              url @include(if: $head)
              state @include(if: $head)
              author @include(if: $head) { login }
              baseRefName @include(if: $head)
              headRefName @include(if: $head)
              headRefOid @include(if: $head)
              pending: reviews(states: PENDING, first: 10) @include(if: $head) {
                nodes { id body viewerDidAuthor commit { oid } }
              }
              reviews(author: $login, first: 50, after: $after) {
                pageInfo { hasNextPage endCursor }
                nodes {
                  state body submittedAt url
                  commit { oid }
                  comments(first: 100) { nodes { replyTo { id } } }
                }
              }
            }
          }
        }
        """

    static let threadsText = """
        query ReviewThreads($owner: String!, $repo: String!, $number: Int!, $after: String) {
          repository(owner: $owner, name: $repo) {
            pullRequest(number: $number) {
              reviewThreads(first: 50, after: $after) {
                pageInfo { hasNextPage endCursor }
                nodes {
                  isResolved isOutdated path line
                  comments(first: 30) { nodes { author { login } body url } }
                }
              }
            }
          }
        }
        """

    static let reviewText = """
        query PendingReview($id: ID!) {
          node(id: $id) {
            ... on PullRequestReview { state viewerDidAuthor commit { oid } }
          }
        }
        """

    // The context of a review of the PR for the viewer. The threads of the viewer are read only
    // when the viewer has a submitted review.
    package static func context(
        _ pr: PRKey, viewer: String, on github: GitHubClient
    ) async throws(GitHubError) -> ReviewContext {
        var head: ReviewContext?
        var reviews: [ViewerReview] = []
        var truncated = false
        var after: String?
        for page in 1...maxPages {
            let query = GitHubQuery(
                name: contextName, text: contextText,
                variables: variables(pr).merging([
                    "login": .string(viewer), "after": after.map(GraphQLValue.string) ?? .null,
                    "head": .bool(page == 1),
                ]) { first, _ in first })
            let answer = try ReviewAnswer.contextPage(
                await github.read(query), pr: pr, withHead: page == 1
            ).get()
            if page == 1 { head = answer.head }
            reviews += answer.reviews
            after = answer.next
            if after == nil { break }
            if page == maxPages { truncated = true }
        }
        guard var context = head else { throw .badAnswer }
        context.reviews = reviews
        if reviews.contains(where: { $0.state != .pending }) {
            let threads = try await threadsOfViewer(pr, viewer: viewer, on: github)
            context.threads = threads.threads
            truncated = truncated || threads.truncated
        }
        context.truncated = truncated
        return context
    }

    // The state of a review now: still pending, and by the viewer.
    package static func review(
        _ id: NodeID, on github: GitHubClient
    ) async throws(GitHubError) -> ReviewAnswer.ReviewNow {
        let query = GitHubQuery(
            name: reviewName, text: reviewText, variables: ["id": .string(id.text)])
        return try ReviewAnswer.reviewNow(await github.read(query)).get()
    }

    private static func threadsOfViewer(
        _ pr: PRKey, viewer: String, on github: GitHubClient
    ) async throws(GitHubError) -> (threads: [ViewerThread], truncated: Bool) {
        var threads: [ViewerThread] = []
        var after: String?
        for page in 1...maxPages {
            let query = GitHubQuery(
                name: threadsName, text: threadsText,
                variables: variables(pr).merging([
                    "after": after.map(GraphQLValue.string) ?? .null
                ]) { first, _ in first })
            let answer = try ReviewAnswer.threadsPage(await github.read(query), viewer: viewer)
                .get()
            threads += answer.threads
            after = answer.next
            if after == nil { return (threads, false) }
            if page == maxPages { return (threads, true) }
        }
        return (threads, false)
    }

    private static func variables(_ pr: PRKey) -> [String: GraphQLValue] {
        [
            "owner": .string(pr.repo.owner), "repo": .string(pr.repo.name),
            "number": .int(pr.number),
        ]
    }
}
