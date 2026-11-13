// Source tests of the microphone permission in the build config (voice dictation of Claude Code).
import { readFileSync } from 'node:fs'
import { join } from 'node:path'
import { describe, expect, it } from 'vitest'
import { releaseConfig } from '../../electron-builder.release.ts'

const ROOT = join(__dirname, '../..')
const read = (file: string): string => readFileSync(join(ROOT, file), 'utf8')

describe('the microphone permission of the build', () => {
  it('has the audio-input entitlement in the entitlements file', () => {
    expect(read('build/entitlements.mac.plist')).toMatch(
      /<key>com\.apple\.security\.device\.audio-input<\/key>\s*<true\/>/,
    )
  })

  it('has the usage text in the base config, so each build has it', () => {
    const text = read('electron-builder.yml')
    expect(text).toContain('extendInfo:')
    expect(text).toContain(
      'NSMicrophoneUsageDescription: Bifrost uses the microphone when you talk to Claude.',
    )
  })

  it('gives the entitlements file to the app, and keeps the default inherit file of the helpers', () => {
    const mac = releaseConfig({ APPLE_SIGNING_IDENTITY: 'Jane Doe (ABCDE12345)' }).mac
    expect(mac?.entitlements).toBe('build/entitlements.mac.plist')
    expect(mac?.entitlementsInherit).toBeUndefined()
    expect(mac?.hardenedRuntime).toBe(true)
  })

  it('makes verify:release check the entitlement and the usage text of the signed app', () => {
    const script = read('scripts/verify-release.ts')
    expect(script).toContain('com.apple.security.device.audio-input')
    expect(script).toContain('NSMicrophoneUsageDescription')
    expect(script).toContain('the app has the microphone entitlement')
    expect(script).toContain('the app has the microphone usage text')
  })
})
