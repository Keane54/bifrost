import tailwindcss from '@tailwindcss/vite'
import react from '@vitejs/plugin-react'
import { defineConfig } from 'electron-vite'
import { moduleApiPlugin } from './scripts/module-api/build'

const FONT_FILE = /\.(woff2?|ttf|otf)$/i

export default defineConfig({
  // The main build also compiles the client library of the modules (ruling P10).
  main: { plugins: [moduleApiPlugin()] },
  preload: {
    build: {
      rollupOptions: {
        // A sandboxed preload must be CommonJS.
        output: { entryFileNames: '[name].cjs', format: 'cjs' },
      },
    },
  },
  renderer: {
    build: {
      // Ship fonts as files: the CSP in index.html blocks data: fonts.
      assetsInlineLimit: filePath => (FONT_FILE.test(filePath) ? false : undefined),
    },
    plugins: [react(), tailwindcss()],
  },
})
