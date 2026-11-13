// The GitHub writes of src/main. R2 writes a pending review: create one with POST
// repos/<owner>/<repo>/pulls/<n>/reviews and no event field, or add threads to the pending review
// of the user and set its body. R3 replies to a thread, resolves a thread, adds a PR comment and
// asks a reviewer for a new review, each in reviews/request-writes.ts. When the user turns on
// signed commits, R3 also sends the fix commit with createCommitOnBranch, in the same file, with
// its body on stdin. Only reviews/request-push.ts calls that write. Bifrost never submits,
// approves, requests changes, dismisses, deletes, edits, hides, unresolves or merges, and it never
// closes, reopens, changes or converts a PR. This test reads each .ts file of src/main and fails
// when a call or a field for one of these shows up. Where it can, a rule allows a known form, and
// refuses all others. If a pattern finds a harmless text in a file, make the pattern more exact.
// Never remove a pattern.

import { readdirSync, readFileSync } from 'node:fs'
import { join } from 'node:path'
import { fileURLToPath } from 'node:url'
import { describe, expect, it } from 'vitest'

const MAIN = fileURLToPath(new URL('../../../src/main/', import.meta.url))
// The path of each file is relative to src/main, with forward slashes. POSTERS gives each file
// that holds a GraphQL mutation, with the mutation fields that it can use.
const POSTERS: Record<string, readonly string[]> = {
  'reviews/pending-review.ts': ['addPullRequestReviewThread', 'updatePullRequestReview'],
  'reviews/request-writes.ts': [
    'addPullRequestReviewThreadReply',
    'resolveReviewThread',
    'addComment',
    'requestReviews',
    'createCommitOnBranch',
  ],
}
// The only file with the REST create call of a pending review.
const POSTER = 'reviews/pending-review.ts'
const REQUEST_WRITES = 'reviews/request-writes.ts'
// The only file that calls the signed commit write of request-writes.ts.
const SIGNED_PUSHER = 'reviews/request-push.ts'
// The one gh call of request-writes.ts that sends its body on stdin: the signed commit.
const COMMIT_CALL = /\[\s*'api'\s*,\s*'graphql'\s*,\s*'--input'\s*,\s*'-'\s*,?\s*\]/g
const isPoster = (file: string): boolean => Object.hasOwn(POSTERS, file)
const fieldsOf = (file: string): readonly string[] => (isPoster(file) ? (POSTERS[file] ?? []) : [])
const FORBIDDEN_NAMES = [
  'submitPullRequestReview',
  'dismissPullRequestReview',
  'deletePullRequestReview',
  'mergePullRequest',
  'enablePullRequestAutoMerge',
]
// Each of these names is matched as a whole word, so updatePullRequest does not find
// updatePullRequestReview.
const FORBIDDEN_WORDS = [
  'unresolveReviewThread',
  'deleteIssueComment',
  'updateIssueComment',
  'deletePullRequestReviewComment',
  'updatePullRequestReviewComment',
  'minimizeComment',
  'closePullRequest',
  'reopenPullRequest',
  'updatePullRequest',
  'updatePullRequestBranch',
  'convertPullRequestToDraft',
  'markPullRequestReadyForReview',
  'addPullRequestReview',
  'requestReviewsByLogin',
  'createRef',
  'updateRef',
  'deleteRef',
]
// The event values of a GitHub review (REST and GraphQL).
const REVIEW_EVENT = 'APPROVE|REQUEST_CHANGES|COMMENT|DISMISS'

const count = (text: string, pattern: RegExp): number => text.match(pattern)?.length ?? 0

// The top-level commands of gh, each with its subcommands. api takes a path, not a subcommand.
// A command with no subcommands (browse, completion, status) never counts as a gh call.
const GH_COMMANDS: Record<string, string> = {
  'agent-task': 'create list view',
  alias: 'delete import list set',
  api: '',
  attestation: 'download trusted-root verify',
  auth: 'login logout refresh setup-git status switch token',
  browse: '',
  cache: 'delete list',
  codespace: 'code cp create delete edit jupyter list logs ports rebuild ssh stop view',
  completion: '',
  config: 'clear-cache get list set',
  extension: 'browse create exec install list remove search upgrade',
  gist: 'clone create delete edit list rename view',
  'gpg-key': 'add delete list',
  issue:
    'close comment create delete develop edit list lock pin reopen status transfer unlock ' +
    'unpin view',
  label: 'clone create delete edit list',
  org: 'list',
  pr:
    'checkout checks close comment create diff edit list lock merge ready reopen revert review ' +
    'status unlock update-branch view',
  preview: 'prompter',
  project:
    'close copy create delete edit field-create field-delete field-list item-add item-archive ' +
    'item-create item-delete item-edit item-list link list mark-template unlink view',
  release: 'create delete delete-asset download edit list upload verify verify-asset view',
  repo:
    'archive autolink clone create delete deploy-key edit fork gitignore license list rename ' +
    'set-default sync unarchive view',
  ruleset: 'check list view',
  run: 'cancel delete download list rerun view watch',
  search: 'code commits issues prs repos',
  secret: 'delete list set',
  'ssh-key': 'add delete list',
  status: '',
  variable: 'delete get list set',
  workflow: 'disable enable list run view',
}

// The start of an argument list: an array, or a push, unshift or concat, with the name of a gh
// command first.
const GH_START = new RegExp(
  `(?:\\[|\\b(?:push|unshift|concat)\\()\\s*(['"\`])(${Object.keys(GH_COMMANDS).join('|')})\\1`,
  'g',
)
// The items after 'api' of the create call of pending-review.ts.
const CREATE_TAIL = new RegExp(
  /^\s*,\s*'--method'\s*,\s*'POST'\s*,\s*/.source +
    /`repos\/\$\{[\w.]+\}\/\$\{[\w.]+\}\/pulls\/\$\{[\w.]+\}\/reviews`/.source +
    /\s*,\s*'--input'\s*,\s*'-'\s*,?\s*\]/.source,
)

interface GhCalls {
  allowed: number
  create: number
  refused: number
}

// The text of a quoted item, or null for an item that is not quoted (a variable, a call).
const literal = (item: string): string | null =>
  /^\s*(['"`])([^'"`]*)\1\s*$/.exec(item)?.[2] ?? null

// True when the list is a gh call. A list that starts with 'api' is always a gh call. For another
// command, the next item must be a subcommand of it, or a flag with a subcommand later in the
// list. So a key list such as ['repo', 'number'] and a git call such as ['status', '--porcelain']
// do not count.
function isGhCall(command: string, rest: string, close: string): boolean {
  if (command === 'api') return true
  const end = rest.indexOf(close)
  const items = (end === -1 ? rest : rest.slice(0, end)).split(',').slice(1).map(literal)
  const subcommands = (GH_COMMANDS[command] ?? '').split(' ').filter(Boolean)
  const isSub = (item: string | null | undefined): boolean =>
    item != null && subcommands.includes(item)
  const [next, ...later] = items
  return isSub(next) || (next?.startsWith('-') === true && later.some(isSub))
}

// The gh calls of src/main today. Each other gh call fails the test.
function ghCalls(code: string, file: string): GhCalls {
  const out: GhCalls = { allowed: 0, create: 0, refused: 0 }
  for (const match of code.matchAll(GH_START)) {
    const rest = code.slice((match.index ?? 0) + match[0].length)
    const command = match[2]
    if (!isGhCall(command, rest, match[0].startsWith('[') ? ']' : ')')) continue
    if (command === 'api' && /^\s*,\s*(['"`])(?:graphql|rate_limit)\1/.test(rest)) out.allowed++
    else if (command === 'pr' && /^\s*,\s*(['"`])view\1/.test(rest)) out.allowed++
    // The Daily update reads the merged PRs of the user. A search only reads.
    else if (command === 'search' && /^\s*,\s*(['"`])prs\1/.test(rest)) out.allowed++
    else if (command === 'api' && file === POSTER && CREATE_TAIL.test(rest)) out.create++
    else out.refused++
  }
  return out
}

// A file that runs gh, or that makes the arguments of gh. Each file in src/main/reviews counts.
const GH_MARK = /['"`]gh['"`]|\bgh\.run\b|\b(?:Gh|createGh|ghFailure)\b/
const runsGh = (code: string, file: string): boolean => {
  if (file.startsWith('reviews/') || GH_MARK.test(code)) return true
  const calls = ghCalls(code, file)
  return calls.allowed + calls.create + calls.refused > 0
}

// The name and the argument of each GraphQL field that has an input argument.
const INPUT_FIELD = /\b(\w+)\s*\(\s*input\s*:/g

const RULE = {
  alias: 'a GraphQL alias in a mutation',
  bracketEvent: 'an event key in brackets',
  dismissals: 'the /dismissals path',
  eventField: 'an event= field',
  eventKey: 'an event: key',
  events: 'the /events path',
  firstField: 'a mutation whose first field is not allowed',
  ghCall: 'a gh call that is not one of the known forms',
  ghText: 'a gh command in a text',
  input:
    '--input outside the create call of pending-review.ts and the commit call of ' +
    'request-writes.ts',
  inputField: 'a mutation field that is not allowed',
  merge: 'the /merge path',
  method: '--method outside pending-review.ts, or with another method than POST',
  mutationWord: 'a GraphQL mutation outside the files of POSTERS',
  prReviewMerge: "an argument list with 'pr' and then 'review' or 'merge'",
  quotedEvent: 'a quoted event key',
  requestInput:
    'a requestReviews field with another input than one pull request, one user and union: true',
  requestUnion: 'a requestReviews field without union: true in its input',
  secondField: 'a mutation with more than one field',
  setEvent: 'a set of an event property',
  shortEvent: 'an event key in the short form',
  x: 'the -X flag',
} as const

interface Rule {
  name: string
  finds(code: string, file: string): boolean
}

// The input of each requestReviews field: the text up to its closing bracket.
const REQUEST_REVIEWS = /\brequestReviews\s*\(([^)]*)/g
// The only input of requestReviews: one pull request, one user and union: true.
const REQUEST_INPUT = new RegExp(
  String.raw`^input\s*:\s*\{\s*pullRequestId\s*:\s*\$\w+\s*,\s*userIds\s*:\s*\[\s*\$\w+\s*\]` +
    String.raw`\s*,\s*union\s*:\s*true\s*\}\s*$`,
)

const RULES: Rule[] = [
  ...FORBIDDEN_NAMES.map(name => ({ finds: (code: string) => code.includes(name), name })),
  ...FORBIDDEN_WORDS.map(name => ({
    finds: (code: string) => new RegExp(`\\b${name}\\b`).test(code),
    name,
  })),
  // A folder such as './events/event-log' is not the REST path.
  { finds: code => /\/events(?![\w/.-])/.test(code), name: RULE.events },
  { finds: code => /\/dismissals/.test(code), name: RULE.dismissals },
  // The merge of a PR (pulls/<n>/merge) and the merge of a branch (repos/<o>/<r>/merges). An
  // import of './merge' and the git ref refs/pull/<n>/merge are not these paths.
  {
    finds: code =>
      /pulls\/[^/'"`\s]+\/merge(?![\w-])|repos\/[^/'"`\s]+\/[^/'"`\s]+\/merges(?![\w-])/.test(code),
    name: RULE.merge,
  },
  { finds: code => /['"`]event['"`]\s*:/.test(code), name: RULE.quotedEvent },
  { finds: code => /\[\s*['"`]event['"`]\s*\]/.test(code), name: RULE.bracketEvent },
  { finds: code => /\.event\s*=(?!=)/.test(code), name: RULE.setEvent },
  { finds: code => /\bevent=/.test(code), name: RULE.eventField },
  {
    // In a file that does not run gh, an event key is also a hook row, a listener or a log type.
    // There, the rule finds an event key with the value of a GitHub review event.
    finds: (code, file) =>
      runsGh(code, file)
        ? /\bevent\s*:/.test(code)
        : new RegExp(`\\bevent\\s*:\\s*['"\`]?(?:${REVIEW_EVENT})\\b`).test(code),
    name: RULE.eventKey,
  },
  {
    // live/live-event.ts, which does not run gh, has { event, type: 'state' }.
    finds: (code, file) => runsGh(code, file) && /[{,]\s*event\s*(?=[,}])/.test(code),
    name: RULE.shortEvent,
  },
  {
    finds: code => /\[[^\]]*?['"`]pr['"`]\s*,[^\]]*?['"`](?:review|merge)['"`]/.test(code),
    name: RULE.prReviewMerge,
  },
  { finds: (code, file) => ghCalls(code, file).refused > 0, name: RULE.ghCall },
  { finds: code => /\bgh\s+(?:pr|api|issue|repo|release)\b/.test(code), name: RULE.ghText },
  {
    finds: (code, file) => {
      const all = count(code, /--method/g)
      if (file !== POSTER) return all > 0
      return all !== count(code, /--method(?:['"`]\s*,\s*['"`]|[= ])POST\b/g)
    },
    name: RULE.method,
  },
  {
    finds: (code, file) => {
      const all = count(code, /--input/g)
      // request-writes.ts has at most one --input: the commit call, in its exact form.
      if (file === REQUEST_WRITES) return all > 1 || all !== count(code, COMMIT_CALL)
      return file === POSTER ? all !== ghCalls(code, file).create : all > 0
    },
    name: RULE.input,
  },
  // -X is the short form of --method, also with the method in the same item (-XPUT).
  { finds: code => /(?:^|['"`\s])-X/m.test(code), name: RULE.x },
  { finds: (code, file) => !isPoster(file) && /\bmutation\b/.test(code), name: RULE.mutationWord },
  {
    finds: (code, file) => {
      if (!isPoster(file)) return false
      const fields = [...code.matchAll(/\bmutation\b[^{]*\{\s*(\w+)/g)].map(m => m[1])
      return fields.some(name => !fieldsOf(file).includes(name))
    },
    name: RULE.firstField,
  },
  {
    finds: (code, file) =>
      isPoster(file) && [...code.matchAll(INPUT_FIELD)].some(m => !fieldsOf(file).includes(m[1])),
    name: RULE.inputField,
  },
  {
    finds: (code, file) => isPoster(file) && /\b\w+\s*:\s*\w+\s*\(\s*input\s*:/.test(code),
    name: RULE.alias,
  },
  {
    // Each mutation has one field. So the count of input fields is the count of mutations.
    finds: (code, file) =>
      isPoster(file) && count(code, INPUT_FIELD) !== count(code, /\bmutation\b/g),
    name: RULE.secondField,
  },
  {
    // union: true keeps the other review requests. Without it, GitHub removes them.
    finds: code =>
      [...code.matchAll(REQUEST_REVIEWS)].some(m => !/\bunion\s*:\s*true\b/.test(m[1] ?? '')),
    name: RULE.requestUnion,
  },
  {
    finds: code => [...code.matchAll(REQUEST_REVIEWS)].some(m => !REQUEST_INPUT.test(m[1] ?? '')),
    name: RULE.requestInput,
  },
]

// A full-line comment is not code, so the rules do not read it.
function codeOf(text: string): string {
  return text
    .split('\n')
    .filter(line => !line.trim().startsWith('//'))
    .join('\n')
}

function ruleNames(text: string, file: string): string[] {
  const code = codeOf(text)
  return RULES.filter(rule => rule.finds(code, file)).map(rule => rule.name)
}

function sourceFiles(): string[] {
  return readdirSync(MAIN, { recursive: true })
    .map(entry => String(entry).split('\\').join('/'))
    .filter(entry => /\.tsx?$/.test(entry))
    .sort()
}

describe('GitHub writes in src/main', () => {
  it('reads the files of src/main, with the files of POSTERS and gh.ts', () => {
    const files = sourceFiles()
    for (const file of Object.keys(POSTERS)) expect(files).toContain(file)
    expect(files).toContain('reviews/gh.ts')
    expect(files).toContain('info/pr-info.ts')
    expect(files.length).toBeGreaterThan(50)
  })

  it('has no call or field that submits, approves, requests changes, dismisses or merges', () => {
    const found = sourceFiles().flatMap(file =>
      ruleNames(readFileSync(join(MAIN, file), 'utf8'), file).map(name => `${file}: ${name}`),
    )
    expect(found).toEqual([])
  })

  it('has each write of a request round one time in request-writes.ts, as GraphQL only', () => {
    const code = codeOf(readFileSync(join(MAIN, REQUEST_WRITES), 'utf8'))
    const fields = [...code.matchAll(INPUT_FIELD)].map(m => m[1])
    expect(fields.sort()).toEqual([...fieldsOf(REQUEST_WRITES)].sort())
    // One call with -f fields for the four writes, and one call with stdin for the commit.
    expect(ghCalls(code, REQUEST_WRITES)).toEqual({ allowed: 2, create: 0, refused: 0 })
    expect(count(code, COMMIT_CALL)).toBe(1)
  })

  it('calls the signed commit write only from request-push.ts', () => {
    const users = sourceFiles().filter(file =>
      /\bcommitOnBranch\b/.test(codeOf(readFileSync(join(MAIN, file), 'utf8'))),
    )
    expect(users).toEqual([SIGNED_PUSHER, REQUEST_WRITES])
    // The pusher sends no GraphQL text of its own.
    const pusher = codeOf(readFileSync(join(MAIN, SIGNED_PUSHER), 'utf8'))
    expect(pusher).not.toMatch(/\bmutation\b|createCommitOnBranch|'graphql'/)
  })

  it('has exactly the five write queries of the plan in request-writes.ts', () => {
    const code = codeOf(readFileSync(join(MAIN, REQUEST_WRITES), 'utf8'))
    const queries = [...code.matchAll(/`(\s*mutation\b[^`]*)`/g)].map(m => flat(m[1] ?? ''))
    expect(queries.sort()).toEqual(WRITE_QUERIES.map(query => flat(query.slice(1, -1))).sort())
    expect(count(code, /\bmutation\b/g)).toBe(WRITE_QUERIES.length)
  })

  it('creates the pending review only with POST and no event', () => {
    const code = codeOf(readFileSync(join(MAIN, POSTER), 'utf8'))
    expect(ghCalls(code, POSTER).create).toBe(1)
    expect(code).not.toMatch(/\bevent\b/i)
  })
})

// A sample text writes % for the $ of a placeholder. So the sample is not a string with a
// placeholder in it, which the linter refuses.
const tpl = (text: string): string => text.replaceAll('%', '$')
const CLOSE = '`mutation C($i: ID!) { closePullRequest(input: { pullRequestId: $i }) { a } }`'
const ALIAS =
  '`mutation A($i: ID!) { addPullRequestReviewThread: ' +
  'closePullRequest(input: { pullRequestId: $i }) { a } }`'
const TWO_FIELDS =
  '`mutation A { addPullRequestReviewThread(input: {}) { thread { id } } ' +
  'updatePullRequestReview(input: {}) { a } }`'
const TWO_WRITES =
  '`mutation A { addPullRequestReviewThread(input: {}) { thread { id } } ' +
  'closePullRequest(input: {}) { a } }`'
const ADD = '`mutation A($i: ID!) { addPullRequestReviewThread(input: {}) { a } }`'
// An approve through stdin, in a file outside src/main/reviews that runs gh.
const APPROVE_STDIN = tpl(
  "gh.run(['api', `repos/%{o}/%{r}/pulls/%{n}/reviews`, '--input', '-'], " +
    '{ input: JSON.stringify({ commit_id, event: verdict }) })',
)
const PUT_MERGE = tpl("gh.run(['api', '-XPUT', `repos/%{o}/%{r}/pulls/%{n}/merge`])")
const REPLY =
  '`mutation ReplyToThread($thread: ID!, $body: String!) {\n' +
  '  addPullRequestReviewThreadReply(input: { pullRequestReviewThreadId: $thread, body: $body })' +
  ' {\n    comment { id createdAt state }\n  }\n}`'
const RESOLVE =
  '`mutation ResolveThread($thread: ID!) {\n' +
  '  resolveReviewThread(input: { threadId: $thread }) { thread { id isResolved } }\n}`'
const COMMENT =
  '`mutation CommentOnPr($subject: ID!, $body: String!) {\n' +
  '  addComment(input: { subjectId: $subject, body: $body }) {\n' +
  '    commentEdge { node { id createdAt } }\n  }\n}`'
const REVIEWS =
  '`mutation RequestReviewer($pr: ID!, $user: ID!) {\n' +
  '  requestReviews(input: { pullRequestId: $pr, userIds: [$user], union: true }) {\n' +
  '    pullRequest { id }\n  }\n}`'
const COMMIT_ON_BRANCH =
  '`mutation CommitOnBranch($input: CreateCommitOnBranchInput!) {\n' +
  '  createCommitOnBranch(input: $input) {\n    commit { oid }\n  }\n}`'
// The five writes of request-writes.ts, as the plan and the signed commits decision give them.
// White space does not count.
const WRITE_QUERIES = [REPLY, RESOLVE, COMMENT, REVIEWS, COMMIT_ON_BRANCH]
const flat = (text: string): string => text.replace(/\s+/g, ' ').trim()
const REVIEWS_TEAMS = REVIEWS.replace('union: true', 'teamIds: [$t], union: true')
const REVIEWS_TWO_USERS = REVIEWS.replace('userIds: [$user]', 'userIds: [$user, $other]')
const REVIEWS_NO_UNION = REVIEWS.replace(', union: true', '')
const REVIEWS_UNION_FALSE = REVIEWS.replace('union: true', 'union: false')
const REVIEWS_BY_VARIABLE =
  '`mutation R($input: RequestReviewsInput!) { requestReviews(input: $input) { a } }`'
const REPLY_ALIAS =
  '`mutation A($t: ID!) { addPullRequestReviewThreadReply: ' +
  'unresolveReviewThread(input: { threadId: $t }) { a } }`'
const REPLY_AND_RESOLVE =
  '`mutation A { addPullRequestReviewThreadReply(input: {}) { a } ' +
  'resolveReviewThread(input: {}) { a } }`'

// Each bad text names the rule that must find it. So one rule cannot hide a broken other rule.
describe('the rules', () => {
  const bad: [string, string, string][] = [
    ...FORBIDDEN_NAMES.map((name): [string, string, string] => [
      name,
      `mutation { ${name}(input: $i) }`,
      POSTER,
    ]),
    ...FORBIDDEN_WORDS.map((name): [string, string, string] => [
      name,
      `mutation { ${name}(input: $i) }`,
      REQUEST_WRITES,
    ]),
    // A name outside a mutation, for example a call through another tool.
    ['closePullRequest', "const op = 'closePullRequest'", 'live/x.ts'],
    ['updatePullRequest', 'run({ field: updatePullRequest })', 'reviews/x.ts'],
    ['createRef', 'createRef(input: { name: $n })', 'info/x.ts'],
    [RULE.requestUnion, REVIEWS_NO_UNION, REQUEST_WRITES],
    [RULE.requestUnion, REVIEWS_UNION_FALSE, REQUEST_WRITES],
    [RULE.requestUnion, REVIEWS_BY_VARIABLE, REQUEST_WRITES],
    [RULE.requestInput, REVIEWS_TEAMS, REQUEST_WRITES],
    [RULE.requestInput, REVIEWS_TWO_USERS, REQUEST_WRITES],
    [RULE.requestInput, REVIEWS_NO_UNION, REQUEST_WRITES],
    [RULE.requestInput, REVIEWS_BY_VARIABLE, 'live/x.ts'],
    [RULE.mutationWord, REPLY, 'reviews/request-posts.ts'],
    [RULE.firstField, ADD, REQUEST_WRITES],
    [RULE.inputField, ADD, REQUEST_WRITES],
    [RULE.firstField, RESOLVE, POSTER],
    [RULE.inputField, RESOLVE, POSTER],
    [RULE.alias, REPLY_ALIAS, REQUEST_WRITES],
    [RULE.secondField, REPLY_AND_RESOLVE, REQUEST_WRITES],
    [RULE.method, "gh.run(['api', '--method', 'POST', path])", REQUEST_WRITES],
    [
      RULE.input,
      "gh.run(['api', 'graphql', '--input', '-'], { input: x })\n" +
        "gh.run(['api', 'graphql', '--input', '-'], { input: y })",
      REQUEST_WRITES,
    ],
    [RULE.input, "gh.run(['api', path, '--input', '-'], { input: x })", REQUEST_WRITES],
    [RULE.input, "gh.run(['api', 'graphql', '--input', file])", REQUEST_WRITES],
    [RULE.ghCall, tpl("gh.run(['api', `repos/%{o}/%{r}/issues/%{n}/comments`])"), REQUEST_WRITES],
    [
      RULE.ghCall,
      tpl(
        "gh.run(['api', '--method', 'POST', `repos/%{owner}/%{repo}/pulls/%{number}/reviews`, " +
          "'--input', '-'])",
      ),
      REQUEST_WRITES,
    ],
    [RULE.events, '`repos/acme/tool/pulls/7/reviews/9/events`', 'reviews/x.ts'],
    [RULE.events, "'repos/o/r/pulls/1/reviews/2/events'", 'live/x.ts'],
    [RULE.dismissals, '`repos/acme/tool/pulls/7/reviews/9/dismissals`', 'reviews/x.ts'],
    [RULE.merge, "const path = 'repos/o/r/pulls/7/merge'", 'live/x.ts'],
    [RULE.merge, "const path = 'repos/o/r/merges'", 'live/x.ts'],
    [RULE.merge, tpl('const path = `repos/%{owner}/%{repo}/pulls/%{number}/merge`'), 'live/x.ts'],
    [RULE.ghCall, "gh.run(['workflow', 'run', 'deploy.yml'])", 'reviews/x.ts'],
    [RULE.ghCall, "gh.run(['label', 'create', 'bug'])", 'reviews/x.ts'],
    [RULE.ghCall, "gh.run(['secret', 'set', 'TOKEN', '--body', t])", 'reviews/x.ts'],
    [RULE.ghCall, "gh.run(['release', 'create', 'v1.0.0'])", 'reviews/x.ts'],
    [RULE.ghCall, "gh.run(['repo', 'delete', name, '--yes'])", 'reviews/x.ts'],
    [RULE.ghCall, "gh.run(['gist', 'create', file])", 'reviews/x.ts'],
    [RULE.ghCall, "gh.run(['run', 'rerun', id])", 'reviews/x.ts'],
    [RULE.ghCall, "gh.run(['variable', 'set', 'NAME'])", 'reviews/x.ts'],
    [RULE.ghCall, "gh.run(['ssh-key', 'add', file])", 'reviews/x.ts'],
    [RULE.ghCall, "gh.run(['auth', 'token'])", 'reviews/x.ts'],
    [RULE.ghCall, "gh.run(['pr', '--repo', name, 'close', '1'])", 'reviews/x.ts'],
    [RULE.quotedEvent, 'const body = { "event": "COMMENT" }', 'live/x.ts'],
    [RULE.bracketEvent, "payload['event'] = 'APPROVE'", 'live/x.ts'],
    [RULE.setEvent, 'payload.event = kind', 'live/x.ts'],
    [RULE.eventField, "gh.run(['api', path, '-f', 'event=APPROVE'])", 'live/x.ts'],
    [RULE.eventKey, 'const payload = { commit_id: sha, event: kind }', 'reviews/x.ts'],
    [RULE.eventKey, "const payload = { event: 'REQUEST_CHANGES' }", 'live/x.ts'],
    [RULE.eventKey, 'addPullRequestReview(input: { event: APPROVE })', 'live/x.ts'],
    [RULE.eventKey, "deps.exec('gh', args, { input: JSON.stringify({ event: v }) })", 'a/x.ts'],
    [RULE.shortEvent, 'const payload = { commit_id, event }', 'reviews/x.ts'],
    [RULE.shortEvent, "const p = { commit_id, event }\nexec('gh', a)", 'info/x.ts'],
    [RULE.prReviewMerge, "gh.run(['pr', 'review', '--approve'])", 'live/x.ts'],
    [RULE.prReviewMerge, "gh.run([\n  'pr',\n  'merge',\n])", 'live/x.ts'],
    [RULE.prReviewMerge, "gh.run(['pr', '-R', repo, 'merge', String(n)])", 'reviews/x.ts'],
    [RULE.ghCall, "gh.run(['pr', '-R', repo, 'merge', String(n)])", 'reviews/x.ts'],
    [RULE.ghCall, "gh.run(['pr', 'comment', String(n), '--body', b])", 'reviews/x.ts'],
    [RULE.ghCall, "gh.run(['pr', 'close', String(n)])", 'reviews/x.ts'],
    [RULE.ghCall, "gh.run(['issue', 'comment', String(n)])", 'reviews/x.ts'],
    [RULE.ghCall, "args.push('api', path)", 'reviews/x.ts'],
    [RULE.ghCall, PUT_MERGE, 'info/x.ts'],
    [
      RULE.ghCall,
      tpl(
        "gh.run(['api', `repos/%{o}/%{r}/pulls/%{n}/comments`, '-f', `body=%{b}`, '-F', 'line=3'])",
      ),
      'reviews/x.ts',
    ],
    [
      RULE.ghCall,
      tpl("gh.run(['api', `repos/%{o}/%{r}/pulls/%{n}/reviews`, '--input', '-'], { input: x })"),
      'info/pr-info.ts',
    ],
    [RULE.ghCall, "gh.run(['api', '--method', 'POST', path, '--input', '-'])", POSTER],
    [RULE.ghText, "execFile('/bin/sh', ['-c', 'gh pr merge 7'])", 'live/x.ts'],
    [RULE.method, "gh.run(['api', '--method', 'POST', path])", 'reviews/x.ts'],
    [RULE.method, "gh.run(['api', '--method', 'DELETE', path])", POSTER],
    [RULE.method, "gh.run(['api', '--method=PUT', path])", POSTER],
    [RULE.input, "gh.run(['api', path, '--input', '-'], { input: x })", 'info/pr-info.ts'],
    [RULE.input, "gh.run(['api', 'graphql', '--input', '-'], { input: x })", POSTER],
    [RULE.x, "gh.run(['api', '-X', 'DELETE', path])", POSTER],
    [RULE.x, "gh.run(['api', '-XDELETE', path])", POSTER],
    [RULE.x, PUT_MERGE, 'info/pr-info.ts'],
    [RULE.mutationWord, ADD, 'reviews/x.ts'],
    [RULE.firstField, CLOSE, POSTER],
    [RULE.inputField, CLOSE, POSTER],
    [RULE.alias, ALIAS, POSTER],
    [RULE.inputField, ALIAS, POSTER],
    [RULE.secondField, TWO_FIELDS, POSTER],
    [RULE.secondField, TWO_WRITES, POSTER],
    [RULE.inputField, TWO_WRITES, POSTER],
    [RULE.eventKey, APPROVE_STDIN, 'info/pr-info.ts'],
    [RULE.input, APPROVE_STDIN, 'info/pr-info.ts'],
    [RULE.ghCall, APPROVE_STDIN, 'info/pr-info.ts'],
  ]
  it.each(bad)('%s finds %j in %s', (rule, text, file) => {
    expect(ruleNames(text, file)).toContain(rule)
  })

  it('has a bad text for each rule', () => {
    const named = new Set(bad.map(([rule]) => rule))
    expect(RULES.map(rule => rule.name).filter(name => !named.has(name))).toEqual([])
  })

  const harmless: [string, string][] = [
    ["import { EventLog } from './events/event-log'", 'ipc.ts'],
    ["on(event: 'closed', listener: () => void): unknown", 'settings/key-recording.ts'],
    ["{ event: 'SessionStart' }", 'integration/settings-plan.ts'],
    ["return { event, type: 'state' }", 'live/live-event.ts'],
    ['// The reviewer of a request or of a request event: a user login.', 'reviews/query.ts'],
    ['timelineItems(last: 10, itemTypes: [REVIEW_REQUESTED_EVENT])', 'reviews/query.ts'],
    ["await mustIn(clone, ['merge-base', head, base])", 'reviews/repo-store.ts'],
    ["const RESULT_KEYS = ['version', 'pr', 'headSha', 'why']", 'reviews/result-file.ts'],
    [
      tpl(
        "gh.run(['api', '--method', 'POST', `repos/%{owner}/%{repo}/pulls/%{number}/reviews`, " +
          "'--input', '-'])",
      ),
      POSTER,
    ],
    [tpl("gh.run(['api', 'graphql', '-f', `query=%{query}`, ...fields])"), POSTER],
    [tpl("gh.run(['api', 'graphql', '-f', `query=%{query}`, ...fields])"), REQUEST_WRITES],
    [REPLY, REQUEST_WRITES],
    [RESOLVE, REQUEST_WRITES],
    [COMMENT, REQUEST_WRITES],
    [REVIEWS, REQUEST_WRITES],
    [COMMIT_ON_BRANCH, REQUEST_WRITES],
    // The commit call sends its body on stdin.
    ["gh.run(['api', 'graphql', '--input', '-'], { input: body })", REQUEST_WRITES],
    // The R2 field and the R3 field start with a forbidden name, but are other words.
    ['`mutation A { addPullRequestReviewThread(input: {}) { a } }`', POSTER],
    ["const KIND = 'resolveReviewThread'", 'reviews/request-posts.ts'],
    ['`mutation Add($id: ID!) {\n  addPullRequestReviewThread(input: {}) { a }\n}`', POSTER],
    ['`mutation Set($id: ID!) { updatePullRequestReview(input: {}) { a } }`', POSTER],
    ["const GH_ARGS = ['pr', 'view', '--json', 'number']", 'info/pr-info.ts'],
    ["export const RATE_LIMIT_ARGS = ['api', 'rate_limit']", 'performance/bindings.ts'],
    ["import { merge } from './merge'", 'live/x.ts'],
    [tpl('const ref = `refs/pull/%{number}/merge`'), 'reviews/repo-store.ts'],
    // Key lists and git calls that start with the name of a gh command.
    ["const KEYS = ['repo', 'number']", 'reviews/x.ts'],
    ["const FIELDS = ['search', 'label', 'status']", 'reviews/x.ts'],
    ["onWorktree(['status', '--porcelain', '--untracked-files=all', '--ignored'])", 'reviews/x.ts'],
    ["git.run(['config', '--get', 'remote.origin.url'])", 'reviews/x.ts'],
    ["const STATES = ['run', 'stop']", 'live/x.ts'],
  ]
  it.each(harmless)('ignores %j in %s', (text, file) => {
    expect(ruleNames(text, file)).toEqual([])
  })
})
