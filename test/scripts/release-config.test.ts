import { spawnSync } from 'node:child_process'
import { readFileSync } from 'node:fs'
import { join } from 'node:path'
import { describe, expect, it } from 'vitest'
import { UPDATE_OWNER, UPDATE_REPO } from '../../src/main/updates/updater'

const ROOT = join(__dirname, '../..')
const read = (file: string): string => readFileSync(join(ROOT, file), 'utf8')

// The text of the workflow step with the name, up to the next step.
function stepOf(workflow: string, name: string): string {
  return workflow.split(`- name: ${name}\n`)[1]?.split('- name:')[0] ?? ''
}

// The script of the "run: |" block of a step, with the indent of the block removed.
function runScriptOf(step: string): string {
  const lines = step.split('\n')
  const start = lines.findIndex(line => line.trim() === 'run: |')
  expect(start).toBeGreaterThan(-1)
  const block: string[] = []
  for (const line of lines.slice(start + 1)) {
    if (line.trim() !== '' && !/^ {10}/.test(line)) break
    block.push(line.slice(10))
  }
  return block.join('\n')
}

// The value of a "key: value" line of the publish block of the release config.
function publishValue(key: string): string | undefined {
  const block = read('electron-builder.release.yml').split(/^publish:$/m)[1] ?? ''
  return new RegExp(`^\\s+${key}: (\\S+)$`, 'm').exec(block)?.[1]
}

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

  it('sets the GitHub publish provider in the release config, and not in the local config', () => {
    expect(publishValue('provider')).toBe('github')
    expect(read('electron-builder.yml')).not.toMatch(/provider:/)
  })

  it('publishes to the repo that the updater reads, so the two cannot differ', () => {
    expect(publishValue('owner')).toBe(UPDATE_OWNER)
    expect(publishValue('repo')).toBe(UPDATE_REPO)
  })

  it('makes verify:release expect the repo that the updater reads in app-update.yml', () => {
    const script = read('scripts/verify-release.ts')
    expect(script).toContain(`const OWNER = '${UPDATE_OWNER}'`)
    expect(script).toContain(`const REPO = '${UPDATE_REPO}'`)
    expect(script).toContain('namesRepo(appUpdate, OWNER, REPO)')
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
    const step = text.split('- name: Upload the dry run files')[1]
    expect(step).toBeDefined()
    expect(step).toMatch(/^\s+name: bifrost-dry-run$/m)
    const block = step.match(/path: \|\n((?:\s+\S.*\n)+?)\s+retention-days/)
    expect(block).not.toBeNull()
    const lines = (block?.[1] ?? '')
      .split('\n')
      .map(l => l.trim())
      .filter(Boolean)
    expect(lines).toEqual(ASSET_PATHS)
  })

  it('prints the summary with the exec plugin before the notes of the notes generator', () => {
    const rc = JSON.parse(read('.releaserc.json'))
    const names = rc.plugins.map((p: unknown) => (Array.isArray(p) ? p[0] : p))
    // semantic-release joins the notes of the plugins in the order of the plugins.
    expect(names).toEqual([
      '@semantic-release/commit-analyzer',
      '@semantic-release/exec',
      '@semantic-release/release-notes-generator',
      '@semantic-release/github',
    ])
    const exec = rc.plugins[1][1]
    expect(exec.generateNotesCmd).toBe('node scripts/release/summary.ts')
    // The other steps of the exec plugin do not change.
    expect(exec.verifyReleaseCmd).toBe('echo $' + '{nextRelease.version} > .release-version')
    expect(exec.prepareCmd).toBe(
      'pnpm pkg set version=$' +
        '{nextRelease.version} && pnpm dist:release && pnpm verify:release',
    )
    expect(Object.keys(exec).sort()).toEqual(['generateNotesCmd', 'prepareCmd', 'verifyReleaseCmd'])
  })

  it('has a required summary input in the Release workflow, for each mode', () => {
    const text = read('.github/workflows/release.yml')
    const inputs = text.split(/^\s+inputs:$/m)[1]?.split(/^concurrency:$/m)[0] ?? ''
    // The lines of the summary input, up to the next input.
    const summary = inputs.split(/^ {6}summary:$/m)[1]?.split(/^ {6}\S/m)[0] ?? ''
    expect(summary).toMatch(/^\s+description: A short summary for the release notes$/m)
    expect(summary).toMatch(/^\s+type: string$/m)
    expect(summary).toMatch(/^\s+required: true$/m)
    expect(summary).not.toMatch(/^\s+default:/m)
  })

  it('gives the summary to the shell and to semantic-release only through the env', () => {
    const text = read('.github/workflows/release.yml')
    const env = 'RELEASE_SUMMARY: $' + '{{ inputs.summary }}'
    // A value in a run script would go into the shell as code. So each use is an env line.
    const uses = text.split('\n').filter(line => line.includes('inputs.summary'))
    expect(uses).toHaveLength(3)
    for (const line of uses) expect(line.trim()).toBe(env)
    expect(stepOf(text, 'Check the release summary')).toContain(env)
    for (const name of ['Find the next version', 'Release']) {
      const step = stepOf(text, name)
      expect(step, name).toContain(env)
      expect(step, name).toMatch(/pnpm exec semantic-release/)
    }
  })

  it('checks the summary in the first step of the check job', () => {
    const text = read('.github/workflows/release.yml')
    const check = text.split(/^ {2}check:$/m)[1]?.split(/^ {2}build:$/m)[0] ?? ''
    expect(check).toMatch(/^\s+runs-on: ubuntu-latest$/m)
    const first = check.split(/^\s+steps:$/m)[1]?.match(/^\s+- name: (.+)$/m)?.[1]
    expect(first).toBe('Check the release summary')
  })

  describe('the summary check step', () => {
    // Run the script of the step as GitHub runs a bash step, with the env of the step.
    function check(value: string): { status: number | null; out: string } {
      const step = stepOf(read('.github/workflows/release.yml'), 'Check the release summary')
      const script = runScriptOf(step)
      const result = spawnSync('bash', ['--noprofile', '--norc', '-eo', 'pipefail', '-c', script], {
        encoding: 'utf8',
        env: { LC_ALL: 'C.UTF-8', PATH: process.env.PATH ?? '', RELEASE_SUMMARY: value },
      })
      return { out: `${result.stdout}${result.stderr}`, status: result.status }
    }

    it('passes a summary of 1 to 600 characters, with white space around it', () => {
      expect(check('Bifrost now warns you.').status).toBe(0)
      expect(check(`  ${'a'.repeat(600)}\n `).status).toBe(0)
      expect(check('x').status).toBe(0)
    })

    it('fails for an empty summary and a summary of only white space', () => {
      for (const value of ['', '   ', ' \n\t ']) {
        const result = check(value)
        expect(result.status).toBe(1)
        expect(result.out).toContain('::error::The release summary is empty.')
      }
    })

    it('fails for a summary of more than 600 characters', () => {
      const result = check(` ${'a'.repeat(601)} `)
      expect(result.status).toBe(1)
      expect(result.out).toContain('::error::The release summary has 601 characters.')
      expect(result.out).toContain('The limit is 600.')
    })

    it('fails for a summary with a line that starts with "#", also after spaces', () => {
      for (const value of ['# Big news', 'First line.\n## Second', 'One.\n \t### x', '#tag']) {
        const result = check(value)
        expect(result.status, value).toBe(1)
        expect(result.out).toContain('::error::A line of the release summary starts with "#".')
      }
    })

    it('passes a "#" that is not at the start of a line', () => {
      expect(check('Fix #12 and the C# sample.').status).toBe(0)
    })

    it('does not run the summary as code', () => {
      const result = check('$(echo injected) `echo injected` ; echo injected')
      expect(result.status).toBe(0)
      expect(result.out).not.toMatch(/^injected$/m)
    })
  })

  it('has electron-updater as an exact dependency', () => {
    const pkg = JSON.parse(read('package.json'))
    expect(pkg.dependencies['electron-updater']).toMatch(/^\d+\.\d+\.\d+$/)
  })
})
