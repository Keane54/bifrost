import {
  chmodSync,
  mkdirSync,
  mkdtempSync,
  realpathSync,
  rmSync,
  symlinkSync,
  writeFileSync,
} from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterEach, beforeEach, describe, expect, test } from 'vitest'
import { NO_STATUSLINE_SETTINGS } from '../../../src/main/actions/session-actions'
import {
  claudeSettingsFile,
  MAX_USER_SETTINGS_BYTES,
  REGISTRY_DOMAINS,
  REQUEST_SETTING_SOURCES,
  REQUEST_TOOLS,
  readUserSandboxProblem,
  requestPrompt,
  requestSessionArgs,
  requestSettings,
  SECRET_PATHS,
  userSandboxProblem,
} from '../../../src/main/reviews/request-session'
import {
  prSessionName,
  reviewSessionName,
  TEST_PREFIX,
} from '../../../src/main/reviews/review-session'
import {
  REASON_USER_FOLDERS,
  REASON_USER_SANDBOX,
  REASON_USER_SANDBOX_OFF,
  REASON_USER_SETTINGS_UNREADABLE,
} from '../../../src/main/reviews/round-text'
import { MAX_NAME } from '../../../src/shared/new-session'

const pr = { number: 7, owner: 'acme', repo: 'web' }
const VARIADIC = new Set(['--tools', '--add-dir', '--plugin-dir'])

// A temp folder with a clone folder and its input folder. Each path is a real path.
let dir: string
let CLONE: string
let IO: string

beforeEach(() => {
  dir = realpathSync(mkdtempSync(join(tmpdir(), 'bifrost-request-session-')))
  CLONE = join(dir, 'repos', 'acme', 'web')
  IO = join(CLONE, '.bifrost-io', '7')
  mkdirSync(IO, { recursive: true })
})

afterEach(() => {
  rmSync(dir, { force: true, recursive: true })
})

const args = (model: '' | 'haiku' = 'haiku', clone = CLONE, ioDir = IO) =>
  requestSessionArgs({
    clone,
    ioDir,
    model,
    name: 'web-7-request',
    pluginDir: '/skills',
    prompt: requestPrompt(join(ioDir, 'input.json')),
  })

const settings = (clone = CLONE) => JSON.parse(requestSettings(clone))

describe('request session args', () => {
  test('the args have the fixed flags, and the prompt is last after --name and its value', () => {
    expect(args()).toEqual([
      '--bg',
      '--setting-sources',
      'user',
      '--strict-mcp-config',
      '--tools',
      'Bash',
      'Read',
      'Glob',
      'Grep',
      'Edit',
      'Write',
      'Skill',
      '--permission-mode',
      'auto',
      '--add-dir',
      IO,
      '--plugin-dir',
      '/skills',
      '--settings',
      requestSettings(CLONE),
      '--model',
      'haiku',
      '--name',
      'web-7-request',
      `/bifrost-resolve-comments bifrost-input=${IO}/input.json`,
    ])
    // The session needs Bash and the CLAUDE.md of the repository.
    expect(args()).not.toContain('--restricted')
  })

  test('the setting sources are the user settings only', () => {
    expect(REQUEST_SETTING_SOURCES).toBe('user')
    const a = args()
    expect(a[a.indexOf('--setting-sources') + 1]).toBe('user')
  })

  test('no variadic flag comes right before the prompt', () => {
    for (const model of ['', 'haiku'] as const) {
      const a = args(model)
      expect(VARIADIC.has(a[a.length - 2] ?? '')).toBe(false)
      expect(a[a.length - 2]).toBe('web-7-request')
      expect(a[a.length - 3]).toBe('--name')
    }
  })

  test('the path rules use the real path of a linked clone folder', () => {
    symlinkSync(join(dir, 'repos'), join(dir, 'link'))
    const linked = join(dir, 'link', 'acme', 'web')
    const a = args('haiku', linked, join(linked, '.bifrost-io', '7'))
    const s = JSON.parse(a[a.indexOf('--settings') + 1] ?? '')
    expect(s.sandbox.filesystem.denyWrite).toEqual([join(CLONE, '.git')])
    expect(a[a.indexOf('--add-dir') + 1]).toBe(IO)
  })

  test('a clone or an input folder that is missing throws', () => {
    expect(() => args('haiku', join(dir, 'none'))).toThrow()
    expect(() => args('haiku', CLONE, join(CLONE, '.bifrost-io', '8'))).toThrow()
  })

  test('an empty model gives no --model', () => {
    expect(args('')).not.toContain('--model')
    expect(args('').length).toBe(args('haiku').length - 2)
  })

  test('the tools have no AskUserQuestion, WebFetch, WebSearch or Agent', () => {
    expect(REQUEST_TOOLS).toEqual(['Bash', 'Read', 'Glob', 'Grep', 'Edit', 'Write', 'Skill'])
    for (const tool of ['AskUserQuestion', 'WebFetch', 'WebSearch', 'Agent', 'Task']) {
      expect(REQUEST_TOOLS).not.toContain(tool)
    }
  })
})

describe('request session settings', () => {
  test(
    'the settings turn the sandbox on, turn the escape off, and deny git push, git commit, gh ' +
      'and the secret folders',
    () => {
      const s = settings()
      expect(s.statusLine).toEqual(JSON.parse(NO_STATUSLINE_SETTINGS).statusLine)
      expect(s.disableAllHooks).toBe(true)
      expect(s.sandbox).toMatchObject({
        allowUnsandboxedCommands: false,
        autoAllowBashIfSandboxed: true,
        enabled: true,
        network: { allowedDomains: [...REGISTRY_DOMAINS] },
      })
      expect(s.permissions.deny).toEqual([
        'Bash(git push:*)',
        'Bash(git commit:*)',
        'Bash(gh:*)',
        'WebFetch',
        'WebSearch',
        'Read(~/.ssh/**)',
        'Read(~/.gnupg/**)',
        'Read(~/.aws/**)',
        'Read(~/.config/gh/**)',
        'Read(~/.netrc)',
        'Read(~/.git-credentials)',
        'Read(~/.docker/**)',
        'Read(~/.kube/**)',
        'Read(~/Library/Keychains/**)',
        `Edit(/${CLONE}/.git/**)`,
        `Write(/${CLONE}/.git/**)`,
      ])
    },
  )

  test('the network allows only the listed registries, with the strict allow list', () => {
    expect(settings().sandbox.network).toEqual({
      allowedDomains: [...REGISTRY_DOMAINS],
      strictAllowlist: true,
    })
  })

  test('Bash, Edit and Write cannot write the .git folder of the clone', () => {
    expect(settings().sandbox.filesystem).toEqual({ denyWrite: [`${CLONE}/.git`] })
    // A rule path that starts with // is an absolute path.
    const deny: string[] = settings().permissions.deny
    expect(CLONE.startsWith('/')).toBe(true)
    expect(deny).toContain(`Edit(//${CLONE.slice(1)}/.git/**)`)
    expect(deny).toContain(`Write(//${CLONE.slice(1)}/.git/**)`)
    // One argument, also for a path with a quote in it.
    const odd = '/u/a "b"/repos/acme/web'
    expect(settings(odd).sandbox.filesystem.denyWrite).toEqual([`${odd}/.git`])
  })

  test('Edit and Write cannot write outside the working folders', () => {
    expect(settings().permissions.blockWritesOutsideWorkingDirectories).toBe(true)
  })

  test('a secret file gets a Read rule for itself, and a secret folder for all its files', () => {
    expect(SECRET_PATHS).toEqual([
      '~/.ssh',
      '~/.gnupg',
      '~/.aws',
      '~/.config/gh',
      '~/.netrc',
      '~/.git-credentials',
      '~/.docker',
      '~/.kube',
      '~/Library/Keychains',
    ])
    const deny: string[] = settings().permissions.deny
    for (const file of ['~/.netrc', '~/.git-credentials']) {
      expect(deny).toContain(`Read(${file})`)
      expect(deny).not.toContain(`Read(${file}/**)`)
    }
    for (const folder of SECRET_PATHS.filter(p => !p.endsWith('netrc') && !p.endsWith('ials'))) {
      expect(deny).toContain(`Read(${folder}/**)`)
    }
  })

  test('no allowed domain is a GitHub host or a proxy that fetches from any host', () => {
    expect(REGISTRY_DOMAINS).not.toContain('proxy.golang.org')
    expect(REGISTRY_DOMAINS).not.toContain('sum.golang.org')
    for (const domain of REGISTRY_DOMAINS) expect(domain).not.toMatch(/golang/)
    expect(REGISTRY_DOMAINS.length).toBeGreaterThan(0)
    for (const domain of REGISTRY_DOMAINS) expect(domain.toLowerCase()).not.toContain('github')
    expect(settings().sandbox.network.allowedDomains).toEqual([...REGISTRY_DOMAINS])
  })

  test('the settings have only the keys of the plan', () => {
    const s = settings()
    expect(Object.keys(s).sort()).toEqual([
      'disableAllHooks',
      'permissions',
      'sandbox',
      'statusLine',
    ])
    expect(Object.keys(s.sandbox).sort()).toEqual([
      'allowUnsandboxedCommands',
      'autoAllowBashIfSandboxed',
      'enabled',
      'filesystem',
      'network',
    ])
    expect(Object.keys(s.permissions).sort()).toEqual([
      'blockWritesOutsideWorkingDirectories',
      'deny',
    ])
  })
})

describe('request session name', () => {
  const title =
    'the name ends with -request, gets the owner on a clash and the test prefix in a test home'
  test(title, () => {
    expect(prSessionName(pr, 'request', new Set(), false)).toBe('web-7-request')
    expect(prSessionName(pr, 'request', new Set(['web-7-request']), false)).toBe(
      'acme-web-7-request',
    )
    expect(prSessionName(pr, 'request', new Set(), true)).toBe(`${TEST_PREFIX}web-7-request`)
    const long = { ...pr, repo: 'r'.repeat(200) }
    for (const testHome of [false, true]) {
      const name = prSessionName(long, 'request', new Set(), testHome)
      expect(name.length).toBe(MAX_NAME)
      expect(name.endsWith('-7-request')).toBe(true)
    }
  })

  test('the review name is the PR session name with review', () => {
    const names = new Set(['web-7-review'])
    for (const testHome of [false, true]) {
      expect(reviewSessionName(pr, names, testHome)).toBe(
        prSessionName(pr, 'review', names, testHome),
      )
    }
    expect(prSessionName(pr, 'review', new Set(), false)).toBe('web-7-review')
  })
})

describe('the sandbox check of the user settings', () => {
  const problem = (data: unknown): string | null => userSandboxProblem(JSON.stringify(data))

  test('settings with only the allowed keys are no problem', () => {
    expect(problem({})).toBeNull()
    expect(problem({ sandbox: {} })).toBeNull()
    expect(
      problem({
        model: 'opus',
        permissions: { additionalDirectories: [], allow: ['Bash(ls:*)'], deny: ['WebFetch'] },
        sandbox: { autoAllowBashIfSandboxed: false, enabled: true },
      }),
    ).toBeNull()
  })

  test.each([
    ['network.allowedDomains', { network: { allowedDomains: ['github.com'] } }],
    ['filesystem.allowWrite', { filesystem: { allowWrite: ['~/'] } }],
    ['network.allowUnixSockets', { network: { allowUnixSockets: ['/var/run/docker.sock'] } }],
    ['excludedCommands', { excludedCommands: ['git'] }],
    ['allowUnsandboxedCommands', { allowUnsandboxedCommands: true }],
    ['network.httpProxyPort', { network: { httpProxyPort: 8080 } }],
    ['a key that Bifrost does not know', { aNewKey: 1 }],
    ['an enabled value that is not true', { enabled: 'yes' }],
  ])('a sandbox with %s is refused', (_name, sandbox) => {
    expect(problem({ sandbox: { enabled: true, ...sandbox } })).toBe(REASON_USER_SANDBOX)
  })

  test('a sandbox value that is not an object is refused', () => {
    for (const sandbox of [true, null, 'on', []]) {
      expect(problem({ sandbox })).toBe(REASON_USER_SANDBOX)
    }
  })

  test('a sandbox that is off is refused', () => {
    expect(problem({ sandbox: { enabled: false } })).toBe(REASON_USER_SANDBOX_OFF)
  })

  test('more working folders are refused', () => {
    for (const more of [['~/other'], '~/other', {}]) {
      expect(problem({ permissions: { additionalDirectories: more } })).toBe(REASON_USER_FOLDERS)
    }
  })

  test('a text that is not valid JSON, or not an object, is refused', () => {
    for (const text of ['{', '', '[]', 'null', '1', '"x"']) {
      expect(userSandboxProblem(text)).toBe(REASON_USER_SETTINGS_UNREADABLE)
    }
  })

  test('a reason names no value of the file', () => {
    const host = 'secret-host.example'
    const reasons = [
      problem({ sandbox: { network: { allowedDomains: [host] } } }),
      problem({ permissions: { additionalDirectories: [host] } }),
    ]
    for (const reason of reasons) {
      expect(reason).not.toBeNull()
      expect(reason).not.toContain(host)
    }
  })
})

describe('readUserSandboxProblem', () => {
  const file = (): string => join(dir, 'settings.json')

  test('the file is settings.json in the .claude folder of the home folder', () => {
    expect(claudeSettingsFile('/h')).toBe('/h/.claude/settings.json')
  })

  test('a missing file is no problem', async () => {
    expect(await readUserSandboxProblem(file())).toBeNull()
  })

  test('a file with only allowed keys is no problem, also through a link', async () => {
    writeFileSync(file(), JSON.stringify({ sandbox: { enabled: true } }))
    expect(await readUserSandboxProblem(file())).toBeNull()
    symlinkSync(file(), join(dir, 'link.json'))
    expect(await readUserSandboxProblem(join(dir, 'link.json'))).toBeNull()
  })

  test('a file with a refused key gives its reason', async () => {
    writeFileSync(file(), JSON.stringify({ sandbox: { network: { allowedDomains: ['x.dev'] } } }))
    expect(await readUserSandboxProblem(file())).toBe(REASON_USER_SANDBOX)
  })

  test('a file over the cap is refused, and a file at the cap is read', async () => {
    const text = (size: number): string => `{"a":"${'x'.repeat(size - 8)}"}`
    expect(text(MAX_USER_SETTINGS_BYTES).length).toBe(MAX_USER_SETTINGS_BYTES)
    writeFileSync(file(), text(MAX_USER_SETTINGS_BYTES))
    expect(await readUserSandboxProblem(file())).toBeNull()
    writeFileSync(file(), text(MAX_USER_SETTINGS_BYTES + 1))
    expect(await readUserSandboxProblem(file())).toBe(REASON_USER_SETTINGS_UNREADABLE)
  })

  test('a file with bad JSON is refused', async () => {
    writeFileSync(file(), '{ "sandbox": ')
    expect(await readUserSandboxProblem(file())).toBe(REASON_USER_SETTINGS_UNREADABLE)
  })

  test('a folder in place of the file is refused', async () => {
    mkdirSync(file())
    expect(await readUserSandboxProblem(file())).toBe(REASON_USER_SETTINGS_UNREADABLE)
  })

  test.skipIf(process.getuid?.() === 0)('a file that cannot be read is refused', async () => {
    writeFileSync(file(), '{}')
    chmodSync(file(), 0o000)
    try {
      expect(await readUserSandboxProblem(file())).toBe(REASON_USER_SETTINGS_UNREADABLE)
    } finally {
      chmodSync(file(), 0o600)
    }
  })
})
