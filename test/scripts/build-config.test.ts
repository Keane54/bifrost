// A source test of the runtime packages. The app ships only the packages that it needs.
import { readFileSync } from 'node:fs'
import { join } from 'node:path'
import { describe, expect, it } from 'vitest'

const ROOT = join(import.meta.dirname, '..', '..')

describe('the runtime packages', () => {
  it('ship only node-pty and electron-updater', () => {
    const pkg = JSON.parse(readFileSync(join(ROOT, 'package.json'), 'utf8'))
    expect(Object.keys(pkg.dependencies).sort()).toEqual(['electron-updater', 'node-pty'])
  })
  it('are not imported from @electron-toolkit/utils in the main process', () => {
    const code = readFileSync(join(ROOT, 'src', 'main', 'index.ts'), 'utf8')
    expect(code).not.toContain("from '@electron-toolkit/utils'")
  })
  it('keep @electron-toolkit/utils out of the lockfile', () => {
    expect(readFileSync(join(ROOT, 'pnpm-lock.yaml'), 'utf8')).not.toContain(
      '@electron-toolkit/utils',
    )
  })
})
