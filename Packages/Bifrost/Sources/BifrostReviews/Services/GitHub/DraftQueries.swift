// The reads of the Approve button and of the Review panel (docs/behaviour/reviews.md, "Approve"
// and "The Review panel"). Each read is a GitHubQuery: a GraphQL query with its values in
// variables, never in the text. The fresh read gives the PR just before a write (FreshPR), and
// the draft read gives Claude's draft review with its comments, at most DraftEdits.maxComments.
// The state of a review just before an edit is ReviewQueries.review. The own reviews read checks
// whether an unsure Comment of the findings form reached GitHub, as a poll never lists a comment.
import BifrostFoundation
import Foundation

@MainActor
package enum DraftQueries {
    package static let freshName = "draftContext"
    package static let draftName = "draftReview"
    package static let ownReviewsName = "ownReviews"

    // The PR, the CI of its head, the pending reviews (only the viewer sees a pending review),
    // and the newest opinions of the viewer.
    static let freshText = """
        query DraftContext($owner: String!, $repo: String!, $number: Int!, $login: String!) {
          repository(owner: $owner, name: $repo) {
            pullRequest(number: $number) {
              id url state headRefOid
              author { login }
              commits(last: 1) { nodes { commit { oid statusCheckRollup { state } } } }
              pending: reviews(states: PENDING, first: 10) {
                nodes { id body viewerDidAuthor commit { oid } }
              }
              opinions: reviews(
                author: $login, states: [APPROVED, CHANGES_REQUESTED, DISMISSED], last: 20
              ) {
                nodes { state submittedAt commit { oid } }
              }
            }
          }
        }
        """

    // The latest finished reviews of the viewer on the PR, with their state, time and commit.
    static let ownReviewsText = """
        query OwnReviews($owner: String!, $repo: String!, $number: Int!, $login: String!) {
          repository(owner: $owner, name: $repo) {
            pullRequest(number: $number) {
              reviews(
                author: $login, states: [COMMENTED, APPROVED, CHANGES_REQUESTED], last: 20
              ) {
                nodes { state submittedAt commit { oid } }
              }
            }
          }
        }
        """

    static let draftText = """
        query DraftReview($id: ID!, $after: String) {
          node(id: $id) {
            ... on PullRequestReview {
              id state body viewerDidAuthor
              commit { oid }
              comments(first: \(DraftEdits.pageSize), after: $after) {
                pageInfo { hasNextPage endCursor }
                nodes { id path line startLine originalLine originalStartLine diffHunk body }
              }
            }
          }
        }
        """

    // The PR as GitHub gives it now, for the viewer.
    package static func fresh(
        _ pr: PRKey, viewer: String, on github: GitHubClient
    ) async throws(GitHubError) -> FreshPR {
        let query = GitHubQuery(
            name: freshName, text: freshText,
            variables: [
                "owner": .string(pr.repo.owner), "repo": .string(pr.repo.name),
                "number": .int(pr.number), "login": .string(viewer),
            ])
        return try FreshPR.decode(await github.read(query)).get()
    }

    // Your own latest finished reviews on the PR.
    package static func ownReviews(
        _ pr: PRKey, viewer: String, on github: GitHubClient
    ) async throws(GitHubError) -> [ViewerOpinion] {
        let query = GitHubQuery(
            name: ownReviewsName, text: ownReviewsText,
            variables: [
                "owner": .string(pr.repo.owner), "repo": .string(pr.repo.name),
                "number": .int(pr.number), "login": .string(viewer),
            ])
        return try FindingsPlan.ownReviews(await github.read(query)).get()
    }

    // The draft review with its comments, page by page. A review with more comments than
    // DraftEdits.maxComments is marked truncated.
    package static func draft(
        _ review: NodeID, on github: GitHubClient
    ) async throws(GitHubError) -> DraftRead {
        var draft: DraftRead?
        var after: String?
        let pages = DraftEdits.maxComments / DraftEdits.pageSize
        for page in 1...pages {
            let query = GitHubQuery(
                name: draftName, text: draftText,
                variables: [
                    "id": .string(review.text), "after": after.map(GraphQLValue.string) ?? .null,
                ])
            let answer = try DraftRead.page(await github.read(query)).get()
            if var whole = draft {
                whole.comments += answer.draft.comments
                draft = whole
            } else {
                draft = answer.draft
            }
            after = answer.next
            if after == nil { break }
            if page == pages { draft?.truncated = true }
        }
        guard let draft else { throw .badAnswer }
        return draft
    }
}
