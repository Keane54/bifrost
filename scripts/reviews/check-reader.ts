// A read-only check of the GitHub reader against the real GitHub. It runs the one query of the
// Reviews panel with the real gh, and it prints only counts. It prints no title, no body and no
// token.
//
// Run it from the root of the repository: node scripts/reviews/check-reader.ts
//
// The modules of src/main import each other with no file extension. Plain node cannot load them.
// So the script first adds a resolve hook that tries a .ts file when a path fails.

import { registerHooks } from 'node:module'

registerHooks({
  resolve(specifier, context, nextResolve) {
    try {
      return nextResolve(specifier, context)
    } catch (err) {
      const relative = specifier.startsWith('.') || specifier.startsWith('/')
      if (!relative) throw err
      for (const suffix of ['.ts', '/index.ts']) {
        try {
          return nextResolve(specifier + suffix, context)
        } catch {
          // Try the next suffix.
        }
      }
      throw err
    }
  },
})

const { execFile } = await import('../../src/main/claude/cli.ts')
const { createGh, ghFailure } = await import('../../src/main/reviews/gh.ts')
const { parsePoll, pollArgs } = await import('../../src/main/reviews/query.ts')

function fail(message: string): never {
  console.error(`check-reader failed: ${message}`)
  process.exit(1)
}

const env: Record<string, string> = {}
for (const [key, value] of Object.entries(process.env)) {
  if (value !== undefined) env[key] = value
}

const gh = createGh({ env: async () => env, exec: execFile })
const result = await gh.run(pollArgs())
const failure = ghFailure(result)
if (failure !== null) fail(`${failure.availability}: ${failure.message}`)

const parsed = parsePoll(result.stdout)
if (!parsed.ok) fail(parsed.message)
const { mine, toReview, viewer } = parsed.data

// The cost of the query is in the raw answer. It is a number only.
let cost: unknown = null
try {
  cost = JSON.parse(result.stdout)?.data?.rateLimit?.cost
} catch {
  // The parse worked above, so this does not happen.
}

const direct = toReview.filter(pr => pr.requestedUsers.includes(viewer))
const team = toReview.length - direct.length
const approved = direct.filter(pr => pr.reviewDecision === 'APPROVED')
const failed = mine.filter(pr => pr.failedChecks > 0)

console.log(`viewer login: ${viewer}`)
console.log(
  `To review: ${toReview.length} (direct ${direct.length}, team ${team}, ` +
    `direct and approved by others ${approved.length})`,
)
console.log(`My PRs: ${mine.length}`)
console.log(`My PRs with failed checks: ${failed.length}`)
console.log(`GraphQL cost: ${typeof cost === 'number' ? cost : 'unknown'}`)
