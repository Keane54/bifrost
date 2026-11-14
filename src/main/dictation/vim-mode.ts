// The vim mode of Claude Code (ruling D7). In vim mode, a letter in the NORMAL mode of Claude's
// prompt runs as a command, and Bifrost cannot see the mode. So dictation stays off while
// Claude's settings turn vim mode on.
// The name of the setting is not known for each Claude version. Claude 2.1.325 has the names
// vimMode, vimModeEnabled, isVimModeEnabled and EDITOR_MODES. Older versions use editorMode "vim"
// in ~/.claude.json. Each of them counts. Only the top level of a file counts, because deeper
// objects of ~/.claude.json hold other data, for example the settings of each project.
import { stat } from 'node:fs/promises'
import { isPlainObject } from '../../shared/plain-object'

const FLAG_KEYS = ['vimMode', 'vimModeEnabled', 'isVimModeEnabled'] as const
const MODE_KEYS = ['editorMode', 'EDITOR_MODES'] as const

const isVim = (value: unknown): boolean =>
  typeof value === 'string' && value.trim().toLowerCase() === 'vim'

// True when the parsed content of a settings file turns vim mode on.
export function vimModeOf(data: unknown): boolean {
  if (!isPlainObject(data)) return false
  const own = (key: string): unknown => (Object.hasOwn(data, key) ? data[key] : undefined)
  if (FLAG_KEYS.some(key => own(key) === true || isVim(own(key)))) return true
  return MODE_KEYS.some(key => isVim(own(key)))
}

// The time and the size of a file. A change of either one means a new content.
export interface FileStamp {
  mtimeMs: number
  size: number
}

export interface VimModeDeps {
  // The stamp of a regular file, or null when no regular file is there.
  stat(file: string): Promise<FileStamp | null>
  // The parsed content of a file, or null when the read or the parse fails.
  read(file: string): Promise<unknown>
}

// The stamp of a regular file, or null.
export async function fileStamp(file: string): Promise<FileStamp | null> {
  try {
    const info = await stat(file)
    return info.isFile() ? { mtimeMs: info.mtimeMs, size: info.size } : null
  } catch {
    return null
  }
}

// Make the check that a hold runs. ~/.claude.json can be many MB, so the check parses a file only
// when its stamp changes. Claude writes the file often, so a read can see a part of it. A parse
// error then keeps the last good value of the file. With no good value, the file gives false.
export function createVimModeCheck(
  files: readonly string[],
  deps: VimModeDeps,
): () => Promise<boolean> {
  const known = new Map<string, { stamp: FileStamp; vim: boolean }>()

  async function fileVim(file: string): Promise<boolean> {
    const stamp = await deps.stat(file).catch(() => null)
    if (stamp === null) {
      known.delete(file)
      return false
    }
    const last = known.get(file)
    if (last && last.stamp.mtimeMs === stamp.mtimeMs && last.stamp.size === stamp.size) {
      return last.vim
    }
    const data = await deps.read(file).catch(() => null)
    const vim = data === null ? (last?.vim ?? false) : vimModeOf(data)
    known.set(file, { stamp, vim })
    return vim
  }

  return async () => (await Promise.all(files.map(fileVim))).some(Boolean)
}
