// The only GitHub write of R2 is a pending review: create one with POST
// repos/<owner>/<repo>/pulls/<n>/reviews and no event field, or add threads to the pending review
// of the user and set its body. Bifrost never submits, approves, requests changes, dismisses,
// deletes or merges. This test reads each .ts file of src/main and fails when a call or a field
// for one of these shows up.
// If a pattern finds a harmless text in a file, make the pattern more exact. Never remove a
// pattern.

import { readdirSync, readFileSync } from 'node:fs'
import { join } from 'node:path'
import { fileURLToPath } from 'node:url'
import { describe, expect, it } from 'vitest'

const MAIN = fileURLToPath(new URL('../../../src/main/', import.meta.url))
// The path of each file is relative to src/main, with forward slashes.
const POSTER = 'reviews/pending-review.ts'
const MUTATIONS = ['addPullRequestReviewThread', 'updatePullRequestReview']
const FORBIDDEN_NAMES = [
  'submitPullRequestReview',
  'dismissPullRequestReview',
  'deletePullRequestReview',
  'mergePullRequest',
  'enablePullRequestAutoMerge',
]
// The event values of a GitHub review (REST and GraphQL).
const REVIEW_EVENT = 'APPROVE|REQUEST_CHANGES|COMMENT|DISMISS'

const inReviews = (file: string): boolean => file.startsWith('reviews/')
const count = (text: string, pattern: RegExp): number => text.match(pattern)?.length ?? 0

interface Rule {
  name: string
  finds(code: string, file: string): boolean
}

const RULES: Rule[] = [
  ...FORBIDDEN_NAMES.map(name => ({ finds: (code: string) => code.includes(name), name })),
  // A folder such as './events/event-log' is not the REST path.
  { finds: code => /\/events(?![\w/.-])/.test(code), name: 'the /events path' },
  { finds: code => /\/dismissals/.test(code), name: 'the /dismissals path' },
  { finds: code => /['"`]event['"`]\s*:/.test(code), name: 'a quoted event key' },
  { finds: code => /\[\s*['"`]event['"`]\s*\]/.test(code), name: 'an event key in brackets' },
  { finds: code => /\.event\s*=(?!=)/.test(code), name: 'a set of an event property' },
  { finds: code => /\bevent=/.test(code), name: 'an event= field' },
  {
    // Outside src/main/reviews, an event key is also a hook row, a listener or a log type. There,
    // the rule finds an event key with the value of a GitHub review event.
    finds: (code, file) =>
      inReviews(file)
        ? /\bevent\s*:/.test(code)
        : new RegExp(`\\bevent\\s*:\\s*['"\`]?(?:${REVIEW_EVENT})\\b`).test(code),
    name: 'an event: key',
  },
  {
    // Outside src/main/reviews, a live event uses the short form { event, type }.
    finds: (code, file) => inReviews(file) && /[{,]\s*event\s*(?=[,}])/.test(code),
    name: 'an event key in the short form',
  },
  {
    finds: code => /['"`]pr['"`]\s*,\s*['"`](?:review|merge)['"`]/.test(code),
    name: "an argument list that starts 'pr', 'review' or 'pr', 'merge'",
  },
  {
    finds: (code, file) => {
      const all = count(code, /--method/g)
      if (file !== POSTER) return all > 0
      return all !== count(code, /--method(?:['"`]\s*,\s*['"`]|[= ])POST\b/g)
    },
    name: '--method outside pending-review.ts, or with another method than POST',
  },
  // -X is the short form of --method. Bifrost uses only --method.
  { finds: code => /(?:^|['"`\s])-X(?:$|['"`\s=])/m.test(code), name: 'the -X flag' },
  {
    finds: (code, file) => {
      if (file !== POSTER) return /\bmutation\b/.test(code)
      const fields = [...code.matchAll(/\bmutation\b[^{]*\{\s*(\w+)/g)].map(m => m[1])
      return fields.some(name => !MUTATIONS.includes(name))
    },
    name: 'a GraphQL mutation that is not one of the two of pending-review.ts',
  },
]

// A full-line comment is not code, so the rules do not read it.
function codeOf(text: string): string {
  return text
    .split('\n')
    .filter(line => !line.trim().startsWith('//'))
    .join('\n')
}

function problems(text: string, file: string): string[] {
  const code = codeOf(text)
  return RULES.filter(rule => rule.finds(code, file)).map(rule => `${file}: ${rule.name}`)
}

function sourceFiles(): string[] {
  return readdirSync(MAIN, { recursive: true })
    .map(entry => String(entry).split('\\').join('/'))
    .filter(entry => /\.tsx?$/.test(entry))
    .sort()
}

describe('GitHub writes in src/main', () => {
  it('reads the files of src/main, with pending-review.ts and gh.ts', () => {
    const files = sourceFiles()
    expect(files).toContain(POSTER)
    expect(files).toContain('reviews/gh.ts')
    expect(files).toContain('info/pr-info.ts')
    expect(files.length).toBeGreaterThan(50)
  })

  it('has no call or field that submits, approves, requests changes, dismisses or merges', () => {
    const found = sourceFiles().flatMap(file =>
      problems(readFileSync(join(MAIN, file), 'utf8'), file),
    )
    expect(found).toEqual([])
  })

  it('creates the pending review only with POST and no event', () => {
    const code = codeOf(readFileSync(join(MAIN, POSTER), 'utf8'))
    expect(code).toMatch(/['"`]--method['"`]\s*,\s*['"`]POST['"`]/)
    expect(code).toContain('/reviews`')
    expect(code).not.toMatch(/\bevent\b/i)
  })
})

// Each rule must find its bad text, so that a broken pattern cannot pass in silence.
describe('the rules', () => {
  const bad: [string, string][] = [
    ...FORBIDDEN_NAMES.map((name): [string, string] => [`mutation { ${name}(input: $i) }`, POSTER]),
    ['`repos/acme/tool/pulls/7/reviews/9/events`', 'reviews/x.ts'],
    ["'repos/o/r/pulls/1/reviews/2/events'", 'live/x.ts'],
    ['`repos/acme/tool/pulls/7/reviews/9/dismissals`', 'reviews/x.ts'],
    ['const body = { "event": "COMMENT" }', 'live/x.ts'],
    ["payload['event'] = 'APPROVE'", 'live/x.ts'],
    ['payload.event = kind', 'live/x.ts'],
    ["gh.run(['api', path, '-f', 'event=APPROVE'])", 'live/x.ts'],
    ['const payload = { commit_id: sha, event: kind }', 'reviews/x.ts'],
    ["const payload = { event: 'REQUEST_CHANGES' }", 'live/x.ts'],
    ['addPullRequestReview(input: { event: APPROVE })', 'live/x.ts'],
    ['const payload = { commit_id, event }', 'reviews/x.ts'],
    ["gh.run(['pr', 'review', '--approve'])", 'live/x.ts'],
    ["gh.run([\n  'pr',\n  'merge',\n])", 'live/x.ts'],
    ["gh.run(['api', '--method', 'POST', path])", 'reviews/x.ts'],
    ["gh.run(['api', '--method', 'DELETE', path])", POSTER],
    ["gh.run(['api', '--method=PUT', path])", POSTER],
    ["gh.run(['api', '-X', 'DELETE', path])", POSTER],
    [
      '`mutation Close($id: ID!) { closePullRequest(input: { pullRequestId: $id }) { a } }`',
      POSTER,
    ],
    ['`mutation Add($id: ID!) { addPullRequestReviewThread(input: {}) { a } }`', 'reviews/x.ts'],
  ]
  it.each(bad)('finds %j in %s', (text, file) => {
    expect(problems(text, file)).not.toEqual([])
  })

  const harmless: [string, string][] = [
    ["import { EventLog } from './events/event-log'", 'ipc.ts'],
    ["on(event: 'closed', listener: () => void): unknown", 'settings/key-recording.ts'],
    ["{ event: 'SessionStart' }", 'integration/settings-plan.ts'],
    ["return { event, type: 'state' }", 'live/live-event.ts'],
    ['// The reviewer of a request or of a request event: a user login.', 'reviews/query.ts'],
    ['timelineItems(last: 10, itemTypes: [REVIEW_REQUESTED_EVENT])', 'reviews/query.ts'],
    ["gh.run(['api', '--method', 'POST', path, '--input', '-'])", POSTER],
    ['`mutation Add($id: ID!) {\n  addPullRequestReviewThread(input: {}) { a }\n}`', POSTER],
    ['`mutation Set($id: ID!) { updatePullRequestReview(input: {}) { a } }`', POSTER],
    ["const GH_ARGS = ['pr', 'view', '--json', 'number']", 'info/pr-info.ts'],
  ]
  it.each(harmless)('ignores %j in %s', (text, file) => {
    expect(problems(text, file)).toEqual([])
  })
})
