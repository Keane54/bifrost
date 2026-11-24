// The full read of a PR of the user before a request round (docs/behaviour/reviews.md, "Request
// rounds"): every thread, comment and review, with pages. Each read is a GitHubQuery: a GraphQL
// query with its values in variables, never in the text. Each list reads at most maxPages pages,
// and one read makes at most maxCalls calls: the three main lists come first, so the long threads
// can't use their part of the calls. A list that stops at a limit makes the read cut
// (FullPR.truncated). FullPRAnswer reads the answers.
import BifrostFoundation
import Foundation

@MainActor
package enum RequestQueries {
    package static let maxPages = 10
    // The three main lists need at most 30 calls, so 170 calls stay for the long threads. Without
    // this limit, a busy PR could need thousands of calls of the hourly GitHub budget.
    package static let maxCalls = 200
    package static let contextName = "requestContext"
    package static let threadsName = "requestThreads"
    package static let commentsName = "requestComments"
    package static let threadCommentsName = "threadComments"
    package static let stateName = "requestState"

    private static let author = "author { login __typename } authorAssociation"
    private static let comment = "id databaseId \(author) body createdAt url"

    // The PR fields come with the first page of the reviews.
    static let contextText = """
        query RequestContext(
          $owner: String!, $repo: String!, $number: Int!, $after: String, $head: Boolean!
        ) {
          repository(owner: $owner, name: $repo) {
            pullRequest(number: $number) {
              id @include(if: $head)
              url @include(if: $head)
              title @include(if: $head)
              body @include(if: $head)
              state @include(if: $head)
              author @include(if: $head) { login }
              isCrossRepository @include(if: $head)
              baseRefName @include(if: $head)
              baseRefOid @include(if: $head)
              headRefName @include(if: $head)
              headRefOid @include(if: $head)
              updatedAt @include(if: $head)
              repository @include(if: $head) { defaultBranchRef { name } }
              latestOpinionatedReviews(first: 100) @include(if: $head) {
                pageInfo { hasNextPage }
                nodes { state author { login __typename ... on User { id } } }
              }
              reviewRequests(first: 100) @include(if: $head) {
                pageInfo { hasNextPage }
                nodes { requestedReviewer { __typename ... on User { login } } }
              }
              pending: reviews(states: PENDING, first: 10) @include(if: $head) {
                nodes { viewerDidAuthor }
              }
              reviews(first: 100, after: $after) {
                pageInfo { hasNextPage endCursor }
                nodes { id databaseId \(author) state body submittedAt commit { oid } url }
              }
            }
          }
        }
        """

    static let threadsText = """
        query RequestThreads($owner: String!, $repo: String!, $number: Int!, $after: String) {
          repository(owner: $owner, name: $repo) {
            pullRequest(number: $number) {
              reviewThreads(first: 50, after: $after) {
                pageInfo { hasNextPage endCursor }
                nodes {
                  id isResolved isOutdated path line viewerCanReply
                  comments(first: 50) {
                    pageInfo { hasNextPage endCursor }
                    nodes { \(comment) pullRequestReview { id } diffHunk }
                  }
                }
              }
            }
          }
        }
        """

    static let threadCommentsText = """
        query ThreadComments($id: ID!, $after: String) {
          node(id: $id) {
            ... on PullRequestReviewThread {
              comments(first: 100, after: $after) {
                pageInfo { hasNextPage endCursor }
                nodes { \(comment) pullRequestReview { id } }
              }
            }
          }
        }
        """

    static let commentsText = """
        query RequestComments($owner: String!, $repo: String!, $number: Int!, $after: String) {
          repository(owner: $owner, name: $repo) {
            pullRequest(number: $number) {
              comments(first: 100, after: $after) {
                pageInfo { hasNextPage endCursor }
                nodes { \(comment) }
              }
            }
          }
        }
        """

    // Only the state of the PR: the check before each write of a request round.
    static let stateText = """
        query RequestState($owner: String!, $repo: String!, $number: Int!) {
          repository(owner: $owner, name: $repo) {
            pullRequest(number: $number) {
              state
            }
          }
        }
        """

    private static func stateQuery(_ pr: PRKey) -> GitHubQuery {
        GitHubQuery(
            name: stateName, text: stateText,
            variables: [
                "owner": .string(pr.repo.owner), "repo": .string(pr.repo.name),
                "number": .int(pr.number),
            ])
    }

    // The state of the PR on GitHub: open, closed or merged. An answer with no known state is a
    // bad answer.
    package static func state(_ pr: PRKey, client: GitHubClient) async throws(GitHubError)
        -> PRLifecycle
    {
        let data = try await client.read(stateQuery(pr))
        let answer = try? JSONDecoder().decode(JSONValue.self, from: data)
        let pull = answer?.object?["data"]?.object?["repository"]?.object?["pullRequest"]
        guard let text = pull?.object?["state"]?.string, let state = PRLifecycle(rawValue: text)
        else { throw .badAnswer }
        return state
    }

    // The same read for a PR that the search of the poll does not list (ReviewRounds.dropIfClosed).
    // The result is nil when GitHub says that the PR, or its repository, is not found: the
    // answer has a NOT_FOUND error and a null for the PR or the repository. Each other answer
    // without a known state is a bad answer.
    package static func stateOrGone(_ pr: PRKey, client: GitHubClient) async throws(GitHubError)
        -> PRLifecycle?
    {
        let data = try await client.read(stateQuery(pr))
        let answer = try? JSONDecoder().decode(JSONValue.self, from: data)
        let repository = answer?.object?["data"]?.object?["repository"]
        let pull = repository?.object?["pullRequest"]
        if let text = pull?.object?["state"]?.string, let state = PRLifecycle(rawValue: text) {
            return state
        }
        let notFound =
            answer?.object?["errors"]?.array?.contains {
                $0.object?["type"]?.string == "NOT_FOUND"
            } ?? false
        if notFound, repository == .null || (repository?.object != nil && pull == .null) {
            return nil
        }
        throw .badAnswer
    }

    // The PR with every thread, comment and review that the limits allow.
    package static func full(_ pr: PRKey, client: GitHubClient) async throws(GitHubError)
        -> FullPR
    {
        var budget = maxCalls
        let base: [String: GraphQLValue] = [
            "owner": .string(pr.repo.owner), "repo": .string(pr.repo.name),
            "number": .int(pr.number),
        ]
        func after(_ cursor: String?) -> GraphQLValue { cursor.map(GraphQLValue.string) ?? .null }

        var head: FullPR?
        var reviews: [PRReview] = []
        let contextCut = try await pages(&budget) { cursor, page throws(GitHubError) in
            let query = GitHubQuery(
                name: contextName, text: contextText,
                variables: base.merging(["after": after(cursor), "head": .bool(page == 1)]) {
                    first, _ in first
                })
            let answer = try FullPRAnswer.contextPage(
                await client.read(query), pr: pr, withHead: page == 1
            ).get()
            if page == 1 { head = answer.head }
            reviews += answer.reviews
            return (answer.next, answer.cut)
        }
        guard var full = head else { throw .badAnswer }

        var entries: [FullPRAnswer.ThreadEntry] = []
        let threadsCut = try await pages(&budget) { cursor, _ throws(GitHubError) in
            let query = GitHubQuery(
                name: threadsName, text: threadsText,
                variables: base.merging(["after": after(cursor)]) { first, _ in first })
            let answer = try FullPRAnswer.threadsPage(await client.read(query)).get()
            entries += answer.threads
            return (answer.next, answer.cut)
        }

        var comments: [PRComment] = []
        let commentsCut = try await pages(&budget) { cursor, _ throws(GitHubError) in
            let query = GitHubQuery(
                name: commentsName, text: commentsText,
                variables: base.merging(["after": after(cursor)]) { first, _ in first })
            let answer = try FullPRAnswer.commentsPage(await client.read(query)).get()
            comments += answer.comments
            return (answer.next, answer.cut)
        }

        var cut = contextCut || threadsCut || commentsCut
        var threads: [FullThread] = []
        for entry in entries {
            var thread = entry.thread
            cut = cut || entry.cut
            if let more = entry.moreComments {
                // The first page of the comments came with the thread.
                let id = thread.thread.id
                let longCut = try await pages(&budget, from: (more, 2)) {
                    cursor, _ throws(GitHubError) in
                    let query = GitHubQuery(
                        name: threadCommentsName, text: threadCommentsText,
                        variables: ["id": .string(id.text), "after": after(cursor)])
                    let answer = try FullPRAnswer.threadCommentsPage(await client.read(query))
                        .get()
                    thread.thread.comments += answer.comments
                    return (answer.next, answer.cut)
                }
                cut = cut || longCut
            }
            threads.append(thread)
        }
        full.reviews = reviews
        full.threads = threads
        full.comments = comments
        full.truncated = cut
        return full
    }

    // Read the pages of one list, from the page of start, at most maxPages pages in all. Each
    // call uses one call of the budget; with no call left, the list stops. read gives the cursor
    // of the next page (nil at the end) and whether the list is cut there. The result is true
    // when the list stopped before its end.
    private static func pages(
        _ budget: inout Int, from start: (cursor: String?, page: Int) = (nil, 1),
        _ read: (String?, Int) async throws(GitHubError) -> (next: String?, cut: Bool)
    ) async throws(GitHubError) -> Bool {
        var cursor = start.cursor
        var page = start.page
        while true {
            guard budget > 0 else { return true }
            budget -= 1
            let (next, cut) = try await read(cursor, page)
            guard let next else { return cut }
            if page >= maxPages { return true }
            cursor = next
            page += 1
        }
    }
}
