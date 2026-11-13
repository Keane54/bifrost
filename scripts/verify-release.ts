// This script checks the signed app of a release build (RELEASING.md).
// The Release workflow runs it after "pnpm dist:release" and before it publishes anything.
// A failed check stops the release. The script needs macOS.
import { spawnSync } from 'node:child_process'
import { createHash } from 'node:crypto'
import { existsSync, readFileSync } from 'node:fs'
import { feedSha512, namesRepo } from './release/feed.ts'

const APP = 'dist/mac-arm64/Bifrost.app'
// The team ID of the signing certificate. The Release workflow reads it from the certificate
// in CSC_LINK (scripts/release/signing-identity.ts).
const TEAM_ID = (process.env.APPLE_TEAM_ID ?? '').trim()
// The repo of the releases. UPDATE_OWNER and UPDATE_REPO in src/main/updates/updater.ts have the
// same values. A unit test compares them.
const OWNER = 'Keane54'
const REPO = 'bifrost'
const DIST = 'dist'

// Run a command and return its result. codesign and spctl write their result to stderr, so the
// text holds stdout and stderr.
function run(command: string, args: string[]): { ok: boolean; text: string } {
  const result = spawnSync(command, args, { encoding: 'utf8' })
  return { ok: result.status === 0, text: `${result.stdout ?? ''}${result.stderr ?? ''}` }
}

const failures: string[] = []

function check(name: string, ok: boolean, text: string): void {
  console.log(`${ok ? 'PASS' : 'FAIL'}: ${name}`)
  if (!ok) {
    console.log(text.trim())
    failures.push(name)
  }
}

if (TEAM_ID === '') {
  console.error(
    'FAIL: APPLE_TEAM_ID is not set. Set it to the team ID of the signing certificate ' +
      '(RELEASING.md).',
  )
  process.exit(1)
}
if (!/^[A-Z0-9]{10}$/.test(TEAM_ID)) {
  console.error('FAIL: APPLE_TEAM_ID must be the 10 letters and digits of the team ID.')
  process.exit(1)
}

if (!existsSync(APP)) {
  console.error(`FAIL: ${APP} does not exist. Run "pnpm dist:release" first.`)
  process.exit(1)
}

// Step 1: the signature of the app and of all code in it is correct.
const verify = run('codesign', ['--verify', '--deep', '--strict', '--verbose=2', APP])
check('the signature is correct', verify.ok, verify.text)

// Step 2: the signature is the Developer ID of the team, with the hardened runtime.
const details = run('codesign', ['--display', '--verbose=4', APP])
check(
  'the signature is the Developer ID of the team',
  details.ok &&
    details.text.includes(`TeamIdentifier=${TEAM_ID}`) &&
    details.text.includes('Authority=Developer ID Application'),
  details.text,
)
check(
  'the app has the hardened runtime',
  details.ok && /flags=0x[0-9a-f]*\(.*runtime.*\)/.test(details.text),
  details.text,
)

// Step 3: the notarisation ticket is stapled to the app, so macOS can check it with no network.
const stapler = run('xcrun', ['stapler', 'validate', APP])
check('the notarisation ticket is stapled', stapler.ok, stapler.text)

// Step 4: Gatekeeper accepts the app as notarised. When Gatekeeper is off on the Mac, spctl
// accepts every app, so its answer has no value. Step 3 then covers the notarisation.
const gatekeeper = run('spctl', ['--assess', '--type', 'execute', '--verbose=4', APP])
if (gatekeeper.text.includes('override=security disabled')) {
  console.log('SKIP: Gatekeeper is off on this Mac, so spctl cannot check the app.')
} else {
  check(
    'Gatekeeper accepts the app as notarised',
    gatekeeper.ok && gatekeeper.text.includes('Notarized Developer ID'),
    gatekeeper.text,
  )
}

// Step 5: the update files exist and agree. The updater reads app-update.yml in the app and
// latest-mac.yml in the release.
const version = JSON.parse(readFileSync('package.json', 'utf8')).version as string
const zipName = `Bifrost-${version}-arm64-mac.zip`
const zipPath = `${DIST}/${zipName}`
const zipExists = existsSync(zipPath)
check('the update ZIP exists', zipExists, `${zipPath} does not exist.`)

const appUpdatePath = `${APP}/Contents/Resources/app-update.yml`
const appUpdate = existsSync(appUpdatePath) ? readFileSync(appUpdatePath, 'utf8') : ''
check(
  'app-update.yml names the repository',
  namesRepo(appUpdate, OWNER, REPO),
  appUpdate || `${appUpdatePath} does not exist.`,
)

const feedPath = `${DIST}/latest-mac.yml`
const feed = existsSync(feedPath) ? readFileSync(feedPath, 'utf8') : ''
check(
  'latest-mac.yml has the version',
  new RegExp(`^version: ${version.replace(/\./g, '\\.')}$`, 'm').test(feed),
  feed || `${feedPath} does not exist.`,
)

// The feed lists each file with its url and its sha512 as base64. The sha512 must match the ZIP.
const sha512 = zipExists ? createHash('sha512').update(readFileSync(zipPath)).digest('base64') : ''
const feedSha = feedSha512(feed, zipName)
const shaDetail = [
  `Expected sha512: ${sha512 || '(no ZIP)'}`,
  `Found sha512: ${feedSha ?? `(no files entry of ${zipName} with a sha512)`}`,
].join('\n')
check(
  'latest-mac.yml has the SHA-512 of the update ZIP',
  zipExists && feedSha === sha512,
  shaDetail,
)

if (failures.length > 0) {
  console.error(`${failures.length} check(s) failed. The release stops.`)
  process.exit(1)
}
console.log('All checks passed.')
