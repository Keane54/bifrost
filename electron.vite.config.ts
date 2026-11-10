import tailwindcss from '@tailwindcss/vite'
import react from '@vitejs/plugin-react'
import { defineConfig } from 'electron-vite'

const FONT_FILE = /\.(woff2?|ttf|otf)$/i

export default defineConfig({
  main: {},
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
