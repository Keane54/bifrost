// Bundles the test module into dist/module.js, one script that the host runs as it is: an IIFE for
// ES2022 with React's production build inside, and nothing it would need to load later.
// Run: node build.ts
import { statSync } from 'node:fs'
import { join } from 'node:path'

import { build } from 'esbuild'

const outfile = join(import.meta.dirname, 'dist', 'module.js')

await build({
  absWorkingDir: import.meta.dirname,
  entryPoints: ['src/app.tsx'],
  outfile,
  bundle: true,
  format: 'iife',
  target: 'es2022',
  jsx: 'automatic',
  minify: true,
  define: { 'process.env.NODE_ENV': '"production"' },
  logLevel: 'warning',
})

console.log(`dist/module.js: ${statSync(outfile).size} bytes`)
