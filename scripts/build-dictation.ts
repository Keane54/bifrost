// This script builds the speech helper (native/dictation) for Apple silicon. It copies the helper
// to resources/bin/bifrost-dictation. electron-builder puts it in Contents/MacOS of the app
// (electron-builder.yml). A dev run of Bifrost starts it from resources/bin.
// The script needs macOS and Xcode 26 or later, because the helper uses the speech API of macOS 26.
import { execFileSync } from 'node:child_process'
import { chmodSync, copyFileSync, mkdirSync, readFileSync } from 'node:fs'
import { dirname, join } from 'node:path'

export const PACKAGE_DIR = 'native/dictation'
export const HELPER_NAME = 'bifrost-dictation'
export const HELPER_OUT = `resources/bin/${HELPER_NAME}`
const MIN_SDK = 26
const ROOT = join(import.meta.dirname, '..')
export const SWIFT_BUILD = [
  'build',
  '-c',
  'release',
  '--arch',
  'arm64',
  '--package-path',
  PACKAGE_DIR,
  '--product',
  HELPER_NAME,
]

// The text of "xcrun --show-sdk-version" gives the version of the macOS SDK. Return an error
// message when the SDK is older than macOS 26, or null when the SDK is correct.
export function checkSdk(text: string): string | null {
  const major = Number(/^(\d+)\./.exec(text.trim())?.[1])
  if (Number.isInteger(major) && major >= MIN_SDK) return null
  const found = text.trim() === '' ? 'no SDK' : `SDK ${text.trim()}`
  return (
    `The speech helper needs the macOS ${MIN_SDK} SDK, but xcrun found ${found}. ` +
    `Install Xcode ${MIN_SDK} or later, and select it with xcode-select.`
  )
}

// The linker puts Info.plist into the __TEXT,__info_plist section of the helper (Package.swift).
// Speech Recognition reads its usage text from there, because the helper has no bundle.
export function hasLinkedPlist(binary: Buffer): boolean {
  return (
    binary.includes('<string>com.keyholding.bifrost.dictation</string>') &&
    binary.includes('<key>NSSpeechRecognitionUsageDescription</key>')
  )
}

type Exec = (command: string, args: string[]) => string

function run(command: string, args: string[]): string {
  return execFileSync(command, args, { cwd: ROOT, encoding: 'utf8', stdio: 'pipe' })
}

// The version of the macOS SDK from xcrun, or a clear message when xcrun does not run.
export function sdkVersion(
  exec: Exec,
): { ok: true; version: string } | { ok: false; message: string } {
  try {
    return { ok: true, version: exec('xcrun', ['--sdk', 'macosx', '--show-sdk-version']).trim() }
  } catch {
    return {
      message:
        'xcrun did not run, so the speech helper cannot build. ' +
        `Install Xcode ${MIN_SDK} or later, and select it with xcode-select.`,
      ok: false,
    }
  }
}

// The folder of the built helper, from swift. When swift fails, the message has the stderr of
// swift, because the pipe keeps it and the terminal does not show it.
export function binPath(exec: Exec): { ok: true; path: string } | { ok: false; message: string } {
  try {
    return { ok: true, path: exec('swift', [...SWIFT_BUILD, '--show-bin-path']).trim() }
  } catch (err) {
    const stderr = String((err as { stderr?: unknown }).stderr ?? '').trim()
    const detail = stderr === '' && err instanceof Error ? err.message : stderr
    const message = 'swift build --show-bin-path failed, so the script cannot find the helper.'
    return { message: detail === '' ? message : `${message}\n${detail}`, ok: false }
  }
}

// Write the message to stderr and stop. A failure of a tool gives no stack trace.
function fail(message: string): never {
  console.error(message)
  process.exit(1)
}

if (import.meta.main) {
  if (process.platform !== 'darwin') fail('The speech helper builds only on macOS.')
  const sdk = sdkVersion(run)
  if (!sdk.ok) fail(sdk.message)
  const sdkError = checkSdk(sdk.version)
  if (sdkError !== null) fail(sdkError)
  try {
    execFileSync('swift', SWIFT_BUILD, { cwd: ROOT, stdio: 'inherit' })
  } catch {
    fail('The Swift build of the speech helper failed. The output of swift is above.')
  }
  const bin = binPath(run)
  if (!bin.ok) fail(bin.message)
  const built = join(bin.path, HELPER_NAME)
  if (!hasLinkedPlist(readFileSync(built))) {
    fail(`${built} has no linked Info.plist. Check the linker flags in Package.swift.`)
  }
  const out = join(ROOT, HELPER_OUT)
  mkdirSync(dirname(out), { recursive: true })
  copyFileSync(built, out)
  chmodSync(out, 0o755)
  console.log(`The speech helper is at ${HELPER_OUT}.`)
}
