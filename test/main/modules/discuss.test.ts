// Discuss with Claude (plan Task 10, Modules design 8.4, Review Focus 5). A module can only ask.
// Heimdall shows the request in its own panel, with an empty prompt box. Only the text of the
// user goes to Claude, in a folder that the user picks, with the normal Claude setup of the user.
// The tests use fakes: no claude, no clipboard and no file system.
import { describe, expect, it } from 'vitest'
import {
  createDiscuss,
  DISCUSS_WAIT_MS,
  type DiscussDeps,
  discussSessionName,
  REASON_DISCUSS_EMPTY,
  REASON_FOLDER_CHECK,
  REASON_MODULE_FOLDER,
} from '../../../src/main/modules/discuss'
import { MAX_DISCUSS_SESSIONS } from '../../../src/main/modules/module-state'
import {
  type ModuleDiscuss,
  REFUSED_BAD_MODULE_INPUT,
  REFUSED_DISCUSS_OPEN,
  REFUSED_DISCUSS_WAIT,
  REFUSED_MODULE_OFF,
  REFUSED_NO_REQUEST,
} from '../../../src/shared/modules'
import {
  type NewSessionSpec,
  REASON_DIR_MISSING,
  REASON_NO_FOLDER,
  REASON_PROMPT_FLAG,
  REASON_PROMPT_IS_COMMAND,
} from '../../../src/shared/new-session'

const HOME = '/Users/someone'
const MODULES = `${HOME}/.bifrost/modules`
const MODULES_DATA = `${HOME}/.bifrost/modules-data`
const JOBS = '/var/folders/xy/T/bifrost-module-jobs'
const PROJECT = `${HOME}/project`
const CARD_TEXT = 'Card text that Claude must never see.'

// The fake file system: each symbolic link and its target. A path under a missing folder fails.
const LINKS: Record<string, string> = {
  '/var': '/private/var',
  [`${HOME}/link-to-modules`]: MODULES,
  [`${HOME}/link-to-data`]: `${MODULES_DATA}`,
}
const MISSING = [`${HOME}/missing`]

async function fakeRealpath(path: string): Promise<string> {
  let real = path
  for (const [link, target] of Object.entries(LINKS)) {
    if (path === link || path.startsWith(`${link}/`)) {
      real = target + path.slice(link.length)
      break
    }
  }
  if (MISSING.some(m => real === m || real.startsWith(`${m}/`))) {
    throw Object.assign(new Error('ENOENT'), { code: 'ENOENT' })
  }
  return real
}

// The fake identity of a folder. /System/Volumes/Data/<path> is the same folder as /<path> (a
// firmlink, and realpath keeps that form). /var is /private/var. A Mac folder name does not care
// about case. Each folder gets its own inode number.
const FIRMLINK = '/System/Volumes/Data'
const INODES = new Map<string, number>()

function sameFolder(path: string): string {
  let p =
    path === FIRMLINK ? '/' : path.startsWith(`${FIRMLINK}/`) ? path.slice(FIRMLINK.length) : path
  if (p === '/var' || p.startsWith('/var/')) p = `/private${p}`
  return p.toLowerCase()
}

async function fakeStat(path: string): Promise<{ dev: number; ino: number }> {
  const real = await fakeRealpath(path)
  const key = sameFolder(real)
  let ino = INODES.get(key)
  if (ino === undefined) {
    ino = INODES.size + 1
    INODES.set(key, ino)
  }
  return { dev: 7, ino }
}

interface Setup {
  discuss: ReturnType<typeof createDiscuss>
  opened: ModuleDiscuss[]
  clipboard: string[]
  created: NewSessionSpec[]
  names: Record<string, string | null>
  // The ids that Discuss gave to the modules state, and the hand-overs that it gave.
  saved: string[]
  carried: [string, string][]
  advance(ms: number): void
}

function setup(over: Partial<DiscussDeps> = {}): Setup {
  const opened: ModuleDiscuss[] = []
  const clipboard: string[] = []
  const created: NewSessionSpec[] = []
  const names: Record<string, string | null> = { demo: 'Demo', other: 'Other' }
  const saved: string[] = []
  const carried: [string, string][] = []
  let now = 10_000
  let next = 0
  const discuss = createDiscuss({
    blockedFolders: [MODULES, MODULES_DATA, JOBS],
    carrySession: (from, to) => {
      carried.push([from, to])
    },
    createSession: async spec => {
      created.push(spec)
      return { sessionId: 'session-1' }
    },
    moduleName: id => names[id] ?? null,
    now: () => now,
    open: view => {
      opened.push(view)
    },
    realpath: fakeRealpath,
    requestId: () => {
      next += 1
      return `req-${next}`
    },
    saveSession: id => {
      saved.push(id)
    },
    stat: fakeStat,
    writeClipboard: text => {
      clipboard.push(text)
    },
    ...over,
  })
  return {
    advance: ms => {
      now += ms
    },
    carried,
    clipboard,
    created,
    discuss,
    names,
    opened,
    saved,
  }
}

const REQ = { cards: [{ label: 'Notes', text: CARD_TEXT }], title: 'Plan the week' }

describe('the request of a module', () => {
  it('opens Heimdall with the title and the cards, and with no prompt', async () => {
    const t = setup()
    await expect(t.discuss.request('demo', REQ)).resolves.toBeNull()
    expect(t.opened).toEqual([
      {
        cards: [{ label: 'Notes', text: CARD_TEXT }],
        moduleId: 'demo',
        moduleName: 'Demo',
        requestId: 'req-1',
        title: 'Plan the week',
      },
    ])
    // The view holds nothing that could fill the prompt box.
    expect(Object.keys(t.opened[0] as object).sort()).toEqual([
      'cards',
      'moduleId',
      'moduleName',
      'requestId',
      'title',
    ])
  })

  it('accepts a request with no cards', async () => {
    const t = setup()
    await t.discuss.request('demo', { title: 'Talk' })
    expect(t.opened[0]?.cards).toEqual([])
  })

  it('refuses a prompt from the module, or any other key', async () => {
    const t = setup()
    for (const extra of [{ prompt: 'Do this' }, { cwd: '/tmp' }, { model: 'opus' }]) {
      await expect(t.discuss.request('demo', { ...REQ, ...extra })).rejects.toThrow(
        REFUSED_BAD_MODULE_INPUT,
      )
    }
    await expect(
      t.discuss.request('demo', { cards: [{ label: 'a', prompt: 'x', text: 'b' }], title: 'T' }),
    ).rejects.toThrow(REFUSED_BAD_MODULE_INPUT)
    expect(t.opened).toEqual([])
  })

  it('accepts the limits, and refuses one character or one card more', async () => {
    const card = { label: 'L'.repeat(40), text: 'T'.repeat(4000) }
    const max = { cards: Array.from({ length: 8 }, () => card), title: 'A'.repeat(80) }
    const t = setup()
    await expect(t.discuss.request('demo', max)).resolves.toBeNull()

    const bad: unknown[] = [
      null,
      'Plan',
      [],
      {},
      { title: '' },
      { title: '   ' },
      { title: 7 },
      { title: 'A'.repeat(81) },
      { title: 'Two\nlines' },
      { title: 'Tab\there' },
      { cards: 'x', title: 'T' },
      { cards: [null], title: 'T' },
      { cards: Array.from({ length: 9 }, () => card), title: 'T' },
      { cards: [{ label: 'L'.repeat(41), text: 'x' }], title: 'T' },
      { cards: [{ label: 'L', text: 'T'.repeat(4001) }], title: 'T' },
      { cards: [{ label: '', text: 'x' }], title: 'T' },
      { cards: [{ label: 'L', text: '' }], title: 'T' },
      { cards: [{ label: 'L' }], title: 'T' },
      { cards: [{ label: 7, text: 'x' }], title: 'T' },
      { cards: [{ label: 'Two\nlines', text: 'x' }], title: 'T' },
    ]
    for (const args of bad) {
      const u = setup()
      await expect(u.discuss.request('demo', args), JSON.stringify(args)).rejects.toThrow(
        REFUSED_BAD_MODULE_INPUT,
      )
      expect(u.opened).toEqual([])
    }
  })

  it('removes invisible characters from the title and the cards, and keeps new lines', async () => {
    const t = setup()
    await t.discuss.request('demo', {
      cards: [{ label: 'No\u200Btes', text: 'Line one\u202E\nLine\u2060 two' }],
      title: 'Plan\u200D the\uFEFF week',
    })
    expect(t.opened[0]).toMatchObject({
      cards: [{ label: 'Notes', text: 'Line one\nLine two' }],
      title: 'Plan the week',
    })
  })

  it('removes control characters from a card text, and keeps tabs', async () => {
    const t = setup()
    await t.discuss.request('demo', {
      cards: [{ label: 'Log', text: 'red \x1b[31mtext\x07\r\nnext\tline' }],
      title: 'T',
    })
    expect(t.opened[0]?.cards).toEqual([{ label: 'Log', text: 'red [31mtext\nnext\tline' }])
  })

  it('removes the invisible characters that the manifest check allows in a name', async () => {
    const t = setup()
    // A Hangul filler and a variation selector pass the manifest check of the name.
    t.names.demo = `De${String.fromCodePoint(0x3164)}mo${String.fromCodePoint(0xfe0f)}`
    await t.discuss.request('demo', REQ)
    expect(t.opened[0]?.moduleName).toBe('Demo')
    await t.discuss.start('req-1', { cwd: PROJECT, prompt: 'Go.' })
    expect(t.created[0]?.name).toBe('Demo: Go.')
  })

  it('drops "-" and spaces at the start of the module name in the session name', async () => {
    for (const [name, label] of [
      ['-Planner', 'Planner'],
      [' - Planner', 'Planner'],
      ['---', 'demo'],
    ]) {
      const t = setup()
      t.names.demo = name as string
      await t.discuss.request('demo', REQ)
      // The view shows the approved name.
      expect(t.opened[0]?.moduleName).toBe((name as string).trim())
      await t.discuss.start('req-1', { cwd: PROJECT, prompt: 'Go.' })
      expect(t.created[0]?.name, name).toBe(`${label}: Go.`)
    }
  })

  it('names the module by its id when its name has only invisible characters', async () => {
    const t = setup()
    t.names.demo = String.fromCodePoint(0x3164, 0x3164)
    await t.discuss.request('demo', REQ)
    expect(t.opened[0]?.moduleName).toBe('demo')
    await t.discuss.start('req-1', { cwd: PROJECT, prompt: 'Go.' })
    expect(t.created[0]?.name).toBe('demo: Go.')
  })

  it('refuses a format character or a line separator that the strip keeps', async () => {
    // U+0600 and U+FFF9 are format characters that are not default ignorable.
    for (const c of [0x0600, 0xfff9, 0x2028, 0x2029]) {
      const ch = String.fromCodePoint(c)
      for (const args of [
        { title: `Plan${ch}week` },
        { cards: [{ label: `No${ch}tes`, text: 'x' }], title: 'T' },
      ]) {
        const t = setup()
        await expect(t.discuss.request('demo', args), c.toString(16)).rejects.toThrow(
          REFUSED_BAD_MODULE_INPUT,
        )
      }
    }
  })

  it('refuses a title that has only invisible characters', async () => {
    const t = setup()
    await expect(t.discuss.request('demo', { title: '\u200B\u200B' })).rejects.toThrow(
      REFUSED_BAD_MODULE_INPUT,
    )
  })

  it('refuses a module that is off or has no discuss permission', async () => {
    const t = setup()
    t.names.demo = null
    await expect(t.discuss.request('demo', REQ)).rejects.toThrow(REFUSED_MODULE_OFF)
    expect(t.opened).toEqual([])
  })

  it('keeps one open request for all modules', async () => {
    const t = setup()
    await t.discuss.request('demo', REQ)
    await expect(t.discuss.request('demo', REQ)).rejects.toThrow(REFUSED_DISCUSS_OPEN)
    await expect(t.discuss.request('other', REQ)).rejects.toThrow(REFUSED_DISCUSS_OPEN)
    expect(t.opened).toHaveLength(1)
  })

  it('refuses a new request of the module within 5 s of a cancel', async () => {
    expect(DISCUSS_WAIT_MS).toBe(5000)
    const t = setup()
    await t.discuss.request('demo', REQ)
    t.discuss.cancel('req-1')
    await expect(t.discuss.request('demo', REQ)).rejects.toThrow(REFUSED_DISCUSS_WAIT)
    t.advance(4999)
    await expect(t.discuss.request('demo', REQ)).rejects.toThrow(REFUSED_DISCUSS_WAIT)
    t.advance(1)
    await expect(t.discuss.request('demo', REQ)).resolves.toBeNull()
    expect(t.opened).toHaveLength(2)
  })

  it('lets another module ask at once after a cancel', async () => {
    const t = setup()
    await t.discuss.request('demo', REQ)
    t.discuss.cancel('req-1')
    await expect(t.discuss.request('other', REQ)).resolves.toBeNull()
  })

  it('ignores a cancel of a request that is not open', async () => {
    const t = setup()
    await t.discuss.request('demo', REQ)
    t.discuss.cancel('req-9')
    t.discuss.cancel(7)
    await expect(t.discuss.request('other', REQ)).rejects.toThrow(REFUSED_DISCUSS_OPEN)
    t.discuss.cancel('req-1')
    t.discuss.cancel('req-1')
    await expect(t.discuss.request('other', REQ)).resolves.toBeNull()
  })

  it('drops the open request when the page ends, with no wait', async () => {
    const t = setup()
    await t.discuss.request('demo', REQ)
    t.discuss.clear()
    await expect(t.discuss.request('demo', REQ)).resolves.toBeNull()
  })
})

describe('Copy', () => {
  it('writes the card text to the clipboard from main, with no invisible character', async () => {
    const t = setup()
    await t.discuss.request('demo', {
      cards: [
        { label: 'A', text: 'First' },
        { label: 'B', text: 'Sec\u200Bond\u202E\nline' },
      ],
      title: 'T',
    })
    await t.discuss.copy('req-1', 1)
    await t.discuss.copy('req-1', 0)
    expect(t.clipboard).toEqual(['Second\nline', 'First'])
  })

  it('refuses a bad card index and a request that is not open', async () => {
    const t = setup()
    await t.discuss.request('demo', REQ)
    for (const index of [-1, 1, 0.5, '0', null, Number.NaN]) {
      await expect(t.discuss.copy('req-1', index), String(index)).rejects.toThrow(
        REFUSED_BAD_MODULE_INPUT,
      )
    }
    await expect(t.discuss.copy('req-2', 0)).rejects.toThrow(REFUSED_NO_REQUEST)
    expect(t.clipboard).toEqual([])
  })

  it('gives a failed clipboard write to the page', async () => {
    const t = setup({
      writeClipboard: async () => {
        throw new Error('no clipboard')
      },
    })
    await t.discuss.request('demo', REQ)
    await expect(t.discuss.copy('req-1', 0)).rejects.toThrow('no clipboard')
  })

  it('refuses a copy when the module is off now, and closes the request', async () => {
    const t = setup()
    await t.discuss.request('demo', REQ)
    t.names.demo = null
    await expect(t.discuss.copy('req-1', 0)).rejects.toThrow(REFUSED_MODULE_OFF)
    expect(t.clipboard).toEqual([])
    await expect(t.discuss.request('other', REQ)).resolves.toBeNull()
  })
})

describe('Start', () => {
  it('starts a session with only the text of the user, and the normal setup', async () => {
    const t = setup()
    await t.discuss.request('demo', REQ)
    await expect(
      t.discuss.start('req-1', { cwd: PROJECT, prompt: '  Help me\u200B plan.\u202E  ' }),
    ).resolves.toEqual({ sessionId: 'session-1' })
    expect(t.created).toEqual([
      {
        cwd: PROJECT,
        model: '',
        name: 'Demo: Help me plan.',
        permissionMode: '',
        prompt: 'Help me plan.',
        worktree: false,
      },
    ])
    // No card text and no module text other than the label reaches the session.
    expect(JSON.stringify(t.created)).not.toContain(CARD_TEXT)
  })

  it('never puts a card text in the prompt, also when the user copied one', async () => {
    const t = setup()
    await t.discuss.request('demo', REQ)
    await t.discuss.copy('req-1', 0)
    await t.discuss.start('req-1', { cwd: PROJECT, prompt: 'My own words.' })
    expect(t.created[0]?.prompt).toBe('My own words.')
  })

  it('gives the module no handle to the session', async () => {
    const t = setup()
    // The answer to the module is null, and the deps have no way to send to a module.
    await expect(t.discuss.request('demo', REQ)).resolves.toBeNull()
    await t.discuss.start('req-1', { cwd: PROJECT, prompt: 'Go.' })
    expect(t.opened).toHaveLength(1)
    expect(JSON.stringify(t.opened)).not.toContain('session-1')
  })

  it('closes the request after the start, so a module can ask again at once', async () => {
    const t = setup()
    await t.discuss.request('demo', REQ)
    await t.discuss.start('req-1', { cwd: PROJECT, prompt: 'Go.' })
    await expect(t.discuss.start('req-1', { cwd: PROJECT, prompt: 'Go.' })).rejects.toThrow(
      REFUSED_NO_REQUEST,
    )
    await expect(t.discuss.request('demo', REQ)).resolves.toBeNull()
  })

  it('refuses an empty prompt', async () => {
    const t = setup()
    await t.discuss.request('demo', REQ)
    for (const prompt of ['', '   ', '\n\t', '\u200B\u2060\uFEFF']) {
      await expect(t.discuss.start('req-1', { cwd: PROJECT, prompt })).rejects.toThrow(
        REASON_DISCUSS_EMPTY,
      )
    }
    expect(t.created).toEqual([])
  })

  it('refuses the prompts that the New session check refuses', async () => {
    const t = setup()
    await t.discuss.request('demo', REQ)
    const cases: [string, string][] = [
      ['-p hi', REASON_PROMPT_FLAG],
      ['  --dangerously-skip-permissions', REASON_PROMPT_FLAG],
      ['\u200B-p hi', REASON_PROMPT_FLAG],
      ['update', REASON_PROMPT_IS_COMMAND],
      [' doctor ', REASON_PROMPT_IS_COMMAND],
      ['mcp\u200B', REASON_PROMPT_IS_COMMAND],
    ]
    for (const [prompt, reason] of cases) {
      await expect(t.discuss.start('req-1', { cwd: PROJECT, prompt }), prompt).rejects.toThrow(
        reason,
      )
    }
    expect(t.created).toEqual([])
  })

  it('refuses a folder that a module can write, or that module jobs use', async () => {
    const blocked = [
      MODULES,
      `${MODULES}/`,
      `${MODULES}/demo/current`,
      MODULES_DATA,
      `${MODULES_DATA}/sub`,
      `${HOME}/.Bifrost/Modules/demo`,
      `${HOME}/link-to-modules/demo`,
      `${HOME}/link-to-data`,
      `${JOBS}/demo`,
      // The real path of the jobs folder starts with /private/var.
      '/private/var/folders/xy/T/bifrost-module-jobs/demo',
      `${HOME}/project/../.bifrost/modules/demo`,
    ]
    for (const cwd of blocked) {
      const t = setup()
      await t.discuss.request('demo', REQ)
      await expect(t.discuss.start('req-1', { cwd, prompt: 'Go.' }), cwd).rejects.toThrow(
        REASON_MODULE_FOLDER,
      )
      expect(t.created).toEqual([])
    }
  })

  it('accepts a folder next to the module folders', async () => {
    for (const cwd of [`${HOME}/.bifrost`, `${MODULES}-old`, `${HOME}/.bifrost/modules-data2`]) {
      const t = setup()
      await t.discuss.request('demo', REQ)
      await expect(t.discuss.start('req-1', { cwd, prompt: 'Go.' }), cwd).resolves.toEqual({
        sessionId: 'session-1',
      })
    }
  })

  it('refuses the firmlink form of a blocked folder, by the identity of the folder', async () => {
    const blocked = [
      `${FIRMLINK}${MODULES}/demo/current`,
      `${FIRMLINK}${MODULES}`,
      `${FIRMLINK}${MODULES_DATA}`,
      `${FIRMLINK}/private${JOBS}/demo`,
      `${FIRMLINK}${HOME}/.BIFROST/modules/demo`,
    ]
    for (const cwd of blocked) {
      const t = setup()
      await t.discuss.request('demo', REQ)
      await expect(t.discuss.start('req-1', { cwd, prompt: 'Go.' }), cwd).rejects.toThrow(
        REASON_MODULE_FOLDER,
      )
      expect(t.created).toEqual([])
    }
  })

  it('accepts the firmlink form of a normal folder', async () => {
    const t = setup()
    await t.discuss.request('demo', REQ)
    await t.discuss.start('req-1', { cwd: `${FIRMLINK}${PROJECT}`, prompt: 'Go.' })
    expect(t.created[0]?.cwd).toBe(`${FIRMLINK}${PROJECT}`)
  })

  it('refuses a folder when Bifrost cannot check a folder of the walk (fail closed)', async () => {
    const denied = (path: string): Error =>
      Object.assign(new Error(`EACCES: ${path}`), { code: 'EACCES' })
    for (const bad of [PROJECT, HOME, '/Users']) {
      const t = setup({
        stat: async path => {
          if (path === bad) throw denied(path)
          return fakeStat(path)
        },
      })
      await t.discuss.request('demo', REQ)
      await expect(t.discuss.start('req-1', { cwd: PROJECT, prompt: 'Go.' }), bad).rejects.toThrow(
        REASON_FOLDER_CHECK,
      )
      expect(t.created).toEqual([])
    }
    expect(REASON_FOLDER_CHECK).toBe("Bifrost can't check that folder. Choose another folder.")
  })

  it('refuses a folder that goes away during the check', async () => {
    const t = setup({
      stat: async path => {
        if (path === PROJECT) throw Object.assign(new Error('ENOENT'), { code: 'ENOENT' })
        return fakeStat(path)
      },
    })
    await t.discuss.request('demo', REQ)
    await expect(t.discuss.start('req-1', { cwd: PROJECT, prompt: 'Go.' })).rejects.toThrow(
      REASON_FOLDER_CHECK,
    )
  })

  it('refuses each folder when Bifrost cannot check a blocked folder', async () => {
    const t = setup({
      stat: async path => {
        if (path === MODULES) throw Object.assign(new Error('EACCES'), { code: 'EACCES' })
        return fakeStat(path)
      },
    })
    await t.discuss.request('demo', REQ)
    await expect(t.discuss.start('req-1', { cwd: PROJECT, prompt: 'Go.' })).rejects.toThrow(
      REASON_FOLDER_CHECK,
    )
  })

  it('skips a blocked folder that does not exist', async () => {
    const t = setup({ blockedFolders: [MODULES, `${HOME}/missing/jobs`] })
    await t.discuss.request('demo', REQ)
    await expect(t.discuss.start('req-1', { cwd: PROJECT, prompt: 'Go.' })).resolves.toEqual({
      sessionId: 'session-1',
    })
  })

  it('starts in the real path of the folder', async () => {
    const t = setup()
    await t.discuss.request('demo', REQ)
    await t.discuss.start('req-1', { cwd: '/var/work/app', prompt: 'Go.' })
    expect(t.created[0]?.cwd).toBe('/private/var/work/app')
  })

  it('refuses a folder that is not absolute or does not exist', async () => {
    const t = setup()
    await t.discuss.request('demo', REQ)
    await expect(t.discuss.start('req-1', { cwd: '', prompt: 'Go.' })).rejects.toThrow(
      REASON_NO_FOLDER,
    )
    await expect(t.discuss.start('req-1', { cwd: 'project', prompt: 'Go.' })).rejects.toThrow(
      REASON_NO_FOLDER,
    )
    await expect(
      t.discuss.start('req-1', { cwd: `${HOME}/missing/app`, prompt: 'Go.' }),
    ).rejects.toThrow(REASON_DIR_MISSING)
    expect(t.created).toEqual([])
  })

  it('refuses bad input and a request that is not open', async () => {
    const t = setup()
    await t.discuss.request('demo', REQ)
    for (const input of [
      null,
      'Go.',
      { prompt: 'Go.' },
      { cwd: PROJECT },
      { cwd: 1, prompt: 'x' },
    ]) {
      await expect(t.discuss.start('req-1', input), JSON.stringify(input)).rejects.toThrow(
        REFUSED_BAD_MODULE_INPUT,
      )
    }
    await expect(
      t.discuss.start('req-1', { cwd: PROJECT, model: 'opus', prompt: 'Go.' }),
    ).rejects.toThrow(REFUSED_BAD_MODULE_INPUT)
    await expect(t.discuss.start('req-2', { cwd: PROJECT, prompt: 'Go.' })).rejects.toThrow(
      REFUSED_NO_REQUEST,
    )
    await expect(t.discuss.start(7, { cwd: PROJECT, prompt: 'Go.' })).rejects.toThrow(
      REFUSED_NO_REQUEST,
    )
    expect(t.created).toEqual([])
  })

  it('refuses a start when the module is off now, and closes the request', async () => {
    const t = setup()
    await t.discuss.request('demo', REQ)
    t.names.demo = null
    await expect(t.discuss.start('req-1', { cwd: PROJECT, prompt: 'Go.' })).rejects.toThrow(
      REFUSED_MODULE_OFF,
    )
    expect(t.created).toEqual([])
    await expect(t.discuss.request('other', REQ)).resolves.toBeNull()
  })

  it('keeps the request open after a failed start, so the user can try again', async () => {
    let fail = true
    const t = setup({
      createSession: async () => {
        if (fail) throw new Error("This folder doesn't exist.")
        return { sessionId: 'session-2' }
      },
    })
    await t.discuss.request('demo', REQ)
    await expect(t.discuss.start('req-1', { cwd: PROJECT, prompt: 'Go.' })).rejects.toThrow(
      "This folder doesn't exist.",
    )
    fail = false
    await expect(t.discuss.start('req-1', { cwd: PROJECT, prompt: 'Go.' })).resolves.toEqual({
      sessionId: 'session-2',
    })
  })

  it('runs one start at a time, and a cancel during it closes the request after it', async () => {
    let release: () => void = () => {}
    let entered: () => void = () => {}
    const inCreate = new Promise<void>(resolve => {
      entered = resolve
    })
    const t = setup({
      createSession: () =>
        new Promise(resolve => {
          release = () => resolve({ sessionId: 'session-3' })
          entered()
        }),
    })
    await t.discuss.request('demo', REQ)
    const first = t.discuss.start('req-1', { cwd: PROJECT, prompt: 'Go.' })
    await expect(t.discuss.start('req-1', { cwd: PROJECT, prompt: 'Go.' })).rejects.toThrow(
      REFUSED_NO_REQUEST,
    )
    // claude runs now, so the cancel cannot stop the start.
    await inCreate
    t.discuss.cancel('req-1')
    await expect(t.discuss.request('other', REQ)).rejects.toThrow(REFUSED_DISCUSS_OPEN)
    release()
    await expect(first).resolves.toEqual({ sessionId: 'session-3' })
    await expect(t.discuss.request('other', REQ)).resolves.toBeNull()
  })

  it('does not run claude when a cancel came during the folder check', async () => {
    let openGate: () => void = () => {}
    const gate = new Promise<void>(resolve => {
      openGate = resolve
    })
    const t = setup({
      realpath: async path => {
        await gate
        return fakeRealpath(path)
      },
    })
    await t.discuss.request('demo', REQ)
    const first = t.discuss.start('req-1', { cwd: PROJECT, prompt: 'Go.' })
    t.discuss.cancel('req-1')
    openGate()
    await expect(first).rejects.toThrow(REFUSED_NO_REQUEST)
    expect(t.created).toEqual([])
    await expect(t.discuss.request('other', REQ)).resolves.toBeNull()
  })

  it('closes the request when a cancel came during a start that failed', async () => {
    let reject: (e: Error) => void = () => {}
    let entered: () => void = () => {}
    const inCreate = new Promise<void>(resolve => {
      entered = resolve
    })
    const t = setup({
      createSession: () =>
        new Promise((_resolve, fail) => {
          reject = fail
          entered()
        }),
    })
    await t.discuss.request('demo', REQ)
    const first = t.discuss.start('req-1', { cwd: PROJECT, prompt: 'Go.' })
    await inCreate
    t.discuss.cancel('req-1')
    reject(new Error('claude not found'))
    await expect(first).rejects.toThrow('claude not found')
    await expect(t.discuss.start('req-1', { cwd: PROJECT, prompt: 'Go.' })).rejects.toThrow(
      REFUSED_NO_REQUEST,
    )
    // The cancel counts, so the module waits.
    await expect(t.discuss.request('demo', REQ)).rejects.toThrow(REFUSED_DISCUSS_WAIT)
  })
})

describe('the sessions of Discuss (ruling P12)', () => {
  it('remembers each session that it started, so Heimdall hides it from modules', async () => {
    const t = setup()
    expect(t.discuss.isDiscussSession('session-1')).toBe(false)
    await t.discuss.request('demo', REQ)
    await t.discuss.start('req-1', { cwd: PROJECT, prompt: 'Go.' })
    expect(t.discuss.isDiscussSession('session-1')).toBe(true)
    expect(t.discuss.isDiscussSession('session-2')).toBe(false)
    // The id also goes to the modules state, so it stays hidden after a restart.
    expect(t.saved).toEqual(['session-1'])
    // The end of a page drops the open request, not the started sessions.
    t.discuss.clear()
    expect(t.discuss.isDiscussSession('session-1')).toBe(true)
  })

  it('does not remember a session that did not start', async () => {
    const t = setup({
      createSession: async () => {
        throw new Error('claude not found')
      },
    })
    await t.discuss.request('demo', REQ)
    await expect(t.discuss.start('req-1', { cwd: PROJECT, prompt: 'Go.' })).rejects.toThrow()
    expect(t.discuss.isDiscussSession('session-1')).toBe(false)
    expect(t.saved).toEqual([])
  })

  it('keeps at most 200 sessions in memory, and the oldest goes first', async () => {
    let n = 0
    const t = setup({
      createSession: async () => {
        n += 1
        return { sessionId: `s-${n}` }
      },
    })
    for (let i = 1; i <= MAX_DISCUSS_SESSIONS + 1; i += 1) {
      await t.discuss.request('demo', REQ)
      await t.discuss.start(`req-${i}`, { cwd: PROJECT, prompt: 'Go.' })
    }
    expect(t.discuss.isDiscussSession('s-1')).toBe(false)
    expect(t.discuss.isDiscussSession('s-2')).toBe(true)
    expect(t.discuss.isDiscussSession('s-201')).toBe(true)
    // Each id still goes to the saved list, which has its own cap.
    expect(t.saved).toHaveLength(201)
    t.discuss.carryOver('s-201', 's-202')
    expect(t.discuss.isDiscussSession('s-2')).toBe(false)
    expect(t.discuss.isDiscussSession('s-202')).toBe(true)
  })

  it('hides the new session of a hand-over of a Discuss session', async () => {
    const t = setup()
    await t.discuss.request('demo', REQ)
    await t.discuss.start('req-1', { cwd: PROJECT, prompt: 'Go.' })
    t.discuss.carryOver('session-1', 'session-9')
    t.discuss.carryOver('session-5', 'session-6')
    expect(t.discuss.isDiscussSession('session-9')).toBe(true)
    expect(t.discuss.isDiscussSession('session-6')).toBe(false)
    // The saved state decides for a session of an earlier run, so each hand-over goes there.
    expect(t.carried).toEqual([
      ['session-1', 'session-9'],
      ['session-5', 'session-6'],
    ])
  })
})

// Ruling P13: only the text of the user and the approved name of the module reach a session.
// A Hand over puts the session name into the note path and the first prompt of the new session,
// so the name never holds a text of the module, for example its title.
describe('the session name', () => {
  it('is the module name and the first words of the prompt of the user', () => {
    expect(discussSessionName('Demo', 'Plan the week')).toBe('Demo: Plan the week')
    // A prompt of more lines gives a name of one line.
    expect(discussSessionName('Demo', 'Plan\nthe\t  week\n\nnow')).toBe('Demo: Plan the week now')
  })

  it('ends after the last word that fits in 64 characters', () => {
    // "Demo:" has 5 characters, and each " word" has 5 more. 12 words give 65 characters.
    const name = discussSessionName('Demo', 'word '.repeat(20).trim())
    expect(name).toBe(`Demo:${' word'.repeat(11)}`)
    expect(discussSessionName('Demo', `${'A'.repeat(57)} B`)).toBe(`Demo: ${'A'.repeat(57)}`)
    // A word that ends at character 64 stays.
    expect(discussSessionName('Demo', `${'A'.repeat(56)} B C`)).toBe(`Demo: ${'A'.repeat(56)} B`)
  })

  it('cuts a first word that is too long, with no half emoji', () => {
    const name = discussSessionName('Demo', 'A'.repeat(80))
    expect(name).toBe(`Demo: ${'A'.repeat(58)}`)
    expect(name).toHaveLength(64)
    // "Demo: " is 6 characters. The emoji takes the characters 63 and 64, so it stays.
    expect(discussSessionName('Demo', `${'A'.repeat(56)}😀B`)).toBe(`Demo: ${'A'.repeat(56)}😀`)
    // Here the emoji would start at character 64, so the cut removes all of it.
    expect(discussSessionName('Demo', `${'A'.repeat(57)}😀`)).toBe(`Demo: ${'A'.repeat(57)}`)
  })

  it('is the name of the started session, and never holds the title of the module', async () => {
    const t = setup()
    const title = 'Zebra quokka narwhal'
    await t.discuss.request('demo', { cards: [{ label: 'Notes', text: CARD_TEXT }], title })
    await t.discuss.start('req-1', { cwd: PROJECT, prompt: 'Help me\u200B plan\n\nmy week.' })
    const name = t.created[0]?.name ?? ''
    expect(name).toBe('Demo: Help me plan my week.')
    for (const word of title.split(' ')) {
      expect(name.toLowerCase()).not.toContain(word.toLowerCase())
    }
    expect(name).not.toContain(CARD_TEXT)
    // Only the Discuss view shows the title.
    expect(t.opened[0]?.title).toBe(title)
  })

  it('is cut to 64 characters for a long prompt of the user', async () => {
    const t = setup()
    await t.discuss.request('demo', { title: 'T'.repeat(80) })
    await t.discuss.start('req-1', { cwd: PROJECT, prompt: 'P'.repeat(200) })
    expect(t.created[0]?.name).toBe(`Demo: ${'P'.repeat(58)}`)
    expect(t.created[0]?.prompt).toBe('P'.repeat(200))
  })
})
