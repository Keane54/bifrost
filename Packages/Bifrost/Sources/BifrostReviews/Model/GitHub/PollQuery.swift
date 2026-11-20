// The one GraphQL read of a poll (docs/behaviour/reviews.md, "The GitHub data"). It asks for both
// lists at once, so a poll costs one call. The two search texts go in variables.

package enum PollQuery {
    package static let name = "poll"
    package static let toReviewSearch = "is:pr is:open review-requested:@me archived:false"
    package static let mineSearch = "is:pr is:open author:@me archived:false"

    // The limits of the lists of one PR. A list with more than its limit is marked cut.
    package static let pullRequestsPerSearch = 50
    package static let reviewsLimit = 30, opinionsLimit = 20, threadsLimit = 20
    package static let threadCommentsLimit = 10, commentsLimit = 30, checksLimit = 20
    // A PR of the user reads more checks, because the CI rounds act only on a full list.
    package static let mineChecksLimit = 50

    package static var query: GitHubQuery {
        GitHubQuery(
            name: name, text: text,
            variables: ["toReview": .string(toReviewSearch), "mine": .string(mineSearch)])
    }

    private static let author = "author { login __typename } authorAssociation"
    private static let reviewer =
        "requestedReviewer { __typename ... on User { login } ... on Team { slug } }"

    // The fields of both kinds of PR. A PR of the To review list reads no reviews, threads or
    // comments.
    private static let head = """
        number title isDraft additions deletions createdAt updatedAt
        repository { name owner { login } }
        author { login }
        reviewDecision
        reviewRequests(first: 10) { nodes { \(reviewer) } }
        timelineItems(last: 10, itemTypes: [REVIEW_REQUESTED_EVENT]) {
          nodes { ... on ReviewRequestedEvent { createdAt \(reviewer) } }
        }
        pendingReviews: reviews(states: PENDING, first: 1) { nodes { id } }
        """

    // The checks of the newest commit, the first limit of them, and the head and base of the PR.
    // A check run names its app and, for GitHub Actions, its job and its workflow run. HeadQueries
    // reads the same fields.
    static func checks(_ limit: Int) -> String {
        """
        commits(last: 1) {
          nodes {
            commit {
              oid
              statusCheckRollup {
                state
                contexts(first: \(limit)) {
                  pageInfo { hasNextPage }
                  nodes {
                    __typename
                    ... on CheckRun {
                      name status conclusion databaseId detailsUrl
                      checkSuite { app { slug } workflowRun { databaseId } }
                    }
                    ... on StatusContext { context state targetUrl }
                  }
                }
              }
            }
          }
        }
        headRefName headRefOid baseRefName isCrossRepository
        """
    }

    // The merge state and the base commit: only a PR of the user reads them.
    static let mergeState = "mergeable baseRefOid"

    // The latest opinion of each reviewer. A To review row reads the opinion of the viewer and
    // counts the approvals of the others.
    private static let opinions = """
        latestOpinionatedReviews(first: \(opinionsLimit)) {
          pageInfo { hasNextPage }
          nodes { id \(author) state submittedAt commit { oid } }
        }
        """

    private static let conversation = """
        reviews(first: \(reviewsLimit)) {
          pageInfo { hasNextPage }
          nodes { id databaseId \(author) state body submittedAt commit { oid } url }
        }
        reviewThreads(last: \(threadsLimit)) {
          pageInfo { hasPreviousPage }
          nodes {
            id isResolved path line
            comments(first: \(threadCommentsLimit)) {
              pageInfo { hasNextPage }
              nodes { id databaseId \(author) body createdAt url pullRequestReview { id } }
            }
          }
        }
        comments(last: \(commentsLimit)) {
          pageInfo { hasPreviousPage }
          nodes { id databaseId \(author) body createdAt url }
        }
        """

    private static let text = """
        query Poll($toReview: String!, $mine: String!) {
          viewer { login }
          toReview: search(query: $toReview, type: ISSUE, first: \(pullRequestsPerSearch)) {
            pageInfo { hasNextPage }
            nodes { ... on PullRequest { ...ToReviewFields } }
          }
          mine: search(query: $mine, type: ISSUE, first: \(pullRequestsPerSearch)) {
            pageInfo { hasNextPage }
            nodes { ... on PullRequest { ...MineFields } }
          }
        }
        fragment ToReviewFields on PullRequest { \(head) \(opinions) \(checks(checksLimit)) }
        fragment MineFields on PullRequest {
          \(head) \(opinions) \(conversation) \(checks(mineChecksLimit)) \(mergeState)
        }
        """
}
