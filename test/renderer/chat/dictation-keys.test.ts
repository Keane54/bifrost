// Tests of the hold key of dictation (dictation design 5). A fake terminal types each key that the
// hold key gives back to xterm.js, and each text of typeKey, in the order of the calls. So the
// output shows a lost, a doubled or a moved space.
import { readFileSync } from 'node:fs'
import { join } from 'node:path'
import { afterEach, beforeEach, describe, expect, it, type Mock, vi } from 'vitest'
import {
  type ChatKeyEvent,
  createChatInput,
  createHoldKey,
  HOLD_MS,
  type HoldKeyEvent,
  isModifierKey,
  movesCursor,
  typedTail,
} from '../../../src/renderer/src/chat/dictation-keys'
import { NEW_LINE } from '../../../src/renderer/src/chat/key-rules'

// The code of a key, as the browser gives it for a US layout.
function codeOf(key: string): string {
  if (key === ' ') return 'Space'
  if (/^[a-z]$/i.test(key)) return `Key${key.toUpperCase()}`
  if (/^[0-9]$/.test(key)) return `Digit${key}`
  const named: Record<string, string> = {
    '.': 'Period',
    '/': 'Slash',
    Alt: 'AltLeft',
    Control: 'ControlLeft',
    Enter: 'Enter',
    Meta: 'MetaLeft',
    Process: 'Space',
    Shift: 'ShiftLeft',
  }
  return named[key] ?? key
}

function ev(type: string, key: string, over: Partial<HoldKeyEvent> = {}): HoldKeyEvent {
  return {
    altKey: false,
    code: codeOf(key),
    ctrlKey: false,
    isComposing: false,
    key,
    keyCode: 0,
    metaKey: false,
    repeat: false,
    shiftKey: false,
    type,
    ...over,
  }
}

// heard: the dictation of the hold got its first level or text, or showed the download. By
// default it did.
function setup(opts: { key?: string | null; blocked?: () => boolean; heard?: () => boolean } = {}) {
  let out = ''
  const calls: string[] = []
  const blocked = vi.fn(opts.blocked ?? (() => false))
  const binding = opts.key === undefined ? 'Space' : opts.key
  const hold = createHoldKey<ReturnType<typeof setTimeout>>({
    blocked,
    cancel: () => calls.push('cancel'),
    clearTimeout: timer => clearTimeout(timer),
    heard: opts.heard ?? (() => true),
    key: () => binding,
    setTimeout: (fn, ms) => setTimeout(fn, ms),
    start: () => calls.push('start'),
    stop: () => calls.push('stop'),
    typeKey: text => {
      calls.push(`type:${text}`)
      out += text
    },
  })
  // A key that the hold key does not handle goes to xterm.js, which types a printable key.
  const down = (key: string, over: Partial<HoldKeyEvent> = {}): boolean => {
    const event = ev('keydown', key, over)
    const handled = hold.keydown(event)
    const plain = !event.metaKey && !event.ctrlKey
    if (!handled && plain && [...key].length === 1) out += key
    return handled
  }
  const up = (key: string, over: Partial<HoldKeyEvent> = {}): boolean =>
    hold.keyup(ev('keyup', key, over))
  return { blocked, calls, down, hold, out: () => out, up }
}

beforeEach(() => {
  vi.useFakeTimers()
})

afterEach(() => {
  vi.useRealTimers()
})

describe('createHoldKey', () => {
  it('waits 250 ms', () => {
    expect(HOLD_MS).toBe(250)
  })

  it('types one space for a tap shorter than 250 ms', () => {
    const t = setup()
    expect(t.down(' ')).toBe(true)
    vi.advanceTimersByTime(HOLD_MS - 1)
    expect(t.out()).toBe('')
    expect(t.up(' ')).toBe(true)
    expect(t.out()).toBe(' ')
    vi.advanceTimersByTime(1000)
    expect(t.calls).toEqual(['type: '])
  })

  it('starts dictation for a hold and types no space', () => {
    const t = setup()
    t.down(' ')
    vi.advanceTimersByTime(HOLD_MS)
    expect(t.calls).toEqual(['start'])
    expect(t.up(' ')).toBe(true)
    expect(t.calls).toEqual(['start', 'stop'])
    expect(t.out()).toBe('')
  })

  it('types the space first, then another key of the wait, and starts no dictation', () => {
    const t = setup()
    t.down(' ')
    vi.advanceTimersByTime(100)
    expect(t.down('b')).toBe(false)
    expect(t.out()).toBe(' b')
    vi.advanceTimersByTime(1000)
    expect(t.up(' ')).toBe(true)
    expect(t.calls).toEqual(['type: '])
    expect(t.out()).toBe(' b')
  })

  it('keeps every space in its place for fast typing with rollover (Review Focus 1)', () => {
    const t = setup()
    const text = 'The quick Brown fox, jumps over the lazy dog. Then it runs.'
    // Each key goes down 40 ms after the last key. After every second word, the next key goes
    // down before Space goes up. A capital letter has Shift first, and then Shift goes down
    // before Space goes up.
    const words = text.split(' ')
    for (const [index, word] of words.entries()) {
      for (const [at, char] of [...word].entries()) {
        const upper = char !== char.toLowerCase()
        if (upper) t.down('Shift', { shiftKey: true })
        if (index > 0 && at === 0 && index % 2 === 0) {
          // Rollover: the first key of the word goes down while Space is still down.
          t.down(char, { shiftKey: upper })
          vi.advanceTimersByTime(30)
          t.up(' ')
        } else {
          t.down(char, { shiftKey: upper })
        }
        vi.advanceTimersByTime(40)
        t.up(char, { shiftKey: upper })
        if (upper) t.up('Shift')
      }
      if (index === words.length - 1) break
      t.down(' ')
      vi.advanceTimersByTime(60)
      if (index % 2 === 0) t.up(' ')
    }
    vi.advanceTimersByTime(1000)
    expect(t.out()).toBe(text)
    expect(t.calls).not.toContain('start')
  })

  it('types the key first at a release before the first level, so no space goes (D8)', () => {
    const t = setup({ heard: () => false })
    t.down(' ')
    vi.advanceTimersByTime(HOLD_MS + 400)
    expect(t.up(' ')).toBe(true)
    expect(t.calls).toEqual(['start', 'type: ', 'stop'])
    expect(t.out()).toBe(' ')
  })

  it('types the key first at another key before the first level, then that key', () => {
    const t = setup({ heard: () => false })
    t.down(' ')
    vi.advanceTimersByTime(HOLD_MS + 400)
    expect(t.down('w')).toBe(false)
    expect(t.calls).toEqual(['start', 'type: ', 'cancel'])
    expect(t.out()).toBe(' w')
    t.up(' ')
    expect(t.calls).toEqual(['start', 'type: ', 'cancel'])
  })

  it('types no space after the first level or during the download (ruling D8)', () => {
    // heard is true after the first level or text, and while the chat shows the download.
    const release = setup({ heard: () => true })
    release.down(' ')
    vi.advanceTimersByTime(HOLD_MS)
    release.up(' ')
    const other = setup({ heard: () => true })
    other.down(' ')
    vi.advanceTimersByTime(HOLD_MS)
    other.down('w')
    expect(release.calls).toEqual(['start', 'stop'])
    expect(other.calls).toEqual(['start', 'cancel'])
    expect(other.out()).toBe('w')
  })

  it('ignores the key-repeat events of the held key', () => {
    const t = setup()
    t.down(' ')
    expect(t.down(' ', { repeat: true })).toBe(true)
    vi.advanceTimersByTime(HOLD_MS)
    for (let i = 0; i < 5; i++) expect(t.down(' ', { repeat: true })).toBe(true)
    t.up(' ')
    expect(t.calls).toEqual(['start', 'stop'])
    expect(t.out()).toBe('')
  })

  it.each([
    ['Shift', { shiftKey: true }],
    ['Control', { ctrlKey: true }],
    ['Option', { altKey: true }],
    ['Cmd', { metaKey: true }],
  ])('gives Space with %s to xterm.js as a normal key', (_name, mods) => {
    const t = setup()
    expect(t.down(' ', mods)).toBe(false)
    vi.advanceTimersByTime(1000)
    expect(t.up(' ', mods)).toBe(false)
    expect(t.calls).toEqual([])
  })

  it('gives Space to xterm.js during a composition of an input method', () => {
    const t = setup()
    expect(t.down(' ', { isComposing: true })).toBe(false)
    expect(t.down('Process', { keyCode: 229 })).toBe(false)
    vi.advanceTimersByTime(1000)
    expect(t.calls).toEqual([])
  })

  it('types a space for a blocked session and never starts', () => {
    const t = setup({ blocked: () => true })
    // A normal key: xterm.js types it at once, with its key repeat.
    expect(t.down(' ')).toBe(false)
    expect(t.down(' ', { repeat: true })).toBe(false)
    vi.advanceTimersByTime(1000)
    expect(t.up(' ')).toBe(false)
    expect(t.calls).toEqual([])
    expect(t.out()).toBe('  ')
  })

  it('types the space at the hold when a block comes during the wait', () => {
    let blocked = false
    const t = setup({ blocked: () => blocked })
    t.down(' ')
    blocked = true
    vi.advanceTimersByTime(HOLD_MS)
    expect(t.calls).toEqual(['type: '])
    expect(t.down(' ', { repeat: true })).toBe(true)
    expect(t.up(' ')).toBe(true)
    expect(t.calls).toEqual(['type: '])
  })

  it.each(['another key', 'a blur', 'a close'])('stops dictation early at %s', name => {
    const t = setup()
    t.down(' ')
    vi.advanceTimersByTime(HOLD_MS)
    if (name === 'another key') expect(t.down('a')).toBe(false)
    if (name === 'a blur') t.hold.blur()
    if (name === 'a close') t.hold.close()
    expect(t.calls).toEqual(['start', 'cancel'])
    // The key up and the repeats do nothing more.
    t.down(' ', { repeat: true })
    t.up(' ')
    expect(t.calls).toEqual(['start', 'cancel'])
  })

  it('stops dictation early at a modifier, for example Cmd before Cmd+Tab', () => {
    const t = setup()
    t.down(' ')
    vi.advanceTimersByTime(HOLD_MS)
    t.down('Meta', { metaKey: true })
    expect(t.calls).toEqual(['start', 'cancel'])
  })

  it('types the key at a blur during the wait, but not at a close', () => {
    const blur = setup()
    blur.down(' ')
    blur.hold.blur()
    vi.advanceTimersByTime(1000)
    expect(blur.calls).toEqual(['type: '])
    const close = setup()
    close.down(' ')
    close.hold.close()
    vi.advanceTimersByTime(1000)
    expect(close.calls).toEqual([])
  })

  it('starts again at a new press when the key up did not come', () => {
    const t = setup()
    t.down(' ')
    // macOS sends no key up for a key that goes up while Cmd is down.
    t.down('Meta', { metaKey: true })
    expect(t.calls).toEqual(['type: '])
    t.down(' ')
    vi.advanceTimersByTime(HOLD_MS)
    expect(t.calls).toEqual(['type: ', 'start'])
  })

  it('types the held key at a fallback, and nothing after the release', () => {
    const t = setup()
    t.down(' ')
    vi.advanceTimersByTime(HOLD_MS)
    t.hold.fallback()
    t.hold.fallback()
    expect(t.calls).toEqual(['start', 'type: '])
    t.up(' ')
    t.hold.fallback()
    expect(t.calls).toEqual(['start', 'type: '])
  })

  it('makes Space a normal key when the slot is Off', () => {
    const t = setup({ key: null })
    expect(t.down(' ')).toBe(false)
    vi.advanceTimersByTime(1000)
    expect(t.up(' ')).toBe(false)
    expect(t.calls).toEqual([])
    expect(t.out()).toBe(' ')
  })

  it('uses another key of the setting and types the text of that key', () => {
    const t = setup({ key: '/' })
    expect(t.down(' ')).toBe(false)
    expect(t.down('/')).toBe(true)
    t.up('/')
    expect(t.out()).toBe(' /')
    t.down('/')
    vi.advanceTimersByTime(HOLD_MS)
    expect(t.calls).toEqual(['type:/', 'start'])
  })

  it('handles the keypress of the key while it waits', () => {
    const t = setup()
    expect(t.hold.handle(ev('keypress', ' '))).toBe(false)
    expect(t.hold.handle(ev('keydown', ' '))).toBe(true)
    expect(t.hold.handle(ev('keypress', ' '))).toBe(true)
    expect(t.hold.handle(ev('keyup', ' '))).toBe(true)
    expect(t.calls).toEqual(['type: '])
  })
})

describe('isModifierKey', () => {
  it('finds the keys that type nothing alone', () => {
    for (const key of ['Shift', 'Control', 'Alt', 'Meta', 'CapsLock', 'Fn']) {
      expect(isModifierKey(key)).toBe(true)
    }
    for (const key of [' ', 'a', 'Enter', 'Backspace']) expect(isModifierKey(key)).toBe(false)
  })
})

describe('movesCursor', () => {
  it('finds the cursor keys, also from a mouse wheel with no mouse tracking', () => {
    for (const data of [
      '\x1b[A',
      '\x1b[B',
      '\x1b[C',
      '\x1b[D',
      // The cursor keys in the application mode of the terminal.
      '\x1bOA',
      '\x1bOB',
      '\x1bOC',
      '\x1bOD',
      // With a modifier, for example Ctrl+Right.
      '\x1b[1;5C',
      '\x1b[A\x1b[A\x1b[A',
    ]) {
      expect(movesCursor(data), JSON.stringify(data)).toBe(true)
    }
  })

  it('ignores text and the replies of xterm.js', () => {
    for (const data of [
      'a',
      'ABCD',
      '[A',
      '\r',
      // Focus reports, a cursor position report and a device attributes reply.
      '\x1b[I',
      '\x1b[O',
      '\x1b[12;5R',
      '\x1b[?1;2c',
      // A mouse report.
      '\x1b[<0;10;5M',
    ]) {
      expect(movesCursor(data), JSON.stringify(data)).toBe(false)
    }
  })
})

describe('typedTail', () => {
  const tail = (...chunks: string[]): string => chunks.reduce(typedTail, '')

  it('keeps the typed text', () => {
    expect(tail('he', 'llo')).toBe('hello')
  })

  it('removes the escape sequences, for example arrows and the replies of xterm.js', () => {
    expect(tail('hi', '\x1b[A', '\x1bOB', '\x1b[I', '\x1b[O')).toBe('hi')
    expect(tail('ok', '\x1b[<0;10;5M', '\x1b]11;rgb:0000/0000/0000\x1b\\', '\x1b[?1;2c')).toBe('ok')
    expect(tail('a', '\x1bb')).toBe('a')
  })

  it('keeps the text of a paste', () => {
    expect(tail('x', '\x1b[200~pasted\x1b[201~')).toBe('xpasted')
  })

  it('removes one grapheme for each DEL', () => {
    expect(tail('café 👍🏽', '\x7f')).toBe('café ')
    expect(tail('café', '\x7f')).toBe('caf')
    expect(tail('ab', '\x7f\x7f\x7f')).toBe('')
  })

  it('ends with a new line after Enter and after Shift+Enter', () => {
    expect(tail('hello', '\r')).toBe('hello\n')
    expect(tail('hello', '\x1b\r')).toBe('hello\n')
  })

  it('clears at Ctrl+C and Ctrl+U, and drops the other control characters', () => {
    expect(tail('hello', '\x03')).toBe('')
    expect(tail('hello', '\x15')).toBe('')
    expect(tail('hel', '\t', '\x01', 'lo')).toBe('hello')
  })

  it('keeps only the end of a long text', () => {
    const long = tail('a'.repeat(5000), 'b')
    expect(long.length).toBeLessThanOrEqual(1000)
    expect(long.endsWith('ab')).toBe(true)
  })
})

// The repository has no DOM test. So these tests read the source text of the chat terminal.
describe('the chat terminal uses the hold key', () => {
  const source = readFileSync(
    join(__dirname, '../../../src/renderer/src/chat/chat-terminal.ts'),
    'utf8',
  )

  it('uses the chat input for the keys, the rows, a mouse down, a paste and a drop', () => {
    expect(source).toContain('attachCustomKeyEventHandler(event => this.chatInput.key(event))')
    expect(source).toContain('this.chatInput.row(row)')
    expect(source).toMatch(/\['mousedown', 'paste', 'drop'\]/)
    expect(source).toContain('this.chatInput.other()')
  })

  it('stops dictation at a blur and a close', () => {
    expect(source).toContain("addEventListener('blur'")
    expect(source).toContain('this.holdKey.close()')
    expect(source).toContain('this.dictation.dispose()')
  })

  it('warms the speech helper when the terminal gets the focus', () => {
    expect(source).toContain("addEventListener('focus'")
    expect(source).toMatch(/dictation\.warm\(\)/)
  })

  it('gives the data of xterm.js to the chat input', () => {
    expect(source).toContain('this.term.onData(data => this.chatInput.data(data))')
  })

  it('keeps the typed text for the leading space, and clears it for a new PTY', () => {
    expect(source).toContain('typedTail(this.typed, data)')
    expect(source).toMatch(/this\.attachCount \+= 1\s+this\.typed = ''/)
  })
})

// A key event with a preventDefault spy.
function chatEvent(
  type: string,
  key: string,
  over: Partial<HoldKeyEvent> = {},
): ChatKeyEvent & { preventDefault: Mock<() => void> } {
  return { ...ev(type, key, over), preventDefault: vi.fn<() => void>() }
}

// waits: the final text of a released dictation still types (ruling D9).
function chatSetup(
  holdTakes: (event: HoldKeyEvent) => boolean = () => false,
  waits: () => boolean = () => false,
) {
  const calls: string[] = []
  const input = createChatInput({
    block: () => calls.push('block'),
    hold: {
      handle: event => {
        calls.push(`hold:${event.type}`)
        return holdTakes(event)
      },
    },
    input: text => calls.push(`input:${JSON.stringify(text)}`),
    interrupt: () => calls.push('interrupt'),
    waits,
    warm: () => calls.push('warm'),
  })
  return { calls, input }
}

describe('createChatInput', () => {
  it('gives each key event to the hold key first, and stops xterm.js for a key it takes', () => {
    const t = chatSetup(event => event.key === ' ')
    const down = chatEvent('keydown', ' ')
    expect(t.input.key(down)).toBe(false)
    expect(down.preventDefault).toHaveBeenCalledTimes(1)
    const repeat = chatEvent('keydown', ' ', { repeat: true })
    expect(t.input.key(repeat)).toBe(false)
    const up = chatEvent('keyup', ' ')
    expect(t.input.key(up)).toBe(false)
    expect(up.preventDefault).toHaveBeenCalledTimes(1)
    // A new press warms the speech helper. No other key rule runs.
    expect(t.calls).toEqual(['hold:keydown', 'warm', 'hold:keydown', 'hold:keyup'])
  })

  it('stops a dictation at another key, before the key rules and before the key goes out', () => {
    const t = chatSetup()
    const shiftEnter = chatEvent('keydown', 'Enter', { shiftKey: true })
    expect(t.input.key(shiftEnter)).toBe(false)
    expect(shiftEnter.preventDefault).toHaveBeenCalledTimes(1)
    expect(t.calls).toEqual(['hold:keydown', 'interrupt', `input:${JSON.stringify(NEW_LINE)}`])
    const letter = chatEvent('keydown', 'a')
    expect(t.input.key(letter)).toBe(true)
    expect(letter.preventDefault).not.toHaveBeenCalled()
    expect(t.calls.slice(3)).toEqual(['hold:keydown', 'interrupt'])
  })

  it('does not stop a dictation at a modifier key alone, or at a key up', () => {
    const t = chatSetup()
    for (const key of ['Shift', 'Meta', 'Alt', 'Control', 'CapsLock']) {
      expect(t.input.key(chatEvent('keydown', key))).toBe(true)
    }
    expect(t.input.key(chatEvent('keyup', 'a'))).toBe(true)
    expect(t.calls).not.toContain('interrupt')
  })

  it('stops a dictation when the row shows a blocking choice', () => {
    const t = chatSetup()
    t.input.row(undefined)
    t.input.row({ box: 'none' })
    t.input.row({ box: 'yellow' })
    t.input.row({ box: 'red', boxReason: 'escalated' })
    t.input.row({ box: 'red', boxReason: 'error' })
    expect(t.calls).toEqual([])
    t.input.row({ box: 'red', boxReason: 'prompt' })
    t.input.row({ box: 'red' })
    // A block also drops the keys that wait for the typer.
    expect(t.calls).toEqual(['block', 'block'])
  })

  it('does not stop the typer of a final text at a key, but Escape and Ctrl+C stop it (D9)', () => {
    const t = chatSetup(
      () => false,
      () => true,
    )
    expect(t.input.key(chatEvent('keydown', 'a'))).toBe(true)
    expect(t.input.key(chatEvent('keydown', 'Enter'))).toBe(true)
    expect(t.calls).toEqual(['hold:keydown', 'hold:keydown'])
    // Escape and Ctrl+C stop each typer and drop the keys that wait (ruling D12).
    t.input.key(chatEvent('keydown', 'Escape'))
    t.input.key(chatEvent('keydown', 'c', { ctrlKey: true }))
    expect(t.calls.slice(2)).toEqual(['hold:keydown', 'block', 'hold:keydown', 'block'])
  })

  it('stops all at Escape and Ctrl+C also with no final text, and keeps the key (D12)', () => {
    const t = chatSetup()
    expect(t.input.key(chatEvent('keydown', 'Escape'))).toBe(true)
    expect(t.input.key(chatEvent('keydown', 'c', { ctrlKey: true }))).toBe(true)
    expect(t.calls).toEqual(['hold:keydown', 'block', 'hold:keydown', 'block'])
  })

  it('reads the wait before the hold key acts, so a key of a live dictation stops it', () => {
    let waits = false
    // The hold key stops a live dictation at the key. After that, the old final can still type.
    const t = chatSetup(
      () => {
        waits = true
        return false
      },
      () => waits,
    )
    t.input.key(chatEvent('keydown', 'a'))
    expect(t.calls).toEqual(['hold:keydown', 'interrupt'])
  })

  it('stops a dictation at input with no key down: a mouse down, a paste or a drop', () => {
    const t = chatSetup()
    t.input.other()
    expect(t.calls).toEqual(['interrupt'])
  })

  it('stops a dictation before a cursor key of xterm.js goes to the PTY', () => {
    const t = chatSetup()
    // A mouse wheel with no mouse tracking sends the arrow keys, with no key down.
    t.input.data('\x1b[A')
    t.input.data('\x1bOB')
    expect(t.calls).toEqual([
      'interrupt',
      `input:${JSON.stringify('\x1b[A')}`,
      'interrupt',
      `input:${JSON.stringify('\x1bOB')}`,
    ])
  })

  it('sends text and the replies of xterm.js with no stop', () => {
    const t = chatSetup()
    t.input.data('a')
    t.input.data('\x1b[I')
    t.input.data('\x1b[12;5R')
    expect(t.calls).toEqual([
      `input:${JSON.stringify('a')}`,
      `input:${JSON.stringify('\x1b[I')}`,
      `input:${JSON.stringify('\x1b[12;5R')}`,
    ])
  })

  it('lets a cursor key wait while a final text types', () => {
    const t = chatSetup(
      () => false,
      () => true,
    )
    t.input.data('\x1b[B')
    expect(t.calls).toEqual([`input:${JSON.stringify('\x1b[B')}`])
  })

  it('does not stop the typer of a final text at a mouse down, a paste or a drop', () => {
    const t = chatSetup(
      () => false,
      () => true,
    )
    t.input.other()
    expect(t.calls).toEqual([])
  })
})
