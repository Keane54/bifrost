import { mkdir, open } from 'node:fs/promises'
import { dirname, join } from 'node:path'
import type { SessionRow } from '../../shared/types'
import { UUID_PATTERN } from './scripts'

// The name of the file that stops the original statusline command for a session (spec section 6.3).
export const QUIET_FILE = 'quiet'

const UUID = new RegExp(UUID_PATTERN)

// Make the directory of the file, then an empty file with mode 0600.
async function writeQuietFile(file: string): Promise<void> {
  await mkdir(dirname(file), { mode: 0o700, recursive: true })
  const handle = await open(file, 'w', 0o600)
  try {
    await handle.chmod(0o600)
  } finally {
    await handle.close()
  }
}

// Write <sessionsDir>/<id>/quiet for each owned session that is not parked.
// Chat windows in Bifrost show no statusline, so the wrapper does not run the original command
// for these sessions (spec section 20).
// The marker writes each file one time. After a failed write, it tries again at the next call.
// mark never rejects.
export function createQuietMarker(
  sessionsDir: string,
  writeFile: (file: string) => Promise<void> = writeQuietFile,
): { mark(rows: SessionRow[]): Promise<void> } {
  const marked = new Set<string>()
  // The IDs with a write that did not end yet. A second call does not write them again.
  const writing = new Set<string>()
  return {
    async mark(rows) {
      const ids = new Set<string>()
      for (const row of rows) {
        if (row.kind !== 'owned' || row.state === 'parked') continue
        // The ID becomes a path. Accept only a UUID.
        if (!UUID.test(row.sessionId)) continue
        if (marked.has(row.sessionId) || writing.has(row.sessionId)) continue
        ids.add(row.sessionId)
      }
      await Promise.all(
        [...ids].map(async id => {
          writing.add(id)
          try {
            await writeFile(join(sessionsDir, id, QUIET_FILE))
            marked.add(id)
          } catch {
            // Try again at the next call.
          } finally {
            writing.delete(id)
          }
        }),
      )
    },
  }
}
