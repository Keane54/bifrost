// Tests of the dictation service. A fake spawn gives fake helpers that print the lines of each
// test. No test runs the real helper or opens the microphone. Fake timers give the time.
import type { ChildProcess } from 'node:child_process'
import { EventEmitter } from 'node:events'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import {
  createDictationService,
  END_LIMIT_MS,
  HOLD_LIMIT_MS,
  IDLE_MS,
  MAX_BAD_LINES,
  READY_LIMIT_MS,
  STOP_WAIT_MS,
} from '../../../src/main/dictation/dictation-service'
import { type DictationViewEvent, MAX_HELPER_LINE } from '../../../src/shared/dictation-protocol'

const A = 'chat:aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'
const B = 'chat:bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb'
const READY = { fallback: false, language: 'en-US', t: 'ready' } as const
const FAILED = expect.objectContaining({ code: 'failed', t: 'error' })
const MODEL_READY = { t: 'model-ready' } as const

type FakeChild = EventEmitter & {
  // The commands on stdin, one for each line.
  commands: string[]
  // True after the end of stdin.
  ended: boolean
  kill: ReturnType<typeof vi.fn>
  stdin: EventEmitter & { end(): void; write(data: string): boolean }
  stdout: EventEmitter & { setEncoding(encoding: string): unknown }
}

// A fake helper. Its stdout gives each chunk at once, so a test needs no wait.
function fakeChild(): FakeChild {
  const child = new EventEmitter() as FakeChild
  child.commands = []
  child.ended = false
  child.stdin = Object.assign(new EventEmitter(), {
    end: () => {
      child.ended = true
    },
    write: (data: string) => {
      child.commands.push(...data.split('\n').filter(line => line !== ''))
      return true
    },
  })
  child.stdout = Object.assign(new EventEmitter(), { setEncoding: () => child.stdout })
  child.kill = vi.fn(() => true)
  return child
}

function setup(path: string | null = '/app/bifrost-dictation') {
  const children: FakeChild[] = []
  const spawn = vi.fn((_path: string) => {
    const made = fakeChild()
    children.push(made)
    return made as unknown as ChildProcess
  })
  const got: Array<[string, DictationViewEvent]> = []
  const service = createDictationService({
    clearTimeout: timer => clearTimeout(timer),
    now: () => Date.now(),
    path: () => path,
    send: (viewId, event) => {
      got.push([viewId, event])
    },
    setTimeout: (fn, ms) => setTimeout(fn, ms),
    spawn,
  })
  // The newest helper.
  const child = (): FakeChild => {
    const last = children.at(-1)
    if (last === undefined) throw new Error('no helper started')
    return last
  }
  // The events that one view got, in order.
  const of = (viewId: string): DictationViewEvent[] =>
    got.filter(([view]) => view === viewId).map(([, event]) => event)
  return { child, children, of, service, spawn }
}

// Give one line of the helper: an object as JSON, or a raw text.
function say(child: FakeChild, line: object | string): void {
  child.stdout.emit('data', `${typeof line === 'string' ? line : JSON.stringify(line)}\n`)
}

// A warm helper that is ready.
function readySetup() {
  const t = setup()
  t.service.warm()
  say(t.child(), READY)
  return t
}

beforeEach(() => {
  vi.useFakeTimers()
})

afterEach(() => {
  vi.useRealTimers()
})

describe('the warm helper', () => {
  it('starts one time for two warm calls, and gets no command', () => {
    const t = setup()
    t.service.warm()
    t.service.warm()
    expect(t.spawn).toHaveBeenCalledTimes(1)
    expect(t.spawn).toHaveBeenCalledWith('/app/bifrost-dictation')
    expect(t.child().commands).toEqual([])
  })

  it('stops when 5 minutes pass with no warm call, and the next warm starts it again', () => {
    const t = readySetup()
    const first = t.child()
    vi.advanceTimersByTime(IDLE_MS - 1_000)
    t.service.warm()
    vi.advanceTimersByTime(IDLE_MS - 1_000)
    expect(first.kill).not.toHaveBeenCalled()
    vi.advanceTimersByTime(1_000)
    expect(first.kill).toHaveBeenCalled()
    expect(first.ended).toBe(true)
    t.service.warm()
    expect(t.spawn).toHaveBeenCalledTimes(2)
  })

  it('never stops for the idle rule while it downloads the model', () => {
    const t = setup()
    t.service.warm()
    const helper = t.child()
    say(helper, { progress: 0, t: 'downloading' })
    // Six minutes of download, with a progress line every 9 seconds.
    for (let i = 1; i <= 40; i++) {
      vi.advanceTimersByTime(9_000)
      say(helper, { progress: i / 40, t: 'downloading' })
    }
    expect(helper.kill).not.toHaveBeenCalled()
    say(helper, READY)
    vi.advanceTimersByTime(IDLE_MS)
    expect(helper.kill).toHaveBeenCalled()
  })

  it('does not start with no helper path, and a start then gives no-helper at once', () => {
    const t = setup(null)
    t.service.warm()
    expect(t.spawn).not.toHaveBeenCalled()
    t.service.start(A)
    // For example a dev run with no helper build. A new hold cannot help, so the code is its own.
    expect(t.of(A)).toEqual([
      { code: 'no-helper', message: "Bifrost can't find its speech helper.", t: 'error' },
    ])
  })
})

describe('the events of a dictation', () => {
  it('go to the view that started only, and stop gives the end', () => {
    const t = readySetup()
    t.service.start(A)
    t.service.start(A)
    expect(t.child().commands).toEqual(['start'])
    say(t.child(), { t: 'level', v: 0.5 })
    say(t.child(), { final: '', t: 'text', volatile: 'hello' })
    t.service.stop(A)
    expect(t.child().commands).toEqual(['start', 'stop'])
    // The microphone is closed. A level or text line before the end goes to no view.
    say(t.child(), { t: 'level', v: 0.2 })
    say(t.child(), { final: 'Hello.', t: 'text', volatile: '' })
    say(t.child(), { final: 'Hello.', t: 'end' })
    expect(t.of(A)).toEqual([
      READY,
      { t: 'level', v: 0.5 },
      { final: '', t: 'text', volatile: 'hello' },
      { final: 'Hello.', t: 'end' },
    ])
    expect(t.of(B)).toEqual([])
  })

  it('give the ready event when the helper gets ready during the hold', () => {
    const t = setup()
    t.service.start(A)
    expect(t.child().commands).toEqual(['start'])
    say(t.child(), READY)
    say(t.child(), { t: 'level', v: 0.1 })
    expect(t.of(A)).toEqual([READY, { t: 'level', v: 0.1 }])
  })

  it('do not go to a view after its stop ends', () => {
    const t = readySetup()
    t.service.start(A)
    t.service.stop(A)
    say(t.child(), { final: '', t: 'end' })
    say(t.child(), { t: 'level', v: 0.5 })
    say(t.child(), { final: 'late', t: 'text', volatile: '' })
    say(t.child(), { code: 'failed', message: 'Speech recognition stopped.', t: 'error' })
    t.child().emit('exit', 1, null)
    vi.advanceTimersByTime(HOLD_LIMIT_MS + END_LIMIT_MS)
    expect(t.of(A)).toEqual([READY, { final: '', t: 'end' }])
  })

  it('do nothing for a stop of a view that does not dictate', () => {
    const t = readySetup()
    t.service.start(A)
    t.service.stop(B)
    expect(t.child().commands).toEqual(['start'])
    expect(t.of(B)).toEqual([])
  })

  it('stop the first view when another view starts', () => {
    const t = readySetup()
    t.service.start(A)
    say(t.child(), { final: '', t: 'text', volatile: 'one' })
    t.service.start(B)
    expect(t.child().commands).toEqual(['start', 'stop', 'start'])
    // The helper gives the rest of the first session, then its end, then the second session.
    say(t.child(), { t: 'level', v: 0.4 })
    say(t.child(), { final: 'One.', t: 'end' })
    say(t.child(), { final: '', t: 'text', volatile: 'two' })
    expect(t.of(A)).toEqual([
      READY,
      { final: '', t: 'text', volatile: 'one' },
      { final: 'One.', t: 'end' },
    ])
    expect(t.of(B)).toEqual([READY, { final: '', t: 'text', volatile: 'two' }])
  })

  it('drop the old end when the same view starts again while its stop waits', () => {
    const t = readySetup()
    t.service.start(A)
    say(t.child(), { final: '', t: 'text', volatile: 'one' })
    t.service.stop(A)
    t.service.start(A)
    expect(t.child().commands).toEqual(['start', 'stop', 'start'])
    say(t.child(), { final: 'One.', t: 'end' })
    say(t.child(), { final: '', t: 'text', volatile: 'two' })
    vi.advanceTimersByTime(STOP_WAIT_MS)
    expect(t.of(A)).toEqual([
      READY,
      { final: '', t: 'text', volatile: 'one' },
      READY,
      { final: '', t: 'text', volatile: 'two' },
    ])
  })

  it('give the text so far as the end when the end does not come in 2 s', () => {
    // The helper gives its end in about 1.5 s. The wait of the service is longer.
    expect(STOP_WAIT_MS).toBe(2_000)
    const t = readySetup()
    t.service.start(A)
    say(t.child(), { final: 'Hi', t: 'text', volatile: ' there' })
    t.service.stop(A)
    vi.advanceTimersByTime(STOP_WAIT_MS - 1)
    expect(t.of(A).at(-1)?.t).toBe('text')
    vi.advanceTimersByTime(1)
    expect(t.of(A).at(-1)).toEqual({ final: 'Hi there', t: 'end' })
    // The late end of the helper goes to no view.
    say(t.child(), { final: 'Hi there.', t: 'end' })
    expect(t.of(A).filter(event => event.t === 'end')).toHaveLength(1)
  })

  it('read a line that comes in two chunks, and two lines in one chunk', () => {
    const t = readySetup()
    t.service.start(A)
    const line = JSON.stringify({ t: 'level', v: 0.25 })
    t.child().stdout.emit('data', line.slice(0, 7))
    expect(t.of(A)).toEqual([READY])
    t.child().stdout.emit('data', `${line.slice(7)}\n`)
    const level = JSON.stringify({ t: 'level', v: 0.5 })
    const text = JSON.stringify({ final: '', t: 'text', volatile: 'hi' })
    t.child().stdout.emit('data', `${level}\n${text}\n`)
    expect(t.of(A)).toEqual([
      READY,
      { t: 'level', v: 0.25 },
      { t: 'level', v: 0.5 },
      { final: '', t: 'text', volatile: 'hi' },
    ])
  })

  it('give model-ready, not ready, to a start that got a downloading line', () => {
    const t = setup()
    t.service.start(A)
    // The helper downloads the model, so the start opens no session and no microphone.
    say(t.child(), { progress: 0, t: 'downloading' })
    say(t.child(), { progress: 0.5, t: 'downloading' })
    say(t.child(), READY)
    // The service never starts the session again by itself.
    expect(t.child().commands).toEqual(['start'])
    t.service.stop(A)
    say(t.child(), { final: '', t: 'end' })
    expect(t.of(A)).toEqual([
      { progress: 0, t: 'downloading' },
      { progress: 0.5, t: 'downloading' },
      MODEL_READY,
      { final: '', t: 'end' },
    ])
    // A new hold after ready opens the microphone.
    t.service.start(A)
    expect(t.child().commands).toEqual(['start', 'stop', 'start'])
    say(t.child(), { t: 'level', v: 0.3 })
    expect(t.of(A).slice(4)).toEqual([READY, { t: 'level', v: 0.3 }])
  })

  it('give model-ready only to the view that dictates', () => {
    const t = setup()
    t.service.start(A)
    say(t.child(), { progress: 0.2, t: 'downloading' })
    // A stopped turn waits for its end. It gets no model-ready.
    t.service.stop(A)
    t.service.start(B)
    say(t.child(), { final: '', t: 'end' })
    say(t.child(), { progress: 0.3, t: 'downloading' })
    say(t.child(), READY)
    expect(t.of(A)).toEqual([
      { progress: 0.2, t: 'downloading' },
      { final: '', t: 'end' },
    ])
    expect(t.of(B)).toEqual([{ progress: 0.3, t: 'downloading' }, MODEL_READY])
  })

  it('give ready before the first level when the session opens after the download', () => {
    const t = setup()
    t.service.start(A)
    say(t.child(), { progress: 0.9, t: 'downloading' })
    say(t.child(), READY)
    // The download ended just before the helper did the start, so the helper opened a session.
    say(t.child(), { t: 'level', v: 0.4 })
    say(t.child(), { final: '', t: 'text', volatile: 'hi' })
    expect(t.child().commands).toEqual(['start'])
    t.service.stop(A)
    say(t.child(), { final: 'Hi.', t: 'end' })
    expect(t.of(A)).toEqual([
      { progress: 0.9, t: 'downloading' },
      MODEL_READY,
      READY,
      { t: 'level', v: 0.4 },
      { final: '', t: 'text', volatile: 'hi' },
      { final: 'Hi.', t: 'end' },
    ])
  })

  it('never give ready to a start during a download that runs already', () => {
    const t = setup()
    t.service.warm()
    say(t.child(), { progress: 0.2, t: 'downloading' })
    t.service.start(A)
    say(t.child(), { progress: 0.2, t: 'downloading' })
    say(t.child(), READY)
    expect(t.of(A)).toEqual([{ progress: 0.2, t: 'downloading' }, MODEL_READY])
    expect(t.child().commands).toEqual(['start'])
  })

  it('stop after 2 minutes, and the view gets the end', () => {
    const t = readySetup()
    t.service.start(A)
    vi.advanceTimersByTime(HOLD_LIMIT_MS - 1)
    expect(t.child().commands).toEqual(['start'])
    vi.advanceTimersByTime(1)
    expect(t.child().commands).toEqual(['start', 'stop'])
    say(t.child(), { final: 'A long text.', t: 'end' })
    expect(t.of(A).at(-1)).toEqual({ final: 'A long text.', t: 'end' })
    t.service.stop(A)
    expect(t.child().commands).toEqual(['start', 'stop'])
  })
})

describe('the errors of the helper', () => {
  it.each(['mic-asked', 'mic-denied', 'speech-asked', 'speech-denied', 'failed'] as const)(
    'give %s to the view, and the service stops the session of the helper',
    code => {
      const t = readySetup()
      t.service.start(A)
      const error = { code, message: 'The message.', t: 'error' } as const
      say(t.child(), error)
      expect(t.of(A)).toEqual([READY, error])
      // The helper can keep the session after an error. The stop clears it.
      expect(t.child().commands).toEqual(['start', 'stop'])
      say(t.child(), { final: '', t: 'end' })
      say(t.child(), { t: 'level', v: 0.3 })
      t.service.stop(A)
      expect(t.child().commands).toEqual(['start', 'stop'])
      expect(t.of(A)).toEqual([READY, error])
      // The helper stays.
      expect(t.child().kill).not.toHaveBeenCalled()
    },
  )

  it('end the helper for an error in place of ready, and only a start starts a new one', () => {
    const t = setup()
    t.service.start(A)
    const error = { code: 'no-model', message: 'No model.', t: 'error' } as const
    say(t.child(), error)
    expect(t.of(A)).toEqual([error])
    expect(t.child().kill).toHaveBeenCalled()
    t.service.warm()
    expect(t.spawn).toHaveBeenCalledTimes(1)
    t.service.start(A)
    expect(t.spawn).toHaveBeenCalledTimes(2)
    expect(t.child().commands).toEqual(['start'])
  })

  it('give failed when no ready comes in 10 s, and the next warm starts a new helper', () => {
    const t = setup()
    t.service.start(A)
    const first = t.child()
    vi.advanceTimersByTime(READY_LIMIT_MS - 1)
    expect(t.of(A)).toEqual([])
    vi.advanceTimersByTime(1)
    expect(t.of(A)).toEqual([FAILED])
    expect(first.kill).toHaveBeenCalled()
    say(first, READY)
    expect(t.of(A)).toEqual([FAILED])
    t.service.warm()
    expect(t.spawn).toHaveBeenCalledTimes(2)
  })

  it('count a downloading line in place of ready, and each one starts the 10 s again', () => {
    const t = setup()
    t.service.start(A)
    vi.advanceTimersByTime(READY_LIMIT_MS - 1)
    say(t.child(), { progress: 0, t: 'downloading' })
    vi.advanceTimersByTime(READY_LIMIT_MS - 1)
    say(t.child(), { progress: 0.5, t: 'downloading' })
    vi.advanceTimersByTime(READY_LIMIT_MS - 1)
    expect(t.of(A)).toEqual([
      { progress: 0, t: 'downloading' },
      { progress: 0.5, t: 'downloading' },
    ])
    vi.advanceTimersByTime(1)
    expect(t.of(A).at(-1)).toEqual(FAILED)
  })

  it('give failed for a crash, and the next warm starts a new helper', () => {
    const t = readySetup()
    t.service.start(A)
    say(t.child(), { t: 'level', v: 0.2 })
    t.child().emit('exit', null, 'SIGSEGV')
    expect(t.of(A)).toEqual([READY, { t: 'level', v: 0.2 }, FAILED])
    t.service.warm()
    expect(t.spawn).toHaveBeenCalledTimes(2)
  })

  it('give failed when the helper cannot start', () => {
    const t = setup()
    t.service.start(A)
    t.child().emit('error', new Error('spawn ENOENT'))
    expect(t.of(A)).toEqual([FAILED])
    t.service.warm()
    expect(t.spawn).toHaveBeenCalledTimes(2)
  })

  it('give the text so far to a view that waits for its end at a crash', () => {
    const t = readySetup()
    t.service.start(A)
    say(t.child(), { final: 'Hi', t: 'text', volatile: ' you' })
    t.service.stop(A)
    t.child().emit('exit', 1, null)
    expect(t.of(A).at(-1)).toEqual({ final: 'Hi you', t: 'end' })
    // The failed helper leaves no timer.
    expect(vi.getTimerCount()).toBe(0)
    vi.advanceTimersByTime(END_LIMIT_MS)
    expect(t.of(A).filter(event => event.t === 'end')).toHaveLength(1)
  })

  it(`give failed after ${MAX_BAD_LINES} bad lines`, () => {
    const t = readySetup()
    t.service.start(A)
    for (let i = 0; i < MAX_BAD_LINES; i++) say(t.child(), 'not json')
    expect(t.of(A)).toEqual([READY])
    // A level outside 0 to 1 is a bad line too.
    say(t.child(), { t: 'level', v: 2 })
    expect(t.of(A)).toEqual([READY, FAILED])
    expect(t.child().kill).toHaveBeenCalled()
  })

  it('count a line over the limit as one bad line, and read the next line', () => {
    const t = readySetup()
    t.service.start(A)
    const half = 'x'.repeat(MAX_HELPER_LINE)
    t.child().stdout.emit('data', half)
    t.child().stdout.emit('data', half)
    t.child().stdout.emit('data', `${half}\n`)
    say(t.child(), { t: 'level', v: 0.7 })
    expect(t.of(A)).toEqual([READY, { t: 'level', v: 0.7 }])
    for (let i = 1; i < MAX_BAD_LINES; i++) say(t.child(), '{}')
    expect(t.of(A)).toHaveLength(2)
    say(t.child(), '{}')
    expect(t.of(A).at(-1)).toEqual(FAILED)
  })

  it('give a permission error that comes after a quick release in place of the end', () => {
    const t = readySetup()
    t.service.start(A)
    t.service.stop(A)
    const error = { code: 'mic-asked', message: 'macOS asks.', t: 'error' } as const
    say(t.child(), error)
    say(t.child(), { final: '', t: 'end' })
    vi.advanceTimersByTime(END_LIMIT_MS)
    expect(t.of(A)).toEqual([READY, error])
    expect(t.child().commands).toEqual(['start', 'stop'])
    expect(t.child().kill).not.toHaveBeenCalled()
  })

  it('drop an error that comes after the stop wait gave the end', () => {
    const t = readySetup()
    t.service.start(A)
    t.service.stop(A)
    vi.advanceTimersByTime(STOP_WAIT_MS)
    say(t.child(), { code: 'failed', message: 'Stopped.', t: 'error' })
    expect(t.of(A)).toEqual([READY, { final: '', t: 'end' }])
  })

  it('arm the end limit of a stop before ready only after ready', () => {
    const t = setup()
    t.service.start(A)
    t.service.stop(A)
    // A slow boot: the helper does the stop after ready. Only the ready limit runs now.
    vi.advanceTimersByTime(READY_LIMIT_MS - 1)
    expect(t.child().kill).not.toHaveBeenCalled()
    expect(t.of(A)).toEqual([{ final: '', t: 'end' }])
    say(t.child(), READY)
    vi.advanceTimersByTime(END_LIMIT_MS - 1)
    expect(t.child().kill).not.toHaveBeenCalled()
    vi.advanceTimersByTime(1)
    expect(t.child().kill).toHaveBeenCalled()
  })

  it('end the helper when an end does not come in 5 s after a stop', () => {
    const t = readySetup()
    t.service.start(A)
    t.service.stop(A)
    vi.advanceTimersByTime(END_LIMIT_MS - 1)
    expect(t.of(A).at(-1)).toEqual({ final: '', t: 'end' })
    expect(t.child().kill).not.toHaveBeenCalled()
    vi.advanceTimersByTime(1)
    expect(t.child().kill).toHaveBeenCalled()
    t.service.warm()
    expect(t.spawn).toHaveBeenCalledTimes(2)
  })
})

describe('stopAll', () => {
  it('kills the helper, and no event goes to a view after it', () => {
    const t = readySetup()
    t.service.start(A)
    const helper = t.child()
    t.service.stopAll()
    expect(helper.kill).toHaveBeenCalled()
    expect(helper.ended).toBe(true)
    say(helper, { t: 'level', v: 0.5 })
    helper.emit('exit', 0, null)
    vi.advanceTimersByTime(HOLD_LIMIT_MS + IDLE_MS)
    expect(t.of(A)).toEqual([READY])
  })

  it('kills a helper that is still in its stop wait', () => {
    const t = readySetup()
    t.service.start(A)
    t.service.stop(A)
    t.service.stopAll()
    expect(t.child().kill).toHaveBeenCalled()
    expect(vi.getTimerCount()).toBe(0)
    vi.advanceTimersByTime(END_LIMIT_MS)
    expect(t.of(A)).toEqual([READY])
  })
})
