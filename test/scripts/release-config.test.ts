import { readFileSync } from 'node:fs'
import { join } from 'node:path'
import { describe, expect, it } from 'vitest'

const ROOT = join(__dirname, '../..')
const read = (file: string): string => readFileSync(join(ROOT, file), 'utf8')

const ASSET_PATHS = [
  'dist/Bifrost-arm64.dmg',
  'dist/Bifrost-*-arm64-mac.zip',
  'dist/Bifrost-*-arm64-mac.zip.blockmap',
  'dist/latest-mac.yml',
]

describe('the release build config', () => {
  it('builds the DMG and the update ZIP for arm64', () => {
    const text = read('electron-builder.yml')
    expect(text).toMatch(/- target: dmg\n\s+arch: arm64/)
    expect(text).toMatch(/- target: zip\n\s+arch: arm64/)
    expect(text).toContain('artifactName: $' + '{productName}-arm64.$' + '{ext}')
  })

  it('keeps publish null for local builds, so they have no app-update.yml', () => {
    expect(read('electron-builder.yml')).toMatch(/^publish: null$/m)
  })

  it('sets the GitHub publish provider only in the release config', () => {
    const text = read('electron-builder.release.yml')
    expect(text).toMatch(/provider: github/)
    expect(text).toMatch(/owner: TheKeyholdingCompany/)
    expect(text).toMatch(/repo: bifrost/)
  })

  it('passes --publish never in the dist:release script', () => {
    const scripts = JSON.parse(read('package.json')).scripts
    expect(scripts['dist:release']).toContain('--publish never')
  })

  it('uploads the four update files with semantic-release', () => {
    const rc = JSON.parse(read('.releaserc.json'))
    const github = rc.plugins.find(
      (p: unknown) => Array.isArray(p) && p[0] === '@semantic-release/github',
    )
    const paths = github[1].assets.map((a: { path: string }) => a.path)
    expect(paths).toEqual(ASSET_PATHS)
  })

  it('uploads the same four files in the dry run', () => {
    const text = read('.github/workflows/release.yml')
    const step = text.split('- name: Upload the dry run DMG')[1]
    expect(step).toBeDefined()
    const block = step.match(/path: \|\n((?:\s+\S.*\n)+?)\s+retention-days/)
    expect(block).not.toBeNull()
    const lines = (block?.[1] ?? '')
      .split('\n')
      .map(l => l.trim())
      .filter(Boolean)
    expect(lines).toEqual(ASSET_PATHS)
  })

  it('has electron-updater as an exact dependency', () => {
    const pkg = JSON.parse(read('package.json'))
    expect(pkg.dependencies['electron-updater']).toMatch(/^\d+\.\d+\.\d+$/)
  })
})
