// The build of the speech helper (native/dictation), and how the app build and the release check
// include it. Most checks read the source files, as the other build config tests do. No test runs
// Swift, codesign or electron-builder.
import { spawnSync } from 'node:child_process'
import { readFileSync } from 'node:fs'
import { join } from 'node:path'
import { describe, expect, it } from 'vitest'
import { releaseConfig } from '../../electron-builder.release.ts'
import {
  binPath,
  checkSdk,
  HELPER_NAME,
  HELPER_OUT,
  hasLinkedPlist,
  PACKAGE_DIR,
  SWIFT_BUILD,
  sdkVersion,
} from '../../scripts/build-dictation.ts'

const ROOT = join(import.meta.dirname, '..', '..')
const read = (file: string): string => readFileSync(join(ROOT, file), 'utf8')

// The text of the workflow step with the name, up to the next step.
function stepOf(workflow: string, name: string): string {
  return workflow.split(`- name: ${name}\n`)[1]?.split('- name:')[0] ?? ''
}

// The lines of a top-level key of electron-builder.yml, up to the next top-level key.
function blockOf(yaml: string, key: string): string {
  return yaml.split(new RegExp(`^${key}:\\n`, 'm'))[1]?.split(/^\S/m)[0] ?? ''
}

const SPEECH_USAGE =
  'NSSpeechRecognitionUsageDescription: Bifrost turns your speech into text on this Mac.'

describe('the build script of the speech helper', () => {
  it('builds native/dictation and writes resources/bin/bifrost-dictation', () => {
    expect(PACKAGE_DIR).toBe('native/dictation')
    expect(HELPER_NAME).toBe('bifrost-dictation')
    expect(HELPER_OUT).toBe('resources/bin/bifrost-dictation')
    expect(read(`${PACKAGE_DIR}/Package.swift`)).toContain('name: "bifrost-dictation"')
  })

  it('builds a release of the helper product for arm64', () => {
    expect(SWIFT_BUILD).toEqual([
      'build',
      '-c',
      'release',
      '--arch',
      'arm64',
      '--package-path',
      'native/dictation',
      '--product',
      'bifrost-dictation',
    ])
  })

  it('is the build:dictation script, and pnpm dist and build:unpack run it first', () => {
    const scripts = JSON.parse(read('package.json')).scripts
    expect(scripts['build:dictation']).toBe('node scripts/build-dictation.ts')
    expect(scripts.dist).toMatch(/^pnpm run build:dictation && /)
    expect(scripts['build:unpack']).toMatch(/^pnpm run build:dictation && /)
  })

  it('reads the SDK version with xcrun, and gives a clear message when xcrun does not run', () => {
    const calls: string[][] = []
    const found = sdkVersion((command, args) => {
      calls.push([command, ...args])
      return '26.5\n'
    })
    expect(found).toEqual({ ok: true, version: '26.5' })
    expect(calls).toEqual([['xcrun', '--sdk', 'macosx', '--show-sdk-version']])
    const missing = sdkVersion(() => {
      throw Object.assign(new Error('spawnSync xcrun ENOENT'), { code: 'ENOENT' })
    })
    expect(missing.ok).toBe(false)
    if (!missing.ok) {
      expect(missing.message).toContain('xcrun')
      expect(missing.message).toContain('Xcode 26 or later')
      expect(missing.message).not.toContain('ENOENT')
    }
  })

  it('reads the folder of the built helper, and gives the stderr of swift when it fails', () => {
    const calls: string[][] = []
    const found = binPath((command, args) => {
      calls.push([command, ...args])
      return '/repo/native/dictation/.build/arm64-apple-macosx/release\n'
    })
    expect(found).toEqual({
      ok: true,
      path: '/repo/native/dictation/.build/arm64-apple-macosx/release',
    })
    expect(calls).toEqual([['swift', ...SWIFT_BUILD, '--show-bin-path']])
    const failed = binPath(() => {
      throw Object.assign(new Error('Command failed: swift build'), {
        status: 1,
        stderr: 'error: unknown option --show-bin-path\n',
      })
    })
    expect(failed.ok).toBe(false)
    if (!failed.ok) {
      expect(failed.message).toContain('--show-bin-path')
      expect(failed.message).toContain('error: unknown option --show-bin-path')
      // The pipe keeps the output of this call, so it is not above.
      expect(failed.message).not.toContain('above')
    }
  })

  it('uses a separate check for the build and for the folder of the helper', () => {
    const script = read('scripts/build-dictation.ts')
    expect(script.match(/The output of swift is above/g)).toHaveLength(1)
    expect(script).toContain('binPath(run)')
  })

  it('stops with one clear line and no stack trace when the tools are missing', () => {
    // No PATH, so the script finds no xcrun and no swift. It never starts a build.
    const result = spawnSync(process.execPath, ['scripts/build-dictation.ts'], {
      cwd: ROOT,
      encoding: 'utf8',
      env: { PATH: '' },
    })
    expect(result.status).toBe(1)
    expect(result.stdout).toBe('')
    expect(result.stderr).not.toMatch(/^\s+at /m)
    expect(result.stderr.trim().split('\n')).toHaveLength(1)
    const expected =
      process.platform === 'darwin'
        ? 'xcrun did not run'
        : 'The speech helper builds only on macOS.'
    expect(result.stderr).toContain(expected)
  })

  it('accepts the macOS SDK 26 or later, and refuses an older SDK', () => {
    expect(checkSdk('26.5\n')).toBeNull()
    expect(checkSdk('26.0')).toBeNull()
    expect(checkSdk('27.1')).toBeNull()
    for (const old of ['15.5', '14.0\n', '9.9']) {
      expect(checkSdk(old), old).toContain('Xcode 26 or later')
    }
    for (const bad of ['', 'abc', '\n']) expect(checkSdk(bad), bad).toContain('Xcode 26 or later')
  })

  it('finds the Info.plist that the linker puts into the helper', () => {
    const plist = Buffer.from(
      '<key>CFBundleIdentifier</key><string>com.keyholding.bifrost.dictation</string>' +
        '<key>NSSpeechRecognitionUsageDescription</key><string>x</string>',
    )
    const binary = Buffer.concat([Buffer.alloc(64, 0xcf), plist, Buffer.alloc(64)])
    expect(hasLinkedPlist(binary)).toBe(true)
    expect(hasLinkedPlist(Buffer.alloc(256))).toBe(false)
    expect(hasLinkedPlist(Buffer.from('NSSpeechRecognitionUsageDescription'))).toBe(false)
  })

  it('links the Info.plist with the usage texts into the helper', () => {
    const manifest = read(`${PACKAGE_DIR}/Package.swift`)
    expect(manifest).toContain('"-sectcreate"')
    expect(manifest).toContain('"__info_plist"')
    const plist = read(`${PACKAGE_DIR}/Sources/bifrost-dictation/Info.plist`)
    const value = (key: string): string | undefined =>
      new RegExp(`<key>${key}</key>\\s*<string>([^<]*)</string>`).exec(plist)?.[1]
    expect(value('CFBundleIdentifier')).toBe('com.keyholding.bifrost.dictation')
    expect(value('NSMicrophoneUsageDescription')).toBe(
      'Bifrost uses the microphone when you talk to Claude.',
    )
    expect(value('NSSpeechRecognitionUsageDescription')).toBe(
      'Bifrost turns your speech into text on this Mac.',
    )
    for (const row of plist.split('\n')) expect(row.length, row).toBeLessThanOrEqual(100)
  })

  it('closes the microphone of a session that failed during begin', () => {
    // A failure during begin runs sessionFailed while current is nil. So the start checks the
    // events after it sets current, and calls sessionFailed itself.
    const helper = read(`${PACKAGE_DIR}/Sources/bifrost-dictation/Helper.swift`)
    const start = helper.split('private func start() async {')[1]?.split('\n  }\n')[0] ?? ''
    const set = start.indexOf('current = Running(session: session, events: events)')
    const check = start.indexOf('if !events.isOpen { sessionFailed(id) }')
    expect(set).toBeGreaterThan(0)
    expect(check).toBeGreaterThan(set)
    const events = read(`${PACKAGE_DIR}/Sources/bifrost-dictation/Session.swift`)
    expect(events).toMatch(/var isOpen: Bool \{\s+lock\.guarded \{ open \}\s+\}/)
  })

  it('keeps the Swift build and the helper binary out of git', () => {
    expect(read('.gitignore')).toMatch(/^resources\/bin\/$/m)
    expect(read(`${PACKAGE_DIR}/.gitignore`)).toMatch(/^\.build\/$/m)
  })
})

describe('the app build config of the speech helper', () => {
  const yaml = read('electron-builder.yml')

  it('puts the helper in Contents/MacOS with extraFiles', () => {
    expect(blockOf(yaml, 'extraFiles')).toMatch(
      new RegExp(`- from: ${HELPER_OUT}\\n\\s+to: MacOS/${HELPER_NAME}\\n`),
    )
  })

  it('keeps the helper out of app.asar and app.asar.unpacked', () => {
    expect(blockOf(yaml, 'files')).toContain("- '!resources/bin/**'")
  })

  it('signs the helper as an extra binary of the app', () => {
    const mac = blockOf(yaml, 'mac')
    expect(mac).toMatch(/\n {2}binaries:\n {4}- Contents\/MacOS\/bifrost-dictation\n/)
  })

  it('has the Speech Recognition usage text next to the microphone text', () => {
    const extendInfo = blockOf(yaml, 'mac').split(/\n {2}extendInfo:\n/)[1] ?? ''
    expect(extendInfo).toContain(
      'NSMicrophoneUsageDescription: Bifrost uses the microphone when you talk to Claude.',
    )
    expect(extendInfo).toContain(SPEECH_USAGE)
  })

  it('signs the helper with the inherit file, which has the microphone entitlement', () => {
    const mac = releaseConfig({ APPLE_SIGNING_IDENTITY: 'Jane Doe (ABCDE12345)' }).mac
    expect(mac?.entitlements).toBe('build/entitlements.mac.plist')
    expect(mac?.entitlementsInherit).toBe('build/entitlements.mac.inherit.plist')
    // The release config keeps the helper list of the base config (mac.binaries).
    expect(mac?.binaries).toBeUndefined()
  })
})

describe('the release of the speech helper', () => {
  it('builds the helper on a macOS 26 runner and prints the Xcode and SDK versions', () => {
    const build = read('.github/workflows/release.yml').split(/^ {2}build:$/m)[1] ?? ''
    expect(build).toMatch(/^ {4}runs-on: macos-26$/m)
    const step = stepOf(build, 'Build the speech helper')
    const lines = step.split('\n').map(row => row.trim())
    const at = ['xcodebuild -version', 'pnpm build:dictation'].map(row => lines.indexOf(row))
    expect(at.every(i => i >= 0)).toBe(true)
    expect(at[0]).toBeLessThan(at[1] ?? 0)
    expect(step).toContain('xcrun --sdk macosx --show-sdk-version')
  })

  it('builds the helper before electron-builder in the Release workflow', () => {
    const text = read('.github/workflows/release.yml')
    const build = text.split(/^ {2}build:$/m)[1] ?? ''
    const order = ['Install dependencies', 'Build the speech helper', 'Release', 'Dry run build']
    const at = order.map(name => build.indexOf(`- name: ${name}\n`))
    expect(at.every(i => i >= 0)).toBe(true)
    expect([...at].sort((x, y) => x - y)).toEqual(at)
  })

  it('makes verify:release check the helper and the Speech Recognition usage text', () => {
    const script = read('scripts/verify-release.ts')
    expect(script).toContain(`Contents/MacOS/${HELPER_NAME}`)
    for (const name of [
      'the speech helper is in the app',
      'the speech helper is signed by the team, with the hardened runtime',
      'the speech helper has its Info.plist',
      'the app has the Speech Recognition usage text',
    ]) {
      expect(script).toContain(name)
    }
    expect(script).toContain('NSSpeechRecognitionUsageDescription')
  })
})
