// Write a hand-over note to a new file (spec 8, step 4).
// Bifrost never writes over a file. Only the user can read the folder and the file.
import { mkdir, writeFile } from 'node:fs/promises'
import { basename, extname, join } from 'node:path'

// The number of names that Bifrost tries before it stops: the name, then -2 to -100.
const MAX_TRIES = 100

// Write the text to dir/fileName and resolve with the path. Make dir with mode 700 when it does
// not exist. When something exists at the path, add -2 before the extension, then -3, and so on.
// fileName must be a plain file name, so the file is always in dir.
export async function writeNoteFile(dir: string, fileName: string, text: string): Promise<string> {
  if (fileName === '' || fileName === '.' || fileName === '..' || basename(fileName) !== fileName) {
    throw new Error("The note file name isn't valid.")
  }
  await mkdir(dir, { mode: 0o700, recursive: true })
  const ext = extname(fileName)
  const stem = fileName.slice(0, fileName.length - ext.length)
  for (let n = 1; n <= MAX_TRIES; n++) {
    const path = join(dir, n === 1 ? fileName : `${stem}-${n}${ext}`)
    try {
      // The flag wx fails when the path exists, also for a link. So no write goes through a link.
      await writeFile(path, text, { flag: 'wx', mode: 0o600 })
      return path
    } catch (error) {
      if ((error as NodeJS.ErrnoException).code !== 'EEXIST') throw error
    }
  }
  throw new Error('Too many hand-over notes have this name.')
}
