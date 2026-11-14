// Discuss with Claude (Modules design 8.4, plan Task 10). A module can only ask. Heimdall shows
// the request in its own panel, which a module can never draw. The prompt box always starts
// empty, and only the text of the user goes to Claude. The cards and the title of the module show
// in the panel as plain text, and only the main process copies a card. The user picks the folder.
// The session starts with the normal Claude setup of the user, through the New session path. The
// module gets no handle to the session and no event about it.

import { dirname, resolve } from 'node:path'
import { cleanText } from '../../shared/input'
import { stripInvisible } from '../../shared/invisible'
import {
  type DiscussCard,
  type ModuleDiscuss,
  REFUSED_BAD_MODULE_INPUT,
  REFUSED_DISCUSS_OPEN,
  REFUSED_DISCUSS_WAIT,
  REFUSED_MODULE_OFF,
  REFUSED_NO_REQUEST,
} from '../../shared/modules'
import {
  checkNewSessionSpec,
  MAX_NAME,
  type NewSessionSpec,
  REASON_DIR_MISSING,
  REASON_NO_FOLDER,
} from '../../shared/new-session'
import { isPlainObject } from '../../shared/plain-object'
import { MAX_DISCUSS_SESSIONS } from './module-state'

export const DISCUSS_MAX_TITLE = 80
export const DISCUSS_MAX_CARDS = 8
export const DISCUSS_MAX_LABEL = 40
export const DISCUSS_MAX_TEXT = 4000
// After a cancel, the module waits this time before it can ask again.
export const DISCUSS_WAIT_MS = 5000

// Texts that the user reads in Heimdall's panel.
export const REASON_DISCUSS_EMPTY = 'Write a prompt first.'
export const REASON_MODULE_FOLDER =
  "Bifrost won't start a session in a module folder. Choose another folder."
export const REASON_FOLDER_CHECK = "Bifrost can't check that folder. Choose another folder."

// A title or a label has one line, and no control, format or separator character after the
// strip, as a manifest text.
const CONTROL = /[\p{Cc}\p{Cf}\p{Zl}\p{Zp}]/u

export interface DiscussDeps {
  // The approved name of a module that is on and has the discuss permission, else null.
  moduleName(moduleId: string): string | null
  // Show the request in Heimdall's panel of the Bifrost page.
  open(view: ModuleDiscuss): void
  // Write a text to the system clipboard. Only the main process does this.
  writeClipboard(text: string): void | Promise<void>
  // The New session path (createSessionActions). It checks the values again and runs claude --bg.
  createSession(spec: NewSessionSpec): Promise<{ sessionId: string }>
  realpath(path: string): Promise<string>
  // The device and the inode of a folder. Two paths to one folder give the same values, also a
  // firmlink form such as /System/Volumes/Data/Users/...
  stat(path: string): Promise<{ dev: number | bigint; ino: number | bigint }>
  // The folders that a module can write, and the folders of the module jobs. A session never
  // starts in them or in a folder under them.
  blockedFolders: readonly string[]
  // Save the id of a started session in the modules state, so Heimdall hides it also after a
  // restart (ruling P12). A hand-over gives a saved session a new id, and carry saves it too.
  saveSession(sessionId: string): void
  carrySession(from: string, to: string): void
  // A clock in milliseconds.
  now(): number
  requestId(): string
}

export interface Discuss {
  // The request of a module. Heimdall checked the module, the caps and the discuss permission
  // first. The answer to the module is null.
  request(moduleId: string, args: unknown): Promise<null>
  // Copy the text of a card. Only Heimdall's panel asks for it. This resolves after the write.
  copy(requestId: unknown, cardIndex: unknown): Promise<void>
  // Start the session with the prompt of the user, in the folder of the user. The answer goes
  // only to Heimdall's panel, never to the module.
  start(requestId: unknown, input: unknown): Promise<{ sessionId: string }>
  // The user closed the request. A cancel of a request that is not open does nothing.
  cancel(requestId: unknown): void
  // The page ended. Drop the open request.
  clear(): void
  // True for a session that Discuss started (ruling P12). Heimdall hides it from each module.
  isDiscussSession(sessionId: string): boolean
  // A hand-over gave the session a new id. The new session stays hidden.
  carryOver(from: string, to: string): void
}

interface OpenRequest {
  view: ModuleDiscuss
  // The module part of the session name. It never starts with "-" or a space.
  label: string
  // True while a start runs.
  starting: boolean
  // True when a cancel came during a start. The request then closes after the start.
  cancelled: boolean
}

function refuse(code: string): never {
  throw new Error(code)
}

// The value as an object with only the given keys and each required key.
function objectWith(
  value: unknown,
  keys: readonly string[],
  required: readonly string[],
): Record<string, unknown> {
  if (!isPlainObject(value)) refuse(REFUSED_BAD_MODULE_INPUT)
  const own = Object.keys(value)
  if (own.some(k => !keys.includes(k)) || required.some(k => !own.includes(k))) {
    refuse(REFUSED_BAD_MODULE_INPUT)
  }
  return value
}

// A text of one line with no invisible character. The limit counts the text that the module
// sent.
function lineText(value: unknown, max: number): string {
  if (typeof value !== 'string' || value.length > max) refuse(REFUSED_BAD_MODULE_INPUT)
  const text = stripInvisible(value).trim()
  if (text === '' || CONTROL.test(text)) refuse(REFUSED_BAD_MODULE_INPUT)
  return text
}

// A card text keeps its tabs and new lines. It loses the invisible and the control characters.
function cardText(value: unknown): string {
  if (typeof value !== 'string' || value.length > DISCUSS_MAX_TEXT) {
    refuse(REFUSED_BAD_MODULE_INPUT)
  }
  const text = cleanText(stripInvisible(value))
  if (text.trim() === '') refuse(REFUSED_BAD_MODULE_INPUT)
  return text
}

function cardsOf(value: unknown): DiscussCard[] {
  if (value === undefined) return []
  if (!Array.isArray(value) || value.length > DISCUSS_MAX_CARDS) refuse(REFUSED_BAD_MODULE_INPUT)
  return value.map(card => {
    const input = objectWith(card, ['label', 'text'], ['label', 'text'])
    return { label: lineText(input.label, DISCUSS_MAX_LABEL), text: cardText(input.text) }
  })
}

// The first characters of the text that fit in max UTF-16 code units. The cut never splits a
// character.
function firstChars(text: string, max: number): string {
  let out = ''
  for (const ch of text) {
    if (out.length + ch.length > max) break
    out += ch
  }
  return out
}

// The name of the session (ruling P13): "<module name>: <the first words of the prompt>". Only
// the approved name and the text of the user go into it. A Hand over puts the name into the note
// path and into the first prompt of the new session, so the title of the module never goes into
// it. The name has one line and MAX_NAME characters or less. A first word that is too long is
// cut, and the cut never splits a character.
export function discussSessionName(moduleName: string, prompt: string): string {
  const words = prompt.split(/\s+/u).filter(word => word !== '')
  let name = `${moduleName}:`
  for (const [index, word] of words.entries()) {
    if (name.length + 1 + word.length <= MAX_NAME) {
      name += ` ${word}`
      continue
    }
    if (index === 0) name += ` ${firstChars(word, MAX_NAME - name.length - 1)}`
    break
  }
  return name.trimEnd()
}

// A path for a compare. By default a folder name on a Mac does not change with the case or the
// Unicode form of its letters.
function fold(path: string): string {
  return path.normalize('NFC').toLowerCase()
}

// True for the error of a path that does not exist.
function isMissing(error: unknown): boolean {
  const code = (error as { code?: unknown } | null)?.code
  return code === 'ENOENT' || code === 'ENOTDIR'
}

function isUnder(path: string, root: string): boolean {
  const p = fold(path)
  const r = fold(root)
  return p === r || p.startsWith(r.endsWith('/') ? r : `${r}/`)
}

// The module part of the session name. claude reads a name that starts with "-" as a flag, so
// New session refuses it. Such a name loses its "-" and its spaces at the start.
function labelOf(name: string, moduleId: string): string {
  return (
    stripInvisible(name)
      .replace(/^[\s-]+/u, '')
      .trim() || moduleId
  )
}

export function createDiscuss(deps: DiscussDeps): Discuss {
  let open: OpenRequest | null = null
  // The time from which each module that cancelled can ask again.
  const waitUntil = new Map<string, number>()
  // The ids of the sessions that Discuss started in this run (ruling P12). Heimdall can hide a
  // session at once, before the save of its id ends.
  const started = new Set<string>()

  function openOf(requestId: unknown): OpenRequest {
    if (open === null || typeof requestId !== 'string' || open.view.requestId !== requestId) {
      refuse(REFUSED_NO_REQUEST)
    }
    return open
  }

  // The user can turn the module off or remove its permission while the request is open. Then
  // the request closes.
  function checkModule(req: OpenRequest): void {
    if (deps.moduleName(req.view.moduleId) !== null) return
    if (open === req) open = null
    refuse(REFUSED_MODULE_OFF)
  }

  // Each blocked folder, as given and as its real path.
  async function blockedRoots(): Promise<string[]> {
    const plain = deps.blockedFolders.map(folder => resolve(folder))
    const real = await Promise.all(plain.map(folder => deps.realpath(folder).catch(() => null)))
    return [...plain, ...real.filter((path): path is string => path !== null)]
  }

  // The identity of a folder: its device and its inode. With missingOk, a folder that does not
  // exist gives null. Each other failure refuses the folder of the user, so a failed check never
  // lets a folder pass (fail closed).
  async function identity(path: string, missingOk: boolean): Promise<string | null> {
    try {
      const { dev, ino } = await deps.stat(path)
      return `${dev}:${ino}`
    } catch (error) {
      if (missingOk && isMissing(error)) return null
      refuse(REASON_FOLDER_CHECK)
    }
  }

  // True when the folder or a folder above it is a blocked folder, by device and inode. A path
  // compare cannot see that two paths are one folder, for example a firmlink form. A blocked
  // folder that does not exist is skipped.
  async function underBlocked(real: string): Promise<boolean> {
    const found = await Promise.all(
      deps.blockedFolders.map(folder => identity(resolve(folder), true)),
    )
    const blocked = new Set(found.filter((id): id is string => id !== null))
    if (blocked.size === 0) return false
    for (let path = real; ; path = dirname(path)) {
      const id = await identity(path, false)
      if (id !== null && blocked.has(id)) return true
      if (dirname(path) === path) return false
    }
  }

  // Remember a session in this run. Above the cap of the saved list, the oldest id goes.
  function remember(sessionId: string): void {
    started.delete(sessionId)
    started.add(sessionId)
    for (const old of started) {
      if (started.size <= MAX_DISCUSS_SESSIONS) break
      started.delete(old)
    }
  }

  // The real path of the folder of the user. A symbolic link cannot get past the check.
  async function folderOf(cwd: string): Promise<string> {
    const given = cwd.trim()
    if (!given.startsWith('/')) refuse(REASON_NO_FOLDER)
    const path = resolve(given)
    const roots = await blockedRoots()
    if (roots.some(root => isUnder(path, root))) refuse(REASON_MODULE_FOLDER)
    let real: string
    try {
      real = await deps.realpath(path)
    } catch {
      refuse(REASON_DIR_MISSING)
    }
    if (roots.some(root => isUnder(real, root))) refuse(REASON_MODULE_FOLDER)
    if (await underBlocked(real)) refuse(REASON_MODULE_FOLDER)
    return real
  }

  return {
    cancel(requestId) {
      if (open === null || typeof requestId !== 'string' || open.view.requestId !== requestId) {
        return
      }
      waitUntil.set(open.view.moduleId, deps.now() + DISCUSS_WAIT_MS)
      if (open.starting) open.cancelled = true
      else open = null
    },

    carryOver(from, to) {
      if (started.has(from)) remember(to)
      deps.carrySession(from, to)
    },

    clear() {
      open = null
    },

    async copy(requestId, cardIndex) {
      const req = openOf(requestId)
      const { cards } = req.view
      const card =
        typeof cardIndex === 'number' && Number.isInteger(cardIndex) ? cards[cardIndex] : undefined
      if (card === undefined) refuse(REFUSED_BAD_MODULE_INPUT)
      checkModule(req)
      await deps.writeClipboard(stripInvisible(card.text))
    },

    isDiscussSession(sessionId) {
      return started.has(sessionId)
    },

    async request(moduleId, args) {
      const input = objectWith(args, ['cards', 'title'], ['title'])
      const title = lineText(input.title, DISCUSS_MAX_TITLE)
      const cards = cardsOf(input.cards)
      if (open !== null) refuse(REFUSED_DISCUSS_OPEN)
      const now = deps.now()
      for (const [id, until] of waitUntil) if (until <= now) waitUntil.delete(id)
      if (waitUntil.has(moduleId)) refuse(REFUSED_DISCUSS_WAIT)
      const name = deps.moduleName(moduleId)
      if (name === null) refuse(REFUSED_MODULE_OFF)
      // The manifest check allows some invisible characters, for example a Hangul filler. The
      // name goes into the label of the session, so it loses them too.
      const moduleName = stripInvisible(name).trim() || moduleId
      const view: ModuleDiscuss = {
        cards,
        moduleId,
        moduleName,
        requestId: deps.requestId(),
        title,
      }
      open = { cancelled: false, label: labelOf(name, moduleId), starting: false, view }
      deps.open(view)
      return null
    },

    async start(requestId, input) {
      const req = openOf(requestId)
      if (req.starting) refuse(REFUSED_NO_REQUEST)
      const values = objectWith(input, ['cwd', 'prompt'], ['cwd', 'prompt'])
      const { cwd, prompt: typed } = values
      if (typeof cwd !== 'string' || typeof typed !== 'string') refuse(REFUSED_BAD_MODULE_INPUT)
      checkModule(req)
      // Only the text of the user, never a card text.
      const prompt = cleanText(stripInvisible(typed)).trim()
      if (prompt === '') refuse(REASON_DISCUSS_EMPTY)
      req.starting = true
      try {
        const folder = await folderOf(cwd)
        // The normal Claude setup of the user: no model, permission mode or worktree flag. The
        // checks of New session refuse a prompt that starts with "-" or is a claude command.
        const checked = checkNewSessionSpec({
          cwd: folder,
          model: '',
          name: discussSessionName(req.label, prompt),
          permissionMode: '',
          prompt,
          worktree: false,
        })
        if (!checked.ok) refuse(checked.reason)
        if (req.cancelled) refuse(REFUSED_NO_REQUEST)
        const { sessionId } = await deps.createSession(checked.spec)
        remember(sessionId)
        deps.saveSession(sessionId)
        if (open === req) open = null
        return { sessionId }
      } catch (error) {
        if (req.cancelled && open === req) open = null
        throw error
      } finally {
        req.starting = false
      }
    },
  }
}
