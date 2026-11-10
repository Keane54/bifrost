# bifrost-review: the calls

Put the real values in place of the words in capitals. Take OWNER, REPO and NUMBER from the URL of
the PR: `https://github.com/OWNER/REPO/pull/NUMBER`. HEAD_SHA is the `headRefOid` of the PR.

Only two sections write to GitHub: "Create the pending review" and "Add to the pending review".
Run them only after the user confirms. Nothing in this file submits a review.

## The PR

```sh
gh pr view NUMBER_OR_URL --json \
  number,url,title,body,author,state,isDraft,baseRefName,baseRefOid,headRefName,headRefOid,commits
```

With no argument, leave out NUMBER_OR_URL. `gh` then uses the PR of the current branch.

Linked issues:

```sh
gh pr view NUMBER --repo OWNER/REPO --json closingIssuesReferences
```

## The user

```sh
gh api user --jq .login
```

This is LOGIN.

## The full diff

```sh
gh pr diff NUMBER --repo OWNER/REPO
```

If GitHub says that the diff is too large, read the patch of each file:

```sh
gh api --paginate repos/OWNER/REPO/pulls/NUMBER/files --jq '.[] | {filename, status, patch}'
```

A file with no `patch` is binary or too large. Read it at the head commit if you need it.

The hunk headers give the lines that a comment can use. In `@@ -a,b +c,d @@`, the lines c to
c+d-1 of the head version (side `RIGHT`) and the lines a to a+b-1 of the base version (side
`LEFT`) are in the diff.

## Files at the head commit

When the current folder is a clone of OWNER/REPO (`git remote get-url origin` names it), fetch the
head commit and read it with git. The fetch changes no branch and no file in the working tree.

```sh
git fetch origin refs/pull/NUMBER/head
git show HEAD_SHA:FILE_PATH
git grep -n 'PATTERN' HEAD_SHA -- 'PATH_GLOB'
```

Else read each file through the API:

```sh
gh api -H 'Accept: application/vnd.github.raw+json' \
  'repos/OWNER/REPO/contents/FILE_PATH?ref=HEAD_SHA'
```

## The last review of the user

```sh
gh api --paginate repos/OWNER/REPO/pulls/NUMBER/reviews \
  --jq '.[] | select(.user.login == "LOGIN" and .state != "PENDING") | .commit_id' | tail -n 1
```

GitHub lists the reviews in time order, so the last line is the newest review. No output means
that this is a first review. Else the output is LAST_SHA.

## Changes since the last review

```sh
gh api repos/OWNER/REPO/compare/LAST_SHA...HEAD_SHA \
  --jq '{status, ahead_by, files: [.files[].filename]}'
gh api -H 'Accept: application/vnd.github.diff' repos/OWNER/REPO/compare/LAST_SHA...HEAD_SHA
```

- `ahead`: the normal case. The diff holds the commits since the last review.
- `identical`: nothing changed since the last review.
- `diverged` or `behind`, or HTTP 404: the history was rewritten. Review the full PR.

The comparison lists 300 files at most. If it has more, read the full diff for the rest.

## Earlier comments of the user

The threads:

```sh
gh api graphql --paginate --slurp -f owner=OWNER -f repo=REPO -F number=NUMBER -f query='
query($owner: String!, $repo: String!, $number: Int!, $endCursor: String) {
  repository(owner: $owner, name: $repo) {
    pullRequest(number: $number) {
      reviewThreads(first: 50, after: $endCursor) {
        pageInfo { hasNextPage endCursor }
        nodes {
          isResolved
          isOutdated
          path
          line
          comments(first: 100) {
            nodes { author { login } body createdAt url }
          }
        }
      }
    }
  }
}'
```

The output is a JSON array with one item for each page. The user started a thread when its first
comment has the login LOGIN. The later comments in the thread hold the answers.

The summaries of the earlier reviews:

```sh
gh api --paginate repos/OWNER/REPO/pulls/NUMBER/reviews \
  --jq '.[] | select(.user.login == "LOGIN" and .state != "PENDING" and .body != "")
    | {state, submitted_at, body, html_url}'
```

## The pending review of the user

```sh
gh api graphql -f owner=OWNER -f repo=REPO -F number=NUMBER -f query='
query($owner: String!, $repo: String!, $number: Int!) {
  repository(owner: $owner, name: $repo) {
    pullRequest(number: $number) {
      headRefOid
      reviews(states: [PENDING], first: 10) {
        nodes { id body viewerDidAuthor commit { oid } }
      }
    }
  }
}'
```

The node with `"viewerDidAuthor": true` is the pending review of the user. Its `id` is REVIEW_ID.
`headRefOid` is the head commit now: compare it with HEAD_SHA.

## Create the pending review

Only after the user confirms. Send the JSON on stdin with a quoted heredoc, so that the shell
changes nothing in the text. Write each body as a JSON string: `\n` for a new line, `\"` for a
quote.

- Leave out `event`. With no `event`, GitHub keeps the review pending.
- Leave out `body` when there is no summary. Leave out `comments` when there are none.
- Each comment has `path`, `line`, `side` and `body`. A comment on a range also has `start_line`
  and `start_side`.

```sh
gh api --method POST repos/OWNER/REPO/pulls/NUMBER/reviews --input - \
  --jq '{id, state, html_url}' <<'BIFROST_JSON'
{
  "commit_id": "HEAD_SHA",
  "body": "The summary.",
  "comments": [
    { "path": "src/a.ts", "line": 42, "side": "RIGHT", "body": "One problem." },
    {
      "path": "src/b.ts",
      "start_line": 10,
      "start_side": "RIGHT",
      "line": 14,
      "side": "RIGHT",
      "body": "A problem in a range of lines."
    }
  ]
}
BIFROST_JSON
```

The answer must show `"state": "PENDING"`. If it shows another state, tell the user at once.

## Add to the pending review

Only after the user confirms. Make one call for each comment. The body goes on stdin, so that the
shell changes nothing in it. For a range, add `-F startLine=FIRST_LINE -f startSide=RIGHT`.

```sh
gh api graphql -f review=REVIEW_ID -f path=FILE_PATH -F line=LINE -f side=RIGHT -F body=@- \
  -f query='
mutation($review: ID!, $path: String!, $line: Int!, $side: DiffSide!, $body: String!,
    $startLine: Int, $startSide: DiffSide) {
  addPullRequestReviewThread(input: {
    pullRequestReviewId: $review, path: $path, line: $line, side: $side,
    startLine: $startLine, startSide: $startSide, body: $body
  }) {
    thread { id }
  }
}' <<'BIFROST_BODY'
The comment.
BIFROST_BODY
```

Set the summary as the body, only when the body of the pending review is empty:

```sh
gh api graphql -f review=REVIEW_ID -F body=@- -f query='
mutation($review: ID!, $body: String!) {
  updatePullRequestReview(input: {pullRequestReviewId: $review, body: $body}) {
    pullRequestReview { id state }
  }
}' <<'BIFROST_BODY'
The summary.
BIFROST_BODY
```

If an answer holds `errors`, stop and show them.

## Never

These calls submit, approve, request changes, dismiss, delete or merge. Never run them.

- `gh pr review`, with any flag. Each form submits a review.
- `gh pr merge`.
- `POST repos/OWNER/REPO/pulls/NUMBER/reviews` with an `event` field.
- `POST repos/OWNER/REPO/pulls/NUMBER/reviews/REVIEW_ID/events`.
- `PUT repos/OWNER/REPO/pulls/NUMBER/reviews/REVIEW_ID/dismissals`.
- The GraphQL mutations `submitPullRequestReview`, `dismissPullRequestReview`,
  `deletePullRequestReview`, `mergePullRequest` and `enablePullRequestAutoMerge`, and
  `addPullRequestReview` with an `event`.
