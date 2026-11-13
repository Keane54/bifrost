// Read the hand-over note from the transcript of the old session (spec 8, step 3).
// The transcript format is internal to Claude Code and can change. So the reader is strict for
// each line and for each entry that it uses: the request, the replies, the turn end and the new
// messages from the user. A form that it does not know is a failure. It skips the metadata
// entries, because their types change between versions of Claude Code.

import { isRecord } from '../../shared/plain-object'
import { maskToken } from '../log/mask'
import { NOTE_END, NOTE_START, requestLine } from './prompt'

export type ReplyState =
  | { kind: 'pending' }
  | { kind: 'done'; note: string; model: string; permissionMode: string | null }
  | { kind: 'failed'; reason: string }

// The block types of an assistant entry that the reader knows.
const BLOCK_TYPES: readonly string[] = ['text', 'thinking', 'redacted_thinking', 'tool_use']
// Claude Code writes this model on an entry that the API did not make, for example an error.
const SYNTHETIC = '<synthetic>'

// The app shows each reason in parentheses after a failure text. So each reason is short.
const REASON_LINE = 'a line of the transcript has an unknown form'
const REASON_EARLY_END = 'a turn ended before the hand-over request'
const REASON_REPLY = "the reply has a part that Bifrost doesn't know"
const REASON_INTERRUPT = 'the session was interrupted'
const REASON_USER = 'a new message came in during the hand-over'
const REASON_TWO_MARKERS = 'the reply has more than one note'
const REASON_NO_MARKERS = "the reply doesn't have both note markers"
const REASON_ORDER = 'the note markers are in the wrong order'
const REASON_EMPTY = 'the note is empty'
const REASON_NO_MODEL = 'the reply has no model name'

type Entry = Record<string, unknown>

function failed(reason: string): ReplyState {
  return { kind: 'failed', reason }
}

// One line as an entry: a JSON object with a string type. Else null.
function parseEntry(line: string): Entry | null {
  let value: unknown
  try {
    value = JSON.parse(line)
  } catch {
    return null
  }
  return isRecord(value) && typeof value.type === 'string' ? value : null
}

function isTurnEnd(entry: Entry): boolean {
  return entry.type === 'system' && entry.subtype === 'turn_duration'
}

// The text of a user entry: a string content, or the text blocks of an array content.
function userText(entry: Entry): string {
  const content = isRecord(entry.message) ? entry.message.content : undefined
  if (typeof content === 'string') return content
  if (!Array.isArray(content)) return ''
  return content
    .filter(block => isRecord(block) && block.type === 'text' && typeof block.text === 'string')
    .map(block => block.text)
    .join('\n')
}

// True when a line of the user text is the request line. Spaces at the ends of the line are
// allowed. A line with other text, for example a longer request ID, is not the request line.
function holdsRequest(entry: Entry, wanted: string): boolean {
  return userText(entry)
    .split(/\r\n|\r|\n/)
    .some(line => line.trim() === wanted)
}

// True for a user entry that is not a message from the user: a meta entry, or only tool results.
function isAllowedUser(entry: Entry): boolean {
  if (entry.isMeta === true) return true
  const content = isRecord(entry.message) ? entry.message.content : undefined
  if (!Array.isArray(content) || content.length === 0) return false
  return content.every(block => isRecord(block) && block.type === 'tool_result')
}

// True for the entry that Claude Code writes after an Interrupt: a user entry with this text.
function isInterrupt(entry: Entry): boolean {
  return entry.type === 'user' && userText(entry).startsWith('[Request interrupted by user')
}

// True for a message from the user (Review Focus 3): a user entry that isAllowedUser does not
// allow, or a queued command. Claude Code writes a message that the user types during a turn as
// a queued_command attachment, and gives it to Claude in that turn. The note of a background task
// is also a queued command, with the command mode task-notification. It is not a message from the
// user.
function isNewMessage(entry: Entry): boolean {
  if (entry.type === 'user') return !isAllowedUser(entry)
  if (entry.type !== 'attachment' || !isRecord(entry.attachment)) return false
  const { commandMode, type } = entry.attachment
  return type === 'queued_command' && commandMode !== 'task-notification'
}

// The texts of the text blocks of an assistant entry. null when the entry has an unknown form.
function replyTexts(entry: Entry): string[] | null {
  const content = isRecord(entry.message) ? entry.message.content : undefined
  if (!Array.isArray(content)) return null
  const texts: string[] = []
  for (const block of content) {
    if (!isRecord(block) || typeof block.type !== 'string') return null
    if (!BLOCK_TYPES.includes(block.type)) return null
    if (block.type !== 'text') continue
    if (typeof block.text !== 'string') return null
    texts.push(block.text)
  }
  return texts
}

// The model of an assistant entry: requestedModel, else message.model. <synthetic> does not
// count.
function modelOf(entry: Entry): string | undefined {
  const message = isRecord(entry.message) ? entry.message.model : undefined
  for (const value of [entry.requestedModel, message]) {
    if (typeof value === 'string' && value !== '' && value !== SYNTHETIC) return value
  }
  return undefined
}

// The indexes of the lines that are the marker. Spaces around the marker are allowed.
function markerLines(lines: readonly string[], marker: string): number[] {
  return lines.flatMap((line, i) => (line.trim() === marker ? [i] : []))
}

// The result at the turn end.
function finish(text: string, model: string | undefined, request: Entry): ReplyState {
  const lines = text.split('\n')
  const starts = markerLines(lines, NOTE_START)
  const ends = markerLines(lines, NOTE_END)
  if (starts.length > 1 || ends.length > 1) return failed(REASON_TWO_MARKERS)
  if (starts.length === 0 || ends.length === 0) return failed(REASON_NO_MARKERS)
  if (starts[0] > ends[0]) return failed(REASON_ORDER)
  const note = lines
    .slice(starts[0] + 1, ends[0])
    .join('\n')
    .trim()
  if (note === '') return failed(REASON_EMPTY)
  if (model === undefined) return failed(REASON_NO_MODEL)
  const mode = request.permissionMode
  return { kind: 'done', model, note, permissionMode: typeof mode === 'string' ? mode : null }
}

// Read the reply to the request from the transcript lines after the baseline (readTail).
// The request entry is the first user entry with the request line. Bifrost reads only the
// entries after it, so a note from before the request never counts (Review Focus 2).
// A new message from the user fails at once (Review Focus 3). This also applies after the first
// turn end. When no tool runs, a message that the user types waits in the queue, and it starts a
// new turn after the turn end. The caller reads again until the session is idle, so that read
// fails.
// No request and no turn end, or a request and no turn end yet, gives pending.
export function readReply(tail: string, requestId: string): ReplyState {
  const wanted = requestLine(requestId)
  let request: Entry | null = null
  // The result at the first turn end.
  let result: ReplyState | null = null
  const texts: string[] = []
  let model: string | undefined
  for (const line of tail.split('\n')) {
    if (line.trim() === '') continue
    const entry = parseEntry(line)
    if (entry === null) return failed(REASON_LINE)
    if (request === null) {
      if (isTurnEnd(entry)) return failed(REASON_EARLY_END)
      if (entry.type === 'user' && holdsRequest(entry, wanted)) request = entry
      continue
    }
    if (isNewMessage(entry)) return failed(isInterrupt(entry) ? REASON_INTERRUPT : REASON_USER)
    // After the first turn end, only a new message counts.
    if (result !== null) continue
    if (isTurnEnd(entry)) {
      result = finish(texts.join('\n'), model, request)
      if (result.kind === 'failed') return result
    } else if (entry.type === 'assistant') {
      // A sidechain entry is the work of a subagent, not the reply.
      if (entry.isSidechain === true) continue
      const blocks = replyTexts(entry)
      if (blocks === null) return failed(REASON_REPLY)
      texts.push(...blocks)
      model = modelOf(entry) ?? model
    }
    // All other entries are metadata.
  }
  return result ?? { kind: 'pending' }
}

// Replace each token of a known form with "[secret removed]". This is a guard for the rule of
// spec 7.5. The rules also tell Claude to write no secret.
export function maskSecrets(text: string): string {
  return maskToken(text, null, '[secret removed]')
}
