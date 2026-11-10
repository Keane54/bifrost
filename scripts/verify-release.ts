// This script checks the signed app of a release build (README, Release flow).
// The Release workflow runs it after "pnpm dist:release" and before it publishes anything.
// A failed check stops the release. The script needs macOS.
import { spawnSync } from 'node:child_process'
import { createHash } from 'node:crypto'
import { existsSync, readFileSync } from 'node:fs'

const APP = 'dist/mac-arm64/Bifrost.app'
const TEAM_ID = '2GUX23RPKA'
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
  /^owner: TheKeyholdingCompany$/m.test(appUpdate) && /^repo: bifrost$/m.test(appUpdate),
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
const feedLines = feed.split('\n').map(line => line.trim())
const urlIndex = feedLines.findIndex(
  line => line === `- url: ${zipName}` || line === `url: ${zipName}`,
)
const feedSha = urlIndex >= 0 ? feedLines[urlIndex + 1] : ''
check(
  'latest-mac.yml has the SHA-512 of the update ZIP',
  zipExists && feedSha === `sha512: ${sha512}`,
  `The files entry of ${zipName} is missing or has a different sha512.`,
)

if (failures.length > 0) {
  console.error(`${failures.length} check(s) failed. The release stops.`)
  process.exit(1)
}
console.log('All checks passed.')
