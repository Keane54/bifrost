// Tests of the dictation of one chat window: the hold, the events of the speech helper and the
// typer. A fake prompt applies the writes: one DEL removes the last grapheme. A fake API stands
// in for the main process.
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { type ChatKeyEvent, createChatInput } from '../../../src/renderer/src/chat/dictation-keys'
import { noticeText, VIM_MODE_TEXT } from '../../../src/renderer/src/chat/dictation-notice'
import {
  CLOSE_WAIT_MS,
  createDictationSession,
  type DictationView,
  KEY_WAIT_MS,
  NOTICE_MS,
} from '../../../src/renderer/src/chat/dictation-session'
import { DEL, WRITE_GAP_MS } from '../../../src/renderer/src/chat/dictation-typing'
import type { HelperEvent } from '../../../src/shared/dictation-protocol'

const VIEW = 'chat:aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'
const segmenter = new Intl.Segmenter(undefined, { granularity: 'grapheme' })
const split = (text: string): string[] => Array.from(segmenter.segment(text), s => s.segment)

const READY: HelperEvent = { fallback: false, language: 'en-US', t: 'ready' }
const text = (final: string, volatile = ''): HelperEvent => ({ final, t: 'text', volatile })
const end = (final: string): HelperEvent => ({ final, t: 'end' })

interface Options {
  vim?: boolean | 'pending'
  refuse?: string
}

function setup(opts: Options = {}) {
  let prompt = ''
  const writes: { at: number; data: string }[] = []
  let vimAnswer: ((on: boolean) => void) | null = null
  const api = {
    start: vi.fn(async (_viewId: string) => {
      if (opts.refuse !== undefined) throw new Error(opts.refuse)
    }),
    stop: vi.fn(async (_viewId: string) => {}),
    vimMode: vi.fn(
      () =>
        new Promise<boolean>(resolve => {
          if (opts.vim === 'pending') vimAnswer = resolve
          else resolve(opts.vim ?? false)
        }),
    ),
  }
  const fallback = vi.fn()
  const views: DictationView[] = []
  const session = createDictationSession({
    after(ms, fn) {
      const timer = setTimeout(fn, ms)
      return () => clearTimeout(timer)
    },
    api,
    changed: () => views.push(session.view()),
    fallback,
    lastSent: () => prompt,
    now: () => Date.now(),
    viewId: VIEW,
    write(data) {
      writes.push({ at: Date.now(), data })
      let deletes = 0
      while (data[deletes] === DEL) deletes++
      prompt = split(prompt)
        .slice(0, Math.max(0, split(prompt).length - deletes))
        .join('')
      prompt += data.slice(deletes)
    },
  })
  return {
    answerVim: (on: boolean) => vimAnswer?.(on),
    api,
    fallback,
    phase: () => session.view().phase,
    prompt: () => prompt,
    session,
    views,
    writes,
  }
}

// The input rules of the chat terminal (createChatInput) on top of the session, as in
// chat-terminal.ts. During a hold, the hold key stops the dictation at another key.
function chatOf(t: ReturnType<typeof setup>) {
  const chat = createChatInput({
    block: () => t.session.block(),
    hold: {
      handle: event => {
        if (event.type === 'keydown' && t.phase() === 'listening') t.session.cancel()
        return false
      },
    },
    input: data => t.session.input(data),
    interrupt: () => t.session.interrupt(),
    waits: () => t.session.waits(),
    warm: () => {},
  })
  // A key down that xterm.js handles. The input rules run first. Then xterm.js sends the data.
  const press = (key: string, data: string, over: Partial<ChatKeyEvent> = {}): void => {
    const event: ChatKeyEvent = {
      altKey: false,
      code: '',
      ctrlKey: false,
      isComposing: false,
      key,
      keyCode: 0,
      metaKey: false,
      preventDefault: () => {},
      repeat: false,
      shiftKey: false,
      type: 'keydown',
      ...over,
    }
    if (chat.key(event)) chat.data(data)
  }
  return { chat, press }
}

// Let the promises of the fake API settle. Each await gives one turn to the promise jobs.
async function settle(): Promise<void> {
  for (let i = 0; i < 10; i++) await Promise.resolve()
}

// A hold that the helper answers with ready and a first level: the microphone is open.
async function listen(t: ReturnType<typeof setup>): Promise<void> {
  t.session.start()
  await settle()
  t.session.event(READY)
  t.session.event({ t: 'level', v: 0.2 })
}

beforeEach(() => {
  vi.useFakeTimers()
})

afterEach(() => {
  vi.useRealTimers()
})

describe('a dictation', () => {
  it('reads the vim mode, starts, types live and types the final text at the release', async () => {
    const t = setup()
    t.session.start()
    expect(t.api.vimMode).toHaveBeenCalledTimes(1)
    expect(t.api.start).not.toHaveBeenCalled()
    await settle()
    expect(t.api.start).toHaveBeenCalledWith(VIEW)
    expect(t.phase()).toBe('starting')
    // The ready of the helper does not open the microphone. The first level shows it is open.
    t.session.event(READY)
    expect(t.phase()).toBe('starting')
    t.session.event({ t: 'level', v: 0.5 })
    expect(t.phase()).toBe('listening')
    t.session.event(text('Hello', ' wor'))
    expect(t.prompt()).toBe('Hello wor')
    t.session.stop()
    expect(t.api.stop).toHaveBeenCalledWith(VIEW)
    expect(t.phase()).toBe('stopping')
    t.session.event(end('Hello world.'))
    await vi.advanceTimersByTimeAsync(1000)
    expect(t.prompt()).toBe('Hello world.')
    expect(t.phase()).toBe('off')
    expect(t.fallback).not.toHaveBeenCalled()
  })

  it('stays off in vim mode, shows the notice and gives the key back', async () => {
    const t = setup({ vim: true })
    t.session.start()
    await settle()
    expect(t.api.start).not.toHaveBeenCalled()
    expect(t.fallback).toHaveBeenCalledTimes(1)
    expect(t.phase()).toBe('off')
    expect(t.session.view().notice).toEqual({ kind: 'vim-mode' })
    expect(noticeText(t.session.view().notice)).toBe(VIM_MODE_TEXT)
    expect(VIM_MODE_TEXT).toBe("Dictation doesn't work with Claude's vim mode yet.")
    vi.advanceTimersByTime(NOTICE_MS)
    expect(t.session.view().notice).toBeNull()
  })

  it('does not start when the key goes up before the vim mode is known', async () => {
    const t = setup({ vim: 'pending' })
    t.session.start()
    t.session.stop()
    t.answerVim(false)
    await settle()
    expect(t.api.start).not.toHaveBeenCalled()
    expect(t.api.stop).not.toHaveBeenCalled()
    expect(t.phase()).toBe('off')
  })

  it('shows the friendly text of a refused start and gives the key back', async () => {
    const t = setup({ refuse: 'refused: the chat window has no terminal' })
    t.session.start()
    await settle()
    expect(t.fallback).toHaveBeenCalledTimes(1)
    expect(t.phase()).toBe('off')
    expect(noticeText(t.session.view().notice)).toBe(
      "This chat window isn't connected to its session, so dictation can't start.",
    )
  })

  it('gives the key back for an error in place of the start, and keeps the error', async () => {
    const t = setup()
    t.session.start()
    await settle()
    t.session.event({ code: 'mic-denied', message: 'no', t: 'error' })
    expect(t.fallback).toHaveBeenCalledTimes(1)
    expect(t.phase()).toBe('off')
    expect(t.session.view().notice).toEqual({ code: 'mic-denied', kind: 'error' })
    // Later events of that dictation do nothing.
    t.session.event(text('late'))
    t.session.event(end('late'))
    expect(t.prompt()).toBe('')
  })

  it('keeps the typed text at an error during the dictation, and types nothing more', async () => {
    const t = setup()
    await listen(t)
    t.session.event(text('Hello'))
    t.session.event({ code: 'failed', message: 'stopped', t: 'error' })
    t.session.event(text('Hello there'))
    t.session.stop()
    t.session.event(end('Hello there'))
    await vi.advanceTimersByTimeAsync(1000)
    expect(t.prompt()).toBe('Hello')
    expect(t.fallback).not.toHaveBeenCalled()
  })

  it('removes the notice at the next good start: the first level after ready', async () => {
    const t = setup()
    t.session.start()
    await settle()
    t.session.event({ code: 'failed', message: 'x', t: 'error' })
    expect(t.session.view().notice).not.toBeNull()
    t.session.start()
    await settle()
    t.session.event(READY)
    expect(t.session.view().notice).not.toBeNull()
    t.session.event({ t: 'level', v: 0.1 })
    expect(t.session.view().notice).toBeNull()
  })
})

describe('an early stop', () => {
  it('stops the microphone, keeps the text and ignores the end and later events', async () => {
    const t = setup()
    await listen(t)
    t.session.event(text('Hello', ' wor'))
    t.session.cancel()
    expect(t.api.stop).toHaveBeenCalledTimes(1)
    expect(t.phase()).toBe('off')
    t.session.event(text('Hello world'))
    t.session.event(end('Hello world.'))
    await vi.advanceTimersByTimeAsync(1000)
    expect(t.prompt()).toBe('Hello wor')
  })

  it('keeps the end of a release at an interrupt before it, and the key waits (D9)', async () => {
    const t = setup()
    await listen(t)
    t.session.event(text('Hello'))
    t.session.stop()
    t.session.interrupt()
    t.session.input('!')
    t.session.event(end('Hello there.'))
    await vi.advanceTimersByTimeAsync(1000)
    expect(t.prompt()).toBe('Hello there.!')
  })

  it('stops the typer at once at a block, so a waiting part cannot answer a choice', async () => {
    const t = setup()
    await listen(t)
    t.session.stop()
    t.session.event(end('Pick 1. '.repeat(40)))
    const before = t.writes.length
    expect(before).toBe(1)
    t.session.block()
    await vi.advanceTimersByTimeAsync(1000)
    expect(t.writes).toHaveLength(before)
  })

  it('treats an end with no stop of this window as an early stop', async () => {
    const t = setup()
    await listen(t)
    t.session.event(text('Hello', ' wor'))
    // For example the 2-minute limit, or a start in another window.
    t.session.event(end('Hello world.'))
    await vi.advanceTimersByTimeAsync(1000)
    expect(t.prompt()).toBe('Hello wor')
    expect(t.phase()).toBe('off')
    // A stop closes the microphone, in case the end was late from an older dictation.
    expect(t.api.stop).toHaveBeenCalledTimes(1)
    t.session.stop()
    expect(t.api.stop).toHaveBeenCalledTimes(1)
  })

  it('stops a dictation at the close of the window', async () => {
    const t = setup()
    await listen(t)
    t.session.event(text('Hello'))
    const changes = t.views.length
    t.session.dispose()
    expect(t.api.stop).toHaveBeenCalledTimes(1)
    t.session.event(text('Hello there'))
    t.session.event(end('Hello there'))
    t.session.start()
    await vi.advanceTimersByTimeAsync(1000)
    expect(t.prompt()).toBe('Hello')
    expect(t.api.start).toHaveBeenCalledTimes(1)
    expect(t.views).toHaveLength(changes)
  })
})

describe('the keys during a final text (ruling D9)', () => {
  // A released dictation whose final text needs many writes.
  async function finishing(t: ReturnType<typeof setup>, final: string): Promise<void> {
    await listen(t)
    t.session.event(text('abcd'))
    t.session.stop()
    t.session.event(end(final))
  }
  const LONG = 'abcd '.repeat(200).trim()

  it('holds a typed letter until the final text is typed, then sends it', async () => {
    const t = setup()
    await finishing(t, LONG)
    expect(t.session.waits()).toBe(true)
    t.session.input('x')
    t.session.input('y')
    expect(t.prompt().endsWith('x')).toBe(false)
    await vi.advanceTimersByTimeAsync(1500)
    expect(t.prompt()).toBe(`${LONG}xy`)
    expect(t.session.waits()).toBe(false)
  })

  it('holds a space of a tap the same way', async () => {
    const t = setup()
    await finishing(t, LONG)
    t.session.input(' ')
    t.session.input('n')
    await vi.advanceTimersByTimeAsync(1500)
    expect(t.prompt()).toBe(`${LONG} n`)
  })

  it('holds the keys after the release until the end comes', async () => {
    const t = setup()
    await listen(t)
    t.session.event(text('Hello', ' wor'))
    t.session.stop()
    expect(t.session.waits()).toBe(true)
    t.session.input('.')
    await vi.advanceTimersByTimeAsync(500)
    t.session.event(end('Hello world'))
    await vi.advanceTimersByTimeAsync(500)
    expect(t.prompt()).toBe('Hello world.')
  })

  it('sends the keys after KEY_WAIT_MS, and stops the typer then', async () => {
    expect(KEY_WAIT_MS).toBe(2000)
    const t = setup()
    await listen(t)
    t.session.event(text('Hi'))
    t.session.stop()
    t.session.input('x')
    await vi.advanceTimersByTimeAsync(KEY_WAIT_MS - 20)
    expect(t.prompt()).toBe('Hi')
    await vi.advanceTimersByTimeAsync(20)
    expect(t.prompt()).toBe('Hix')
    // The end comes late. It types nothing now.
    t.session.event(end('Hi there'))
    await vi.advanceTimersByTimeAsync(1000)
    expect(t.prompt()).toBe('Hix')
  })

  it('types the final text first when no text came before the release (fix round 2)', async () => {
    const t = setup()
    await listen(t)
    t.session.stop()
    t.session.input('x')
    t.session.input('\r')
    t.session.event(end('yes'))
    await vi.advanceTimersByTimeAsync(500)
    expect(t.prompt()).toBe('yesx\r')
  })

  it('types the final text first when its text waited for an older typer', async () => {
    const t = setup()
    await finishing(t, LONG)
    // A new dictation. Its text waits for the older typer.
    await listen(t)
    t.session.event(text('Hi'))
    t.session.stop()
    t.session.input('x')
    t.session.input('\r')
    t.session.event(end('Hi there'))
    await vi.advanceTimersByTimeAsync(3000)
    expect(t.prompt()).toBe(`${LONG} Hi therex\r`)
  })

  it('types all of a long final that comes late, then the waiting Enter', async () => {
    const t = setup()
    await listen(t)
    t.session.event(text('abcd'))
    t.session.stop()
    t.session.input('\r')
    await vi.advanceTimersByTimeAsync(1900)
    // 2000 units: 20 writes, so the typer needs about 400 ms.
    const final = 'abcd '.repeat(400).trim()
    t.session.event(end(final))
    await vi.advanceTimersByTimeAsync(2000)
    expect(t.prompt()).toBe(`${final}\r`)
  })

  it.each([
    ['Escape', '\x1b', {}],
    ['c', '\x03', { code: 'KeyC', ctrlKey: true }],
  ] as const)(
    'stops the final at once at %s, drops the waiting keys, then sends it (D12)',
    async (key, data, over) => {
      const t = setup()
      const { press } = chatOf(t)
      await finishing(t, LONG)
      press('x', 'x')
      press('Enter', '\r')
      const before = t.prompt()
      expect(before.length).toBeLessThan(LONG.length)
      press(key, data, over)
      expect(t.prompt()).toBe(`${before}${data}`)
      await vi.advanceTimersByTimeAsync(1500)
      expect(t.prompt()).toBe(`${before}${data}`)
    },
  )

  it('drops the final and the waiting keys at Escape during a new dictation (D12)', async () => {
    const t = setup()
    const { press } = chatOf(t)
    await finishing(t, LONG)
    press('Enter', '\r')
    await listen(t)
    const before = t.prompt()
    press('Escape', '\x1b')
    expect(t.phase()).toBe('off')
    expect(t.api.stop).toHaveBeenCalledTimes(2)
    expect(t.prompt()).toBe(`${before}\x1b`)
    await vi.advanceTimersByTimeAsync(1500)
    expect(t.prompt()).toBe(`${before}\x1b`)
  })

  it('lets an older final finish at a key in a new live dictation, then the keys go', async () => {
    const t = setup()
    const { press } = chatOf(t)
    await listen(t)
    t.session.event(text('abcd'))
    t.session.stop()
    // Enter waits for the final text.
    press('Enter', '\r')
    t.session.event(end(LONG))
    // A new hold reaches listening while the older final still types.
    await listen(t)
    expect(t.phase()).toBe('listening')
    press('x', 'x')
    // Only the new dictation stops.
    expect(t.phase()).toBe('off')
    expect(t.prompt()).not.toContain('\r')
    await vi.advanceTimersByTimeAsync(1500)
    expect(t.prompt()).toBe(`${LONG}\rx`)
  })

  it('lets an older final finish at a click during a new live dictation', async () => {
    const t = setup()
    const { chat, press } = chatOf(t)
    await finishing(t, LONG)
    press('Enter', '\r')
    await listen(t)
    t.session.event(text('Next'))
    // A mouse down. Only the new dictation stops, and its text never types.
    chat.other()
    expect(t.phase()).toBe('off')
    expect(t.prompt()).not.toContain('\r')
    await vi.advanceTimersByTimeAsync(1500)
    expect(t.prompt()).toBe(`${LONG}\r`)
  })

  it('stops a live dictation at a cursor key of a mouse wheel, before the key goes', async () => {
    const t = setup()
    const { chat } = chatOf(t)
    await listen(t)
    t.session.event(text('Hello', ' wor'))
    chat.data('\x1b[A')
    expect(t.phase()).toBe('off')
    expect(t.prompt()).toBe('Hello wor\x1b[A')
    // The next text of the helper types nothing, so no DEL can remove other text.
    t.session.event(text('Hello world'))
    t.session.event(end('Hello world.'))
    await vi.advanceTimersByTimeAsync(1000)
    expect(t.prompt()).toBe('Hello wor\x1b[A')
  })

  it('stops a new hold before its good start at a click, and the older final types', async () => {
    const t = setup()
    const { chat } = chatOf(t)
    await finishing(t, LONG)
    t.session.start()
    await settle()
    expect(t.phase()).toBe('starting')
    expect(t.session.waits()).toBe(false)
    chat.other()
    expect(t.phase()).toBe('off')
    expect(t.api.stop).toHaveBeenCalledTimes(2)
    t.session.input('x')
    await vi.advanceTimersByTimeAsync(1500)
    expect(t.prompt()).toBe(`${LONG}x`)
  })

  it('does not stop the final at a click while it types, and a paste waits', async () => {
    const t = setup()
    const { chat } = chatOf(t)
    await finishing(t, LONG)
    chat.other()
    // xterm.js sends the text of the paste.
    t.session.input('pasted')
    expect(t.prompt()).not.toContain('pasted')
    await vi.advanceTimersByTimeAsync(1500)
    expect(t.prompt()).toBe(`${LONG}pasted`)
  })

  it('keeps the end of a release at a click before the end, and a drop waits', async () => {
    const t = setup()
    const { chat } = chatOf(t)
    await listen(t)
    t.session.event(text('Hello'))
    t.session.stop()
    chat.other()
    t.session.input('/tmp/a.png')
    t.session.event(end('Hello there.'))
    await vi.advanceTimersByTimeAsync(1000)
    expect(t.prompt()).toBe('Hello there./tmp/a.png')
  })

  it('drops the waiting keys at a block, for example a blocking choice', async () => {
    const t = setup()
    await finishing(t, LONG)
    t.session.input('1')
    const before = t.prompt()
    t.session.block()
    await vi.advanceTimersByTimeAsync(1500)
    expect(t.prompt()).toBe(before)
  })

  it('does not hold keys during a live dictation or with no dictation', async () => {
    const t = setup()
    expect(t.session.waits()).toBe(false)
    t.session.input('a')
    expect(t.prompt()).toBe('a')
    await listen(t)
    expect(t.session.waits()).toBe(false)
  })

  it('sends the waiting keys before the text of a new dictation', async () => {
    const t = setup()
    await finishing(t, LONG)
    t.session.input('x')
    await listen(t)
    t.session.event(text('Next'))
    await vi.advanceTimersByTimeAsync(2000)
    expect(t.prompt()).toBe(`${LONG}x Next`)
  })
})

describe('heard', () => {
  it('is false until the first level or the download, so the held key can type', async () => {
    const t = setup({ vim: 'pending' })
    expect(t.session.heard()).toBe(true)
    t.session.start()
    expect(t.session.heard()).toBe(false)
    t.answerVim(false)
    await settle()
    expect(t.phase()).toBe('starting')
    expect(t.session.heard()).toBe(false)
    // A ready alone opens no microphone. The first level does.
    t.session.event(READY)
    expect(t.session.heard()).toBe(false)
    t.session.event({ t: 'level', v: 0.1 })
    expect(t.session.heard()).toBe(true)
  })

  it('takes the path before ready for a release or an error after ready (ruling D10)', async () => {
    // The release: the hold key types the space, because heard() is false. The end types
    // nothing.
    const released = setup()
    released.session.start()
    await settle()
    released.session.event(READY)
    expect(released.session.heard()).toBe(false)
    released.session.stop()
    released.session.event(end('late words'))
    await vi.advanceTimersByTimeAsync(1000)
    expect(released.prompt()).toBe('')
    // The error: the key is given back, and the phase never was listening.
    const failed = setup()
    failed.session.start()
    await settle()
    failed.session.event(READY)
    failed.session.event({ code: 'mic-denied', message: 'no', t: 'error' })
    expect(failed.fallback).toHaveBeenCalledTimes(1)
    expect(failed.views.some(view => view.phase === 'listening')).toBe(false)
  })

  it('listens at a first text with no level before it (ruling D6a)', async () => {
    const t = setup()
    t.session.start()
    await settle()
    t.session.event(READY)
    t.session.event(text('Hi'))
    expect(t.phase()).toBe('listening')
    expect(t.session.heard()).toBe(true)
    expect(t.prompt()).toBe('Hi')
  })

  it('is true during the download and after an early stop', async () => {
    const download = setup()
    download.session.start()
    await settle()
    download.session.event({ progress: 0.2, t: 'downloading' })
    expect(download.session.heard()).toBe(true)
    // A blocking choice stopped the dictation. The release then types nothing.
    const blocked = setup()
    blocked.session.start()
    await settle()
    blocked.session.block()
    expect(blocked.session.heard()).toBe(true)
  })
})

describe('the model download', () => {
  it('shows the download for a hold during the download, never listening', async () => {
    const t = setup()
    t.session.start()
    await settle()
    t.session.event({ progress: 0, t: 'downloading' })
    t.session.event({ progress: 0.4, t: 'downloading' })
    expect(t.session.view()).toMatchObject({ phase: 'downloading', progress: 0.4 })
    t.session.stop()
    t.session.event(end('words'))
    await vi.advanceTimersByTimeAsync(1000)
    expect(t.prompt()).toBe('')
    expect(t.views.some(view => view.phase === 'listening')).toBe(false)
    // A new hold after the download opens the microphone.
    await listen(t)
    expect(t.phase()).toBe('listening')
  })

  it('listens when the helper gives ready after all (ruling D6a)', async () => {
    const t = setup()
    t.session.start()
    await settle()
    t.session.event({ progress: 0.9, t: 'downloading' })
    t.session.event(READY)
    t.session.event(text('Hi'))
    expect(t.phase()).toBe('listening')
    expect(t.prompt()).toBe('Hi')
  })
})

describe('one dictation at a time', () => {
  it('starts a new hold only after the end of the early stop', async () => {
    const t = setup()
    await listen(t)
    t.session.event(text('One'))
    t.session.cancel()
    t.session.start()
    await settle()
    expect(t.api.start).toHaveBeenCalledTimes(1)
    // The late end of the first dictation types nothing.
    t.session.event(end('One two'))
    await settle()
    expect(t.api.start).toHaveBeenCalledTimes(2)
    t.session.event(READY)
    t.session.event(text('Three'))
    await vi.advanceTimersByTimeAsync(1000)
    expect(t.prompt()).toBe('One Three')
  })

  it('starts a new hold after the end of a release, and types that end first', async () => {
    const t = setup()
    await listen(t)
    t.session.event(text('One'))
    t.session.stop()
    t.session.start()
    await settle()
    expect(t.api.start).toHaveBeenCalledTimes(1)
    t.session.event(end('One.'))
    await settle()
    expect(t.api.start).toHaveBeenCalledTimes(2)
    t.session.event(READY)
    t.session.event(text('Two'))
    await vi.advanceTimersByTimeAsync(1000)
    expect(t.prompt()).toBe('One. Two')
  })

  it('stops the wait for an end after CLOSE_WAIT_MS', async () => {
    const t = setup()
    await listen(t)
    t.session.cancel()
    t.session.start()
    await vi.advanceTimersByTimeAsync(CLOSE_WAIT_MS - 1)
    await settle()
    expect(t.api.start).toHaveBeenCalledTimes(1)
    await vi.advanceTimersByTimeAsync(1)
    await settle()
    expect(t.api.start).toHaveBeenCalledTimes(2)
  })

  it('drops a waiting start when the key goes up', async () => {
    const t = setup()
    await listen(t)
    t.session.cancel()
    t.session.start()
    t.session.stop()
    t.session.event(end(''))
    await settle()
    expect(t.api.start).toHaveBeenCalledTimes(1)
  })

  it('lets the typer of the last dictation finish before the next typer writes', async () => {
    const t = setup()
    await listen(t)
    t.session.stop()
    // 500 units: five writes, WRITE_GAP_MS apart.
    const long = 'abcd '.repeat(100).trim()
    t.session.event(end(long))
    expect(t.writes).toHaveLength(1)
    await listen(t)
    t.session.event(text('Next'))
    await vi.advanceTimersByTimeAsync(1000)
    expect(t.prompt()).toBe(`${long} Next`)
    for (let i = 1; i < t.writes.length; i++) {
      expect(t.writes[i].at - t.writes[i - 1].at).toBeGreaterThanOrEqual(WRITE_GAP_MS)
    }
  })

  it('keeps a final text that waits for an older typer when a waiting hold starts', async () => {
    const t = setup()
    const long = 'abcd '.repeat(100).trim()
    await listen(t)
    t.session.stop()
    t.session.event(end(long))
    // The typer of the first dictation still types. A second dictation hears no text.
    await listen(t)
    t.session.stop()
    // A third hold waits for the end of the second dictation.
    t.session.start()
    t.session.event(end('Hello'))
    await vi.advanceTimersByTimeAsync(1000)
    await settle()
    expect(t.api.start).toHaveBeenCalledTimes(3)
    t.session.event(READY)
    t.session.event(text('World'))
    await vi.advanceTimersByTimeAsync(1000)
    expect(t.prompt()).toBe(`${long} Hello World`)
  })

  it('drops a waiting start when the key goes up while a final text waits', async () => {
    const t = setup()
    await listen(t)
    t.session.stop()
    t.session.event(end('abcd '.repeat(100).trim()))
    await listen(t)
    t.session.stop()
    t.session.start()
    t.session.event(end('Hello'))
    t.session.stop()
    await vi.advanceTimersByTimeAsync(1000)
    await settle()
    expect(t.api.start).toHaveBeenCalledTimes(2)
    expect(t.prompt().endsWith(' Hello')).toBe(true)
  })

  it('ignores the events before a start and after the end', () => {
    const t = setup()
    t.session.event(READY)
    t.session.event(text('stray'))
    t.session.event(end('stray'))
    expect(t.prompt()).toBe('')
    expect(t.phase()).toBe('off')
  })
})
