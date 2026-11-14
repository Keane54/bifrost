// The build of the client library of the modules (scripts/module-api/build.ts, ruling P10). The
// build turns the TypeScript source into the classic script that the module protocol serves at
// _bifrost/api.js.
import { readdirSync, readFileSync } from 'node:fs'
import { join, relative } from 'node:path'
import { Script } from 'node:vm'
import { describe, expect, it } from 'vitest'
import {
  compileModuleApi,
  MODULE_API_ASSET,
  MODULE_API_SOURCE,
  moduleApiPlugin,
} from '../../scripts/module-api/build'

const ROOT = join(__dirname, '..', '..')
const JS_FILE = /\.(c|m)?js$/
// Claude Code can write files into this folder. Git ignores it, and Bifrost does not ship it.
const IGNORED = 'resources/live-mod/.claude-plugin/types/'

// The files under a folder, as paths from the repository root.
function filesUnder(dir: string): string[] {
  return readdirSync(join(ROOT, dir), { recursive: true, withFileTypes: true })
    .filter(entry => entry.isFile())
    .map(entry => relative(ROOT, join(entry.parentPath, entry.name)))
    .filter(file => !file.startsWith(IGNORED))
}

type EmittedFile = { fileName: string; source: string; type: string }

// Run the hooks of the plugin as the main build does, and give the files that it emits.
async function runPlugin(root: string): Promise<EmittedFile[]> {
  const emitted: EmittedFile[] = []
  const watched: string[] = []
  const plugin = moduleApiPlugin() as unknown as {
    buildStart(this: unknown): void
    configResolved(config: { root: string }): void
    generateBundle(this: unknown): Promise<void>
  }
  const context = {
    addWatchFile: (file: string) => watched.push(file),
    emitFile: (file: EmittedFile) => emitted.push(file),
  }
  plugin.configResolved({ root })
  plugin.buildStart.call(context)
  await plugin.generateBundle.call(context)
  expect(watched).toEqual([join(root, MODULE_API_SOURCE)])
  return emitted
}

describe('the build of the module client library', () => {
  it('keeps its TypeScript source in src/module-api', () => {
    expect(MODULE_API_SOURCE).toBe('src/module-api/api.ts')
    expect(MODULE_API_ASSET).toBe('module-api/api.js')
  })

  it('compiles the source to a classic script with no import or export', async () => {
    const code = await compileModuleApi(readFileSync(join(ROOT, MODULE_API_SOURCE), 'utf8'))
    // A classic script cannot hold an import or an export statement, or import.meta.
    expect(() => new Script(code, { filename: 'api.js' })).not.toThrow()
    expect(code).not.toMatch(/^\s*(import|export)\b/m)
    expect(code).toMatch(/Object\.defineProperty\(globalThis, ["']bifrost["']/)
  })

  it('refuses a source that is not a classic script', async () => {
    const message = 'The client library must be a classic script, with no import or export.'
    await expect(compileModuleApi("import x from 'y'\nx()\n")).rejects.toThrow(message)
    await expect(compileModuleApi('export const a: number = 1\n')).rejects.toThrow(message)
  })

  it('emits the compiled script into the main build', async () => {
    const emitted = await runPlugin(ROOT)
    const source = readFileSync(join(ROOT, MODULE_API_SOURCE), 'utf8')
    expect(emitted).toEqual([
      { fileName: MODULE_API_ASSET, source: await compileModuleApi(source), type: 'asset' },
    ])
  })

  it('ships no hand-written JavaScript to module authors', () => {
    // The user's rule (ruling P10): Bifrost gives module authors only TypeScript source.
    const files = [...filesUnder('resources'), ...filesUnder('src/module-api')]
    expect(files.filter(file => JS_FILE.test(file))).toEqual([])
  })
})
