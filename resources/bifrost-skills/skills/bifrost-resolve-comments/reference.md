# bifrost-resolve-comments: the calls

Put the real values in place of the words in capitals. Take OWNER, REPO and NUMBER from the URL of
the PR: `https://github.com/OWNER/REPO/pull/NUMBER`.

Only the sections "Push" and "Reply and resolve" write to GitHub. Run them only after the user
confirms.

## The PR

```sh
gh pr view NUMBER_OR_URL --json number,url,state,author,headRefName,headRefOid \
  --json isCrossRepository,headRepository,headRepositoryOwner
gh api user --jq .login
```

With no argument, leave out NUMBER_OR_URL. `gh` then uses the PR of the current branch.

- The second command gives LOGIN. `author.login` must be LOGIN.
- `headRefName` is HEAD_BRANCH. `headRefOid` is HEAD_SHA.
- `headRepository.nameWithOwner` is the repository to push to.
- `isCrossRepository: true` means that the head branch is in a fork. Push only when
  `headRepositoryOwner.login` is LOGIN.

## Check the local branch

```sh
git branch --show-current
git rev-parse --abbrev-ref '@{upstream}'
git remote get-url origin
git fetch origin HEAD_BRANCH
git merge-base --is-ancestor HEAD_SHA HEAD && echo 'contains the PR head'
git status --porcelain
```

- The current branch is the head branch when its name is HEAD_BRANCH or its upstream is
  `origin/HEAD_BRANCH`.
- `origin` must name the head repository.
- No output from the `merge-base` line means that the local branch is behind GitHub. After the user
  agrees, merge with `git merge --no-edit FETCH_HEAD`. Never rebase.
- `git status --porcelain` lists the changes that were there before you. Leave them alone.

## Read the comments

Each command prints a JSON array with one item for each page.

The review threads:

```sh
gh api graphql --paginate --slurp -f owner=OWNER -f repo=REPO -F number=NUMBER -f query='
query($owner: String!, $repo: String!, $number: Int!, $endCursor: String) {
  repository(owner: $owner, name: $repo) {
    pullRequest(number: $number) {
      reviewThreads(first: 50, after: $endCursor) {
        pageInfo { hasNextPage endCursor }
        nodes {
          id
          isResolved
          isOutdated
          viewerCanReply
          viewerCanResolve
          path
          line
          comments(first: 100) {
            nodes { author { __typename login } authorAssociation body path line createdAt url }
          }
        }
      }
    }
  }
}'
```

The `id` of a thread is THREAD_ID. When `viewerCanReply` or `viewerCanResolve` is false, tell the
user, and do not post on that thread.

The PR comments:

```sh
gh api graphql --paginate --slurp -f owner=OWNER -f repo=REPO -F number=NUMBER -f query='
query($owner: String!, $repo: String!, $number: Int!, $endCursor: String) {
  repository(owner: $owner, name: $repo) {
    pullRequest(number: $number) {
      comments(first: 100, after: $endCursor) {
        pageInfo { hasNextPage endCursor }
        nodes { author { __typename login } authorAssociation body createdAt url }
      }
    }
  }
}'
```

The reviews:

```sh
gh api graphql --paginate --slurp -f owner=OWNER -f repo=REPO -F number=NUMBER -f query='
query($owner: String!, $repo: String!, $number: Int!, $endCursor: String) {
  repository(owner: $owner, name: $repo) {
    pullRequest(number: $number) {
      reviews(first: 100, after: $endCursor) {
        pageInfo { hasNextPage endCursor }
        nodes { author { __typename login } authorAssociation state body submittedAt url }
      }
    }
  }
}'
```

Copilot shows as `{"__typename": "Bot", "login": "copilot-pull-request-reviewer"}`. Find Copilot by
these two values, not by its `authorAssociation`, which can be `NONE` or `CONTRIBUTOR`.

## Push

```sh
git fetch origin HEAD_BRANCH
git merge-base --is-ancestor FETCH_HEAD HEAD && echo 'safe to push'
git push origin HEAD:HEAD_BRANCH
```

- Push only when the second line prints its text. Else merge first with
  `git merge --no-edit FETCH_HEAD`, run the checks again, and check again.
- If GitHub refuses the push, run the fetch and the merge again, run the checks again, then push
  one more time.
- After the push, the head of the PR must be the local head:

```sh
gh pr view NUMBER --repo OWNER/REPO --json headRefOid --jq .headRefOid
git rev-parse HEAD
```

The short SHA for a reply comes from `git rev-parse --short COMMIT`.

## Reply and resolve

The body goes on stdin with a quoted heredoc, so that the shell changes nothing in the text.

Reply to a thread. Do not pass `pullRequestReviewId`: with it, the reply goes into a pending review.

```sh
gh api graphql -f thread=THREAD_ID -F body=@- -f query='
mutation($thread: ID!, $body: String!) {
  addPullRequestReviewThreadReply(input: {pullRequestReviewThreadId: $thread, body: $body}) {
    comment { url state }
  }
}' <<'BIFROST_BODY'
Fixed by abc1234
BIFROST_BODY
```

The answer must show `"state": "SUBMITTED"`. Then resolve the thread:

```sh
gh api graphql -f thread=THREAD_ID -f query='
mutation($thread: ID!) {
  resolveReviewThread(input: {threadId: $thread}) {
    thread { id isResolved }
  }
}'
```

The answer must show `"isResolved": true`.

Reply to a top-level comment with a new PR comment. Put `> ` before each quoted line.

```sh
gh pr comment NUMBER --repo OWNER/REPO --body-file - <<'BIFROST_BODY'
> The request, quoted.

Fixed by abc1234
BIFROST_BODY
```

If an answer holds `errors`, stop and show them.

## Never

- `git push --force`, `git push --force-with-lease`, or a push to another repository or branch.
- `git rebase` or `git pull --rebase`.
- `gh pr review` (each form submits a review) and `gh pr merge`.
- The GraphQL mutations `submitPullRequestReview`, `mergePullRequest` and
  `enablePullRequestAutoMerge`.
