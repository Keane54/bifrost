import { rmSync } from 'node:fs'
import { mkdir, open } from 'node:fs/promises'
import { join } from 'node:path'

// The name of the file that tells the scripts that Bifrost runs (spec section 5.3).
export const ACTIVE_FILE = 'active'

export interface ActiveMarker {
  // Make the directory and an empty marker file with mode 0600.
  create(): Promise<void>
  // Delete the marker file. A missing file is not an error. This call never throws.
  remove(): void
}

// The hook and the statusline wrapper do their work only while the marker file exists.
// So no event files and no status copies collect while Bifrost is closed.
// remove is synchronous, because Bifrost calls it in the will-quit event.
export function createActiveMarker(bifrostHome: string): ActiveMarker {
  const file = join(bifrostHome, ACTIVE_FILE)
  return {
    async create() {
      await mkdir(bifrostHome, { recursive: true })
      const handle = await open(file, 'w', 0o600)
      try {
        await handle.chmod(0o600)
      } finally {
        await handle.close()
      }
    },
    remove() {
      try {
        rmSync(file, { force: true })
      } catch (error) {
        console.warn(`Bifrost could not delete ${file}:`, error)
      }
    },
  }
}
