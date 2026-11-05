import { afterEach, beforeEach, describe, expect, test, vi } from 'vitest'
import {
  CHAT_VIEW,
  chatView,
  type InputPty,
  REASON_AGENT_VIEW,
  REASON_CHAT_GONE,
  REASON_ENDED,
  REASON_NO_SIZE,
  REASON_NOT_READY,
  SessionInput,
  sendView,
} from '../../../src/main/actions/session-input'
import { REASON_EMPTY, RED_BOX_BLOCK } from '../../../src/shared/input'
import type { SessionRow, TermSize } from '../../../src/shared/types'

const S = 'f3a9c2d1-4b5e-4c6d-8e7f-0a1b2c3d4e5f'
const CHAT = `chat:${S}`
const SEND = `send:${S}`
const PASTE = '\x1b[200~Reply with OK\x1b[201~'
const REFUSED = 'refused: the session is not an owned session that runs'

const row = (o: Partial<SessionRow> = {}): SessionRow => ({
  box: 'none',
  boxSince: null,
  cwd: '/p',
  flashing: false,
  kind: 'owned',
  lastActivity: 1,
  name: 'bifrost-test-s',
  pid: 4242,
  sessionId: S,
  shortId: 'abcd1234',
  startedAt: 1,
  state: 'idle',
  status: 'idle',
  ...o,
})

interface Call {
  at: number
  op: 'open' | 'write' | 'close'
  view: string
  data?: string
  args?: string[]
  opts?: { cwd: string; cols: number; rows: number }
  signal?: string
}

// A fake PTY manager. It records each call with the fake time since base.
class FakePty implements InputPty {
  calls: Call[] = []
  views = new Set<string>()
  base = 0
  onOpen: (viewId: string) => void = () => {}
  has(viewId: string): boolean {
    return this.views.has(viewId)
  }
  open(viewId: string, args: string[], opts: { cwd: string; cols: number; rows: number }): number {
    this.views.add(viewId)
    this.calls.push({ args, at: Date.now() - this.base, op: 'open', opts, view: viewId })
    this.onOpen(viewId)
    return 99
  }
  write(viewId: string, data: string): boolean {
    this.calls.push({ at: Date.now() - this.base, data, op: 'write', view: viewId })
    return this.views.has(viewId)
  }
  close(viewId: string, signal?: string): void {
    this.views.delete(viewId)
    this.calls.push({ at: Date.now() - this.base, op: 'close', signal, view: viewId })
  }
  ops(): string[] {
    return this.calls.map(
      c => `${c.at} ${c.op} ${c.view}${c.data === undefined ? '' : ` ${JSON.stringify(c.data)}`}`,
    )
  }
  writes(): Call[] {
    return this.calls.filter(c => c.op === 'write')
  }
}

let pty: FakePty
let rows: SessionRow[]
let readSize: ReturnType<typeof vi.fn<(pid: number) => Promise<TermSize | null>>>
let input: SessionInput

beforeEach(() => {
  vi.useFakeTimers({ now: 0 })
  pty = new FakePty()
  rows = [row()]
  readSize = vi.fn(async () => ({ cols: 97, rows: 41 }))
  input = new SessionInput({ pty: async () => pty, readSize, rows: () => rows })
})

afterEach(() => {
  vi.useRealTimers()
})

// Record the result of a promise, so a test can check it at a fake time.
function track(p: Promise<void>): { done: boolean; error: string | undefined; at: number } {
  const t = { at: -1, done: false, error: undefined as string | undefined }
  p.then(
    () => {
      t.done = true
      t.at = Date.now() - pty.base
    },
    (e: unknown) => {
      t.done = true
      t.error = e instanceof Error ? e.message : String(e)
      t.at = Date.now() - pty.base
    },
  )
  return t
}

// Open a chat PTY for S and let its output get quiet.
async function openChat(): Promise<void> {
  pty.views.add(CHAT)
  input.opened(CHAT)
  input.data(CHAT)
  await vi.advanceTimersByTimeAsync(1500)
  pty.base = Date.now()
}

// Each hidden attach gives one chunk of output at once after its open.
function quietAttach(): void {
  pty.onOpen = view => {
    void Promise.resolve().then(() => input.data(view))
  }
}

describe('the view IDs', () => {
  test('chatView and sendView give the view IDs of a session', () => {
    expect(chatView(S)).toBe(CHAT)
    expect(sendView(S)).toBe(SEND)
    expect(CHAT_VIEW.test(CHAT)).toBe(true)
    expect(CHAT_VIEW.test(SEND)).toBe(false)
    expect(CHAT_VIEW.test('chat:abc')).toBe(false)
    expect(CHAT_VIEW.test(`${CHAT}x`)).toBe(false)
  })
})

describe('SessionInput send', () => {
  test('send writes into the open chat PTY and opens no attach', async () => {
    await openChat()
    const sent = track(input.send(S, 'Reply with OK'))
    await vi.advanceTimersByTimeAsync(1000)
    expect(sent).toEqual({ at: 300, done: true, error: undefined })
    expect(pty.ops()).toEqual([
      `0 write ${CHAT} ${JSON.stringify(PASTE)}`,
      `300 write ${CHAT} "\\r"`,
    ])
  })

  test('send without a chat window opens a hidden attach at the session size', async () => {
    quietAttach()
    const sent = track(input.send(S, 'Reply with OK'))
    await vi.advanceTimersByTimeAsync(5000)
    expect(sent.error).toBeUndefined()
    expect(readSize).toHaveBeenCalledWith(4242)
    expect(pty.calls[0]).toEqual({
      args: ['attach', 'abcd1234'],
      at: 0,
      op: 'open',
      opts: { cols: 97, cwd: '/', rows: 41 },
      view: SEND,
    })
  })

  test('the hidden attach is ready after 1.5 s of quiet output', async () => {
    const sent = track(input.send(S, 'Reply with OK'))
    await vi.advanceTimersByTimeAsync(0)
    expect(pty.ops()).toEqual([`0 open ${SEND}`])
    input.data(SEND)
    await vi.advanceTimersByTimeAsync(300)
    input.data(SEND)
    await vi.advanceTimersByTimeAsync(1499)
    expect(pty.writes()).toEqual([])
    await vi.advanceTimersByTimeAsync(2000)
    expect(sent).toEqual({ at: 3100, done: true, error: undefined })
    expect(pty.ops()).toEqual([
      `0 open ${SEND}`,
      `1800 write ${SEND} ${JSON.stringify(PASTE)}`,
      `2100 write ${SEND} "\\r"`,
      `3100 close ${SEND}`,
    ])
    expect(pty.calls[3].signal).toBe('SIGHUP')
  })

  test('send refuses when the session size is not known', async () => {
    readSize.mockResolvedValue(null)
    const sent = track(input.send(S, 'Reply with OK'))
    await vi.advanceTimersByTimeAsync(0)
    expect(sent.error).toBe(REASON_NO_SIZE)
    expect(pty.calls).toEqual([])
  })

  test('send refuses a red box before the attach', async () => {
    rows = [row({ box: 'red', state: 'needs-you' })]
    const sent = track(input.send(S, 'Reply with OK'))
    await vi.advanceTimersByTimeAsync(0)
    expect(sent.error).toBe(RED_BOX_BLOCK)
    expect(pty.calls).toEqual([])
    expect(readSize).not.toHaveBeenCalled()
  })

  test('send refuses a red box in the chat path', async () => {
    await openChat()
    rows = [row({ box: 'red', state: 'needs-you' })]
    const sent = track(input.send(S, 'Reply with OK'))
    await vi.advanceTimersByTimeAsync(0)
    expect(sent.error).toBe(RED_BOX_BLOCK)
    expect(pty.calls).toEqual([])
  })

  test('send checks the red box again before the first write', async () => {
    quietAttach()
    const sent = track(input.send(S, 'Reply with OK'))
    await vi.advanceTimersByTimeAsync(1000)
    rows = [row({ box: 'red', state: 'needs-you' })]
    await vi.advanceTimersByTimeAsync(5000)
    expect(sent).toEqual({ at: 1500, done: true, error: RED_BOX_BLOCK })
    expect(pty.writes()).toEqual([])
    expect(pty.ops()).toEqual([`0 open ${SEND}`, `1500 close ${SEND}`])
  })

  test('send does not write the CR when a red box shows after the paste', async () => {
    await openChat()
    const sent = track(input.send(S, 'Reply with OK'))
    await vi.advanceTimersByTimeAsync(100)
    rows = [row({ box: 'red', state: 'needs-you' })]
    await vi.advanceTimersByTimeAsync(1000)
    expect(sent).toEqual({ at: 300, done: true, error: RED_BOX_BLOCK })
    expect(pty.ops()).toEqual([`0 write ${CHAT} ${JSON.stringify(PASTE)}`])
  })

  test('send gives up after 15 s without quiet output and writes nothing', async () => {
    const sent = track(input.send(S, 'Reply with OK'))
    await vi.advanceTimersByTimeAsync(0)
    input.data(SEND)
    const timer = setInterval(() => input.data(SEND), 500)
    await vi.advanceTimersByTimeAsync(14_999)
    expect(sent.done).toBe(false)
    await vi.advanceTimersByTimeAsync(1)
    clearInterval(timer)
    expect(sent).toEqual({ at: 15_000, done: true, error: REASON_NOT_READY })
    expect(pty.ops()).toEqual([`0 open ${SEND}`, `15000 close ${SEND}`])
    expect(REASON_NOT_READY).toBe(
      'The session did not get ready in 15 seconds. Bifrost sent nothing.',
    )
  })

  test('send rejects when the attach ends before it is ready', async () => {
    const sent = track(input.send(S, 'Reply with OK'))
    await vi.advanceTimersByTimeAsync(0)
    input.data(SEND)
    await vi.advanceTimersByTimeAsync(500)
    pty.views.delete(SEND)
    input.ended(SEND)
    await vi.advanceTimersByTimeAsync(0)
    expect(sent).toEqual({ at: 500, done: true, error: REASON_ENDED })
    expect(pty.writes()).toEqual([])
    expect(pty.ops()).toEqual([`0 open ${SEND}`, `500 close ${SEND}`])
  })

  test('send refuses an external, parked or unknown session and a session without a short ID', async () => {
    const cases: SessionRow[][] = [
      [row({ kind: 'external' })],
      [row({ pid: undefined, state: 'parked' })],
      [row({ sessionId: 'b1b2c3d4-0000-4000-8000-000000000000' })],
      [],
      [row({ shortId: undefined })],
      [row({ shortId: '--help' })],
      [row(), row({ sessionId: 'b1b2c3d4-0000-4000-8000-000000000000' })],
    ]
    for (const c of cases) {
      rows = c
      const sent = track(input.send(S, 'Reply with OK'))
      await vi.advanceTimersByTimeAsync(0)
      expect(sent.error).toBe(REFUSED)
    }
    expect(pty.calls).toEqual([])
    expect(readSize).not.toHaveBeenCalled()
  })

  test('send refuses an external session also when a chat view of that ID is open', async () => {
    await openChat()
    rows = [row({ kind: 'external' })]
    const sent = track(input.send(S, 'Reply with OK'))
    await vi.advanceTimersByTimeAsync(0)
    expect(sent.error).toBe(REFUSED)
    expect(pty.calls).toEqual([])
  })

  test('send checks the row again before the first write', async () => {
    quietAttach()
    const sent = track(input.send(S, 'Reply with OK'))
    await vi.advanceTimersByTimeAsync(1000)
    rows = [row({ pid: undefined, state: 'parked' })]
    await vi.advanceTimersByTimeAsync(5000)
    expect(sent.error).toBe(REFUSED)
    expect(pty.writes()).toEqual([])
    expect(pty.ops()).toEqual([`0 open ${SEND}`, `1500 close ${SEND}`])
  })

  test('send refuses a row without a process ID in the hidden path', async () => {
    rows = [row({ pid: undefined })]
    const sent = track(input.send(S, 'Reply with OK'))
    await vi.advanceTimersByTimeAsync(0)
    expect(sent.error).toBe('refused: the session has no process ID yet')
    expect(pty.calls).toEqual([])
  })

  test('send refuses values that are not strings and text with no plan', async () => {
    for (const [id, text] of [
      [7, 'x'],
      [S, 7],
      [null, null],
      [{ toString: () => S }, 'x'],
    ] as const) {
      await expect(input.send(id, text)).rejects.toThrow('refused: bad input')
    }
    await expect(input.send(S, ' \x1b ')).rejects.toThrow(REASON_EMPTY)
    expect(pty.calls).toEqual([])
  })

  test('send refuses a chat window that shows the agent view', async () => {
    await openChat()
    input.setBlocked(CHAT, true)
    const blocked = track(input.send(S, 'Reply with OK'))
    await vi.advanceTimersByTimeAsync(0)
    expect(blocked.error).toBe(REASON_AGENT_VIEW)
    expect(pty.calls).toEqual([])
    input.setBlocked(CHAT, false)
    const sent = track(input.send(S, 'Reply with OK'))
    await vi.advanceTimersByTimeAsync(1000)
    expect(sent.error).toBeUndefined()
    expect(pty.writes().map(c => c.data)).toEqual([PASTE, '\r'])
    expect(REASON_AGENT_VIEW).toBe(
      'The chat window shows the agent view. Close the window and open it again.',
    )
  })

  test('setBlocked accepts only a chat view ID and a boolean', async () => {
    await openChat()
    input.setBlocked(SEND, true)
    input.setBlocked(CHAT, 'yes')
    input.setBlocked(CHAT, 1)
    input.setBlocked(7, true)
    input.setBlocked('chat:abc', true)
    const sent = track(input.send(S, 'Reply with OK'))
    await vi.advanceTimersByTimeAsync(1000)
    expect(sent.error).toBeUndefined()
  })

  test('a new open of the chat view clears the block', async () => {
    await openChat()
    input.setBlocked(CHAT, true)
    input.opened(CHAT)
    input.data(CHAT)
    await vi.advanceTimersByTimeAsync(1500)
    pty.base = Date.now()
    const sent = track(input.send(S, 'Reply with OK'))
    await vi.advanceTimersByTimeAsync(1000)
    expect(sent.error).toBeUndefined()
  })

  test('send waits until a new chat window is ready', async () => {
    pty.views.add(CHAT)
    input.opened(CHAT)
    const sent = track(input.send(S, 'Reply with OK'))
    await vi.advanceTimersByTimeAsync(200)
    input.data(CHAT)
    await vi.advanceTimersByTimeAsync(3000)
    expect(sent).toEqual({ at: 2000, done: true, error: undefined })
    expect(pty.ops()).toEqual([
      `1700 write ${CHAT} ${JSON.stringify(PASTE)}`,
      `2000 write ${CHAT} "\\r"`,
    ])
  })

  test('send rejects when the chat window closes during the send', async () => {
    await openChat()
    const sent = track(input.send(S, 'Reply with OK'))
    await vi.advanceTimersByTimeAsync(100)
    pty.views.delete(CHAT)
    await vi.advanceTimersByTimeAsync(1000)
    expect(sent.error).toBe(REASON_CHAT_GONE)
    expect(pty.calls.filter(c => c.op !== 'write')).toEqual([])
    expect(REASON_CHAT_GONE).toBe('The chat window closed during the send.')
  })

  test('send rejects when the chat attach ends during the wait', async () => {
    pty.views.add(CHAT)
    input.opened(CHAT)
    const sent = track(input.send(S, 'Reply with OK'))
    await vi.advanceTimersByTimeAsync(200)
    pty.views.delete(CHAT)
    input.ended(CHAT)
    await vi.advanceTimersByTimeAsync(0)
    expect(sent.error).toBe(REASON_CHAT_GONE)
    expect(pty.calls).toEqual([])
  })

  test('the chat path never closes the chat PTY', async () => {
    await openChat()
    for (const text of ['Reply with OK', '/compact']) {
      const sent = track(input.send(S, text))
      await vi.advanceTimersByTimeAsync(1000)
      expect(sent.error).toBeUndefined()
    }
    const failed = track(input.send(S, 'x'))
    await vi.advanceTimersByTimeAsync(100)
    rows = [row({ box: 'red' })]
    await vi.advanceTimersByTimeAsync(1000)
    expect(failed.error).toBe(RED_BOX_BLOCK)
    expect(pty.calls.filter(c => c.op !== 'write')).toEqual([])
  })

  test('two sends to one session run one after the other', async () => {
    quietAttach()
    const first = track(input.send(S, 'Reply with OK'))
    const second = track(input.send(S, 'Reply with OK'))
    let idleAt = -1
    void input.idle(S).then(() => {
      idleAt = Date.now()
    })
    await vi.advanceTimersByTimeAsync(10_000)
    expect(first).toEqual({ at: 2800, done: true, error: undefined })
    expect(second).toEqual({ at: 5600, done: true, error: undefined })
    expect(pty.ops()).toEqual([
      `0 open ${SEND}`,
      `1500 write ${SEND} ${JSON.stringify(PASTE)}`,
      `1800 write ${SEND} "\\r"`,
      `2800 close ${SEND}`,
      `2800 open ${SEND}`,
      `4300 write ${SEND} ${JSON.stringify(PASTE)}`,
      `4600 write ${SEND} "\\r"`,
      `5600 close ${SEND}`,
    ])
    expect(idleAt).toBe(5600)
  })

  test('a failed send does not stop the next send of the session', async () => {
    quietAttach()
    readSize.mockResolvedValueOnce(null)
    const first = track(input.send(S, 'Reply with OK'))
    const second = track(input.send(S, 'Reply with OK'))
    await vi.advanceTimersByTimeAsync(5000)
    expect(first.error).toBe(REASON_NO_SIZE)
    expect(second).toEqual({ at: 2800, done: true, error: undefined })
  })

  test('idle resolves at once for a session with no queue', async () => {
    let idle = false
    void input.idle(S).then(() => {
      idle = true
    })
    await vi.advanceTimersByTimeAsync(0)
    expect(idle).toBe(true)
  })
})

describe('SessionInput interrupt', () => {
  test('interrupt sends one Esc and a red box does not block it', async () => {
    await openChat()
    rows = [row({ box: 'red', state: 'needs-you' })]
    const sent = track(input.interrupt(S))
    await vi.advanceTimersByTimeAsync(0)
    expect(sent).toEqual({ at: 0, done: true, error: undefined })
    expect(pty.ops()).toEqual([`0 write ${CHAT} "\\u001b"`])
  })

  test('interrupt through a hidden attach sends one Esc and closes the attach', async () => {
    quietAttach()
    const sent = track(input.interrupt(S))
    await vi.advanceTimersByTimeAsync(5000)
    expect(sent).toEqual({ at: 2500, done: true, error: undefined })
    expect(pty.ops()).toEqual([
      `0 open ${SEND}`,
      `1500 write ${SEND} "\\u001b"`,
      `2500 close ${SEND}`,
    ])
  })

  test('interrupt refuses a session that Bifrost does not own', async () => {
    await openChat()
    rows = [row({ kind: 'external' })]
    await expect(input.interrupt(S)).rejects.toThrow(REFUSED)
    await expect(input.interrupt(42)).rejects.toThrow('refused: bad input')
    expect(pty.calls).toEqual([])
  })

  test('a second interrupt within 1.5 s has no effect', async () => {
    await openChat()
    const a = track(input.interrupt(S))
    const b = track(input.interrupt(S))
    await vi.advanceTimersByTimeAsync(0)
    expect(a.done && b.done).toBe(true)
    expect(pty.writes()).toHaveLength(1)
    await vi.advanceTimersByTimeAsync(1000)
    const c = track(input.interrupt(S))
    await vi.advanceTimersByTimeAsync(0)
    expect(c).toEqual({ at: 1000, done: true, error: undefined })
    expect(pty.writes()).toHaveLength(1)
    await vi.advanceTimersByTimeAsync(600)
    const d = track(input.interrupt(S))
    await vi.advanceTimersByTimeAsync(0)
    expect(d.error).toBeUndefined()
    expect(pty.ops()).toEqual([`0 write ${CHAT} "\\u001b"`, `1600 write ${CHAT} "\\u001b"`])
  })

  test('an interrupt that waits in the queue makes a new interrupt resolve at once', async () => {
    quietAttach()
    const sent = track(input.send(S, 'Reply with OK'))
    const a = track(input.interrupt(S))
    const b = track(input.interrupt(S))
    await vi.advanceTimersByTimeAsync(0)
    expect(a.done).toBe(false)
    expect(b).toEqual({ at: 0, done: true, error: undefined })
    await vi.advanceTimersByTimeAsync(10_000)
    expect(sent.error).toBeUndefined()
    expect(a).toEqual({ at: 5300, done: true, error: undefined })
    expect(pty.writes().map(c => c.data)).toEqual([PASTE, '\r', '\x1b'])
  })
})
