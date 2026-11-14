// The build of the client library of the modules (ruling P10). Bifrost gives module authors only
// TypeScript source. The main build compiles src/module-api/api.ts to out/main/module-api/api.js,
// and the module protocol serves that file at /_bifrost/api.js (module-protocol.ts in src/main).
// The result must stay a classic script: a frame loads it with a plain <script> tag.
import { readFile } from 'node:fs/promises'
import { join } from 'node:path'
import { Script } from 'node:vm'
import { type Plugin, transformWithOxc } from 'vite'

// The source, from the repository root.
export const MODULE_API_SOURCE = 'src/module-api/api.ts'
// The built file, from the output folder of the main build.
export const MODULE_API_ASSET = 'module-api/api.js'

const NOT_CLASSIC = 'The client library must be a classic script, with no import or export.'

// Remove the types from the source. Then make sure that the result compiles as a classic script.
// A classic script cannot hold an import or an export statement, or import.meta.
export async function compileModuleApi(source: string): Promise<string> {
  const { code } = await transformWithOxc(source, 'api.ts', { lang: 'ts', sourceType: 'script' })
  try {
    new Script(code, { filename: 'api.js' })
  } catch {
    throw new Error(NOT_CLASSIC)
  }
  return code
}

// The plugin of the main build. It adds the built client library to the output of the build. In
// a dev run, a change of the source builds it again.
export function moduleApiPlugin(): Plugin {
  let sourceFile = ''
  return {
    buildStart() {
      this.addWatchFile(sourceFile)
    },
    configResolved(config) {
      sourceFile = join(config.root, MODULE_API_SOURCE)
    },
    async generateBundle() {
      const code = await compileModuleApi(await readFile(sourceFile, 'utf8'))
      this.emitFile({ fileName: MODULE_API_ASSET, source: code, type: 'asset' })
    },
    name: 'bifrost-module-api',
  }
}
