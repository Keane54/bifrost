import { beforeEach, describe, expect, test } from 'vitest'
import { NO_STATUSLINE_SETTINGS } from '../../../src/main/actions/session-actions'
import {
  createHandOver,
  HANDOVER_POLL_MS,
  HANDOVER_TIMEOUT_MS,
  type HandOverDeps,
} from '../../../src/main/handover/hand-over'
import {
  continuePrompt,
  handOverPrompt,
  NOTE_END,
  NOTE_START,
  requestLine,
} from '../../../src/main/handover/prompt'
import { MAX_TEXT, REASON_TOO_LONG } from '../../../src/shared/input'
import type { SessionRow } from '../../../src/shared/types'

const S = 'f3a9c2d1-4b5e-4c6d-8e7f-0a1b2c3d4e5f'
const S2 = '0b1c2d3e-4f50-4a6b-8c7d-9e0f1a2b3c4d'
const ID = 'ab12cd34'
const MODEL = 'claude-opus-5-5'
const FILE = `/projects/-p/${S}.jsonl`
const NOTE_PATH = '/h/.bifrost/handovers/x-20261110-120000.md'
const RULES = 'The rules.'
// The fake clock starts here. sleep moves it.
const BASE = Date.UTC(2026, 10, 10, 12, 0, 0)

const NO_RULES = "Bifrost can't read its hand-over rules, so nothing changed."
const NO_TRANSCRIPT = "Bifrost can't find the transcript of this session, so nothing changed."
const TIMEOUT =
  "The session didn't finish the hand-over note within 5 minutes, " +
  "so Bifrost didn't start a new session."
const STOPPED = 'The session stopped before it finished the hand-over note.'
const readFailed = (reason: string): string =>
  `Bifrost couldn't read the hand-over note, so it didn't start a new session. (${reason})`
const saveFailed = (message: string): string =>
  `Bifrost couldn't save the hand-over note, so it didn't start a new session. ${message}`
const startFailed = (message: string): string =>
  `The note is saved at ${NOTE_PATH}, but the new session didn't start. ${message}`

const row = (o: Partial<SessionRow> = {}): SessionRow => ({
  box: 'none',
  boxSince: null,
  claudeName: 'x',
  cwd: '/p',
  flashing: false,
  kind: 'owned',
  lastActivity: 1,
  name: 'x',
  pid: 4242,
  sessionId: S,
  shortId: 'abcd1234',
  startedAt: 1,
  state: 'idle',
  status: 'idle',
  ...o,
})

// One transcript line.
function line(entry: unknown): string {
  return `${JSON.stringify(entry)}\n`
}

const TURN_END = line({ durationMs: 1200, subtype: 'turn_duration', type: 'system' })

// A reply with the note between the markers, and the turn end.
function noteReply(note: string): string {
  const reply = `Here is the note.\n${NOTE_START}\n${note}\n${NOTE_END}`
  return (
    line({
      message: { content: [{ text: reply, type: 'text' }], model: MODEL, role: 'assistant' },
      type: 'assistant',
    }) + TURN_END
  )
}

// A message that the user typed.
const TYPED = line({ message: { content: 'Wait, stop.', role: 'user' }, type: 'user' })

// An earlier hand-over in the same transcript, with the same request ID (Review Focus 2).
const OLD =
  line({ message: { content: handOverPrompt(RULES, ID), role: 'user' }, type: 'user' }) +
  noteReply('old note')

// Fake deps with a fake clock. Each call goes into the log with the fake time since BASE.
// The send writes the request entry to the transcript, as Claude Code does.
// An event runs when sleep moves the clock to its time or later.
class Fake {
  t = BASE
  log: string[] = []
  sent: string[] = []
  notes: string[] = []
  rows: SessionRow[] = [row()]
  text = ''
  found: string | null = FILE
  // The permission mode of the request entry. undefined gives no field.
  requestMode: string | undefined = 'plan'
  rules: () => Promise<string> = async () => RULES
  sendError: Error | null = null
  readError: Error | null = null
  noteError: Error | null = null
  startError: Error | null = null
  events: { at: number; run: () => void }[] = []

  at(ms: number, run: () => void): void {
    this.events.push({ at: BASE + ms, run })
  }

  // The session writes text to the transcript at a time.
  writes(ms: number, text: string): void {
    this.at(ms, () => {
      this.text += text
    })
  }

  // The status of the session changes at a time.
  status(ms: number, status: string): void {
    this.at(ms, () => {
      this.rows = this.rows.map(r => (r.sessionId === S ? { ...r, status } : r))
    })
  }

  private add(op: string, ...args: unknown[]): void {
    const text = args.map(a => (typeof a === 'string' ? a : JSON.stringify(a))).join(' ')
    this.log.push(`${this.t - BASE} ${op}${text === '' ? '' : ` ${text}`}`)
  }

  ops(...names: string[]): string[] {
    return this.log.filter(entry => names.length === 0 || names.includes(entry.split(' ')[1]))
  }

  start = async (args: string[], cwd: string): Promise<SessionRow> => {
    this.add('start', args, cwd)
    if (this.startError) throw this.startError
    return row({ claudeName: 'x (2)', name: 'x (2)', sessionId: S2, shortId: '4cb23c30' })
  }

  deps(): HandOverDeps {
    return {
      now: () => this.t,
      readTail: async (file, offset) => {
        this.add('readTail', file, offset)
        if (this.readError) throw this.readError
        return Buffer.from(this.text).subarray(offset).toString('utf8')
      },
      requestId: () => ID,
      rows: () => this.rows,
      rules: () => {
        this.add('rules')
        return this.rules()
      },
      send: async (id, text) => {
        this.add('send', id)
        this.sent.push(text)
        if (this.sendError) throw this.sendError
        const entry: Record<string, unknown> = { message: { content: text, role: 'user' } }
        if (this.requestMode !== undefined) entry.permissionMode = this.requestMode
        this.text += line({ ...entry, type: 'user' })
      },
      size: async file => {
        this.add('size', file)
        return Buffer.byteLength(this.text)
      },
      sleep: async ms => {
        this.t += ms
        for (const event of this.events.filter(e => e.at <= this.t)) {
          this.events.splice(this.events.indexOf(event), 1)
          event.run()
        }
      },
      transcript: async r => {
        this.add('transcript', r.sessionId)
        return this.found
      },
      writeNote: async (name, note, at) => {
        this.add('writeNote', name, at.getTime() - BASE)
        if (this.noteError) throw this.noteError
        this.notes.push(note)
        return NOTE_PATH
      },
    }
  }

  run(): Promise<unknown> {
    return createHandOver(this.deps())(this.rows[0], this.start)
  }
}

// The message of a rejection.
async function failure(p: Promise<unknown>): Promise<string> {
  return p.then(
    () => 'resolved',
    (error: Error) => error.message,
  )
}

let f: Fake

beforeEach(() => {
  f = new Fake()
})

// The good timeline: the session gets busy, ends the turn with the note, then gets idle.
function goodTimeline(note = '# Hand-over: fix login\n\n## Goal and scope\nfix the login'): void {
  f.status(1000, 'busy')
  f.writes(3000, noteReply(note))
  f.status(4000, 'idle')
}

describe('the hand-over run: the good path', () => {
  test('the limits are 5 minutes and 1 second', () => {
    expect(HANDOVER_TIMEOUT_MS).toBe(300_000)
    expect(HANDOVER_POLL_MS).toBe(1000)
  })

  test('one send, a wait for the turn end and idle, the note, and the new session', async () => {
    const note = '# Hand-over: fix login\n\n## Goal and scope\nfix the login'
    goodTimeline(note)
    await expect(f.run()).resolves.toEqual({ name: 'x (2)', notePath: NOTE_PATH, sessionId: S2 })
    expect(f.sent).toEqual([handOverPrompt(RULES, ID)])
    expect(f.sent[0].startsWith(`${requestLine(ID)}\n`)).toBe(true)
    // The turn ends at 3000, but the session is idle only at 4000.
    expect(f.ops('rules', 'transcript', 'size', 'send', 'writeNote', 'start')).toEqual([
      '0 rules',
      `0 transcript ${S}`,
      `0 size ${FILE}`,
      `0 send ${S}`,
      '4000 writeNote x 4000',
      `4000 start ${JSON.stringify([
        '--bg',
        '--settings',
        NO_STATUSLINE_SETTINGS,
        '--model',
        MODEL,
        '--permission-mode',
        'plan',
        '--name',
        'x (2)',
        continuePrompt(note, NOTE_PATH),
      ])} /p`,
    ])
    expect(f.notes).toEqual([note])
    // One read for each poll, each from the baseline.
    expect(f.ops('readTail')).toEqual(
      [1000, 2000, 3000, 4000].map(ms => `${ms} readTail ${FILE} 0`),
    )
  })

  test('the prompt of the new session holds the note and its path', async () => {
    goodTimeline('the note text')
    await f.run()
    const args = JSON.parse(f.ops('start')[0].split(' ').slice(2, -1).join(' ')) as string[]
    const prompt = args.at(-1) as string
    expect(prompt).toContain('the note text')
    expect(prompt).toContain(NOTE_PATH)
  })

  test('idle before the turn end does not end the wait', async () => {
    // The status stays idle while the session works, and the note comes at 5000.
    f.writes(5000, noteReply('n'))
    await f.run()
    expect(f.ops('writeNote')).toEqual(['5000 writeNote x 5000'])
  })

  test('the note file gets the note with each secret masked and no NUL character', async () => {
    const token = `ghp_${'a'.repeat(36)}`
    goodTimeline(`token ${token} end\nnul\u0000here`)
    await f.run()
    expect(f.notes).toEqual(['token [secret removed] end\nnulhere'])
    expect(f.ops('start')[0]).not.toContain(token)
    expect(f.ops('start')[0]).not.toContain('\\u0000')
  })

  test('a NUL character inside a token does not keep the token', async () => {
    goodTimeline(`token ghp_${'a'.repeat(18)}\u0000${'a'.repeat(18)} end`)
    await f.run()
    expect(f.notes).toEqual(['token [secret removed] end'])
  })

  test('the new name skips each name and Claude name of all rows', async () => {
    f.rows = [
      row(),
      row({ claudeName: 'x (2)', name: 'mine', sessionId: S2 }),
      row({ claudeName: 'other', name: 'x (3)', sessionId: 'c' }),
    ]
    goodTimeline()
    await expect(f.run()).resolves.toEqual(expect.objectContaining({ name: 'x (4)' }))
    expect(f.ops('start')[0]).toContain('"--name","x (4)"')
  })

  test('the mode of the row counts when the request entry has no mode, else no flag', async () => {
    f.requestMode = undefined
    f.rows = [row({ permissionMode: 'acceptEdits' })]
    goodTimeline()
    await f.run()
    expect(f.ops('start')[0]).toContain('"--permission-mode","acceptEdits"')

    f = new Fake()
    f.requestMode = undefined
    goodTimeline()
    await f.run()
    expect(f.ops('start')[0]).not.toContain('--permission-mode')
  })
})

describe('the hand-over run: each failure', () => {
  // No note file and no new session.
  const nothingDone = (): void => {
    expect(f.ops('writeNote', 'start')).toEqual([])
  }

  test('no rules: no send', async () => {
    f.rules = async () => {
      throw new Error('ENOENT')
    }
    expect(await failure(f.run())).toBe(NO_RULES)
    // An empty rules file is no rules.
    f.rules = async () => ' \n'
    expect(await failure(f.run())).toBe(NO_RULES)
    expect(f.ops('transcript', 'send')).toEqual([])
    nothingDone()
  })

  test('no transcript: no send', async () => {
    f.found = null
    expect(await failure(f.run())).toBe(NO_TRANSCRIPT)
    expect(f.ops('size', 'send')).toEqual([])
    nothingDone()
  })

  test('a transcript that Bifrost cannot read: no send', async () => {
    const deps = f.deps()
    const run = createHandOver({
      ...deps,
      size: async () => {
        throw new Error('EACCES')
      },
    })
    expect(await failure(run(row(), f.start))).toBe(NO_TRANSCRIPT)
    const failing = createHandOver({
      ...deps,
      transcript: async () => {
        throw new Error('EIO')
      },
    })
    expect(await failure(failing(row(), f.start))).toBe(NO_TRANSCRIPT)
    expect(f.ops('send')).toEqual([])
    nothingDone()
  })

  test('a rejected send stops with its message', async () => {
    f.sendError = new Error('Answer the prompt in the chat window first.')
    expect(await failure(f.run())).toBe('Answer the prompt in the chat window first.')
    expect(f.ops('readTail')).toEqual([])
    nothingDone()
  })

  test('a row that parks or goes during the wait', async () => {
    f.status(1000, 'busy')
    f.at(2000, () => {
      f.rows = [row({ pid: undefined, state: 'parked', status: '' })]
    })
    // A note that is ready at the same poll does not count.
    f.writes(2000, noteReply('n'))
    expect(await failure(f.run())).toBe(STOPPED)
    expect(f.t - BASE).toBe(2000)
    nothingDone()

    f = new Fake()
    f.at(1000, () => {
      f.rows = []
    })
    expect(await failure(f.run())).toBe(STOPPED)
    nothingDone()
  })

  test('a failed reply stops at once', async () => {
    f.status(1000, 'busy')
    f.writes(
      2000,
      line({
        message: { content: [{ text: 'No note.', type: 'text' }], model: MODEL },
        type: 'assistant',
      }) + TURN_END,
    )
    expect(await failure(f.run())).toBe(readFailed("the reply doesn't have both note markers"))
    expect(f.t - BASE).toBe(2000)
    nothingDone()
  })

  test('a failed read of the transcript stops at once', async () => {
    f.readError = new Error('The transcript got shorter while Bifrost read it.')
    expect(await failure(f.run())).toBe(
      readFailed('The transcript got shorter while Bifrost read it.'),
    )
    expect(f.t - BASE).toBe(1000)
    nothingDone()
  })

  test('the timeout comes after exactly 5 minutes of fake time', async () => {
    // The session ends its turn but never gets idle.
    f.status(1000, 'busy')
    f.writes(3000, noteReply('n'))
    expect(await failure(f.run())).toBe(TIMEOUT)
    expect(f.t - BASE).toBe(HANDOVER_TIMEOUT_MS)
    expect(f.ops('readTail')).toHaveLength(HANDOVER_TIMEOUT_MS / HANDOVER_POLL_MS)
    nothingDone()
  })

  test('a note at the last poll before the timeout still counts', async () => {
    f.status(1000, 'busy')
    f.writes(HANDOVER_TIMEOUT_MS, noteReply('n'))
    f.status(HANDOVER_TIMEOUT_MS, 'idle')
    await expect(f.run()).resolves.toEqual(expect.objectContaining({ sessionId: S2 }))
  })

  test('a failed save starts no session', async () => {
    goodTimeline()
    f.noteError = new Error('Too many hand-over notes have this name.')
    expect(await failure(f.run())).toBe(saveFailed('Too many hand-over notes have this name.'))
    expect(f.ops('start')).toEqual([])
  })

  test('a failed start keeps the note and names its path', async () => {
    goodTimeline()
    f.startError = new Error('Claude Code reported a problem: boom')
    expect(await failure(f.run())).toBe(startFailed('Claude Code reported a problem: boom'))
    expect(f.notes).toHaveLength(1)
    expect(f.ops('start')).toHaveLength(1)
  })

  test('a note that is too long for the prompt is saved, and no session starts', async () => {
    const long = 'n'.repeat(MAX_TEXT)
    goodTimeline(long)
    expect(await failure(f.run())).toBe(startFailed(REASON_TOO_LONG))
    expect(f.notes).toEqual([long])
    expect(f.ops('start')).toEqual([])
  })
})

describe('the hand-over run: the review focus', () => {
  test('an older note before the baseline is not used (Review Focus 2)', async () => {
    f.text = OLD
    goodTimeline('new note')
    await f.run()
    expect(f.notes).toEqual(['new note'])
    const baseline = Buffer.byteLength(OLD)
    expect(f.ops('size', 'readTail')[1]).toBe(`1000 readTail ${FILE} ${baseline}`)
    expect(f.ops('writeNote')).toEqual(['4000 writeNote x 4000'])
  })

  test('a message that the user types during the wait fails (Review Focus 3)', async () => {
    f.status(1000, 'busy')
    f.writes(2000, TYPED)
    f.writes(3000, noteReply('n'))
    f.status(4000, 'idle')
    const reason = readFailed('a new message came in during the hand-over')
    expect(await failure(f.run())).toBe(reason)
    expect(f.t - BASE).toBe(2000)
    expect(f.ops('writeNote', 'start')).toEqual([])
  })

  test('a message after the first turn end, before idle, also fails (Review Focus 3)', async () => {
    f.status(1000, 'busy')
    f.writes(3000, noteReply('n'))
    // The queued message starts a new turn after the turn end.
    f.writes(4000, TYPED)
    f.status(5000, 'idle')
    const reason = readFailed('a new message came in during the hand-over')
    expect(await failure(f.run())).toBe(reason)
    expect(f.t - BASE).toBe(4000)
    expect(f.ops('writeNote', 'start')).toEqual([])
  })
})
