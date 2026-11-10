// This script draws the Bifrost icon from the colours of app.css and writes the icon files.
// It also draws resources/icon-dev.png: the same icon with a "dev" badge. Only a dev start uses it.
// Run it with: node scripts/make-icon.ts
import { execFileSync } from 'node:child_process'
import { mkdirSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'
import { drawDevIcon } from './icon/dev-badge.ts'
import { drawIcon, encodePng, readPalette } from './icon/draw.ts'

const ROOT = join(dirname(fileURLToPath(import.meta.url)), '..')
const palette = readPalette(readFileSync(join(ROOT, 'src/renderer/src/styles/app.css'), 'utf8'))

function png(size: number): Buffer {
  return encodePng(size, size, drawIcon(size, palette))
}

const iconset = join(ROOT, 'build/icon.iconset')
rmSync(iconset, { force: true, recursive: true })
// The finally block removes the iconset folder also when a step fails.
try {
  mkdirSync(iconset, { recursive: true })
  for (const size of [16, 32, 128, 256, 512]) {
    writeFileSync(join(iconset, `icon_${size}x${size}.png`), png(size))
    writeFileSync(join(iconset, `icon_${size}x${size}@2x.png`), png(size * 2))
  }
  writeFileSync(join(ROOT, 'build/icon.png'), png(1024))
  writeFileSync(join(ROOT, 'resources/icon.png'), png(512))
  writeFileSync(
    join(ROOT, 'resources/icon-dev.png'),
    encodePng(512, 512, drawDevIcon(512, palette)),
  )
  execFileSync('iconutil', ['-c', 'icns', iconset, '-o', join(ROOT, 'build/icon.icns')])
} finally {
  rmSync(iconset, { force: true, recursive: true })
}
