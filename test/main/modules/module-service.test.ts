// The install, the update and the removal of modules (plan Task 9, Modules design 7). The state
// store and the data store are real and write to a temporary folder. A fake git takes the place of
// git, so no test reaches the network or the gh login.
import { existsSync } from 'node:fs'
import { mkdir, mkdtemp, readdir, readFile, rm, writeFile } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import type { ExecResult } from '../../../src/main/claude/cli'
import { activeModule } from '../../../src/main/modules/heimdall'
import { createModuleDataStore, type ModuleDataStore } from '../../../src/main/modules/module-data'
import { hashModule } from '../../../src/main/modules/module-files'
import { modulesSnapshot } from '../../../src/main/modules/module-rows'
import {
  createModuleService,
  DEFAULT_DAILY_CAP,
  githubRepo,
  type ModuleService,
  type ModuleServiceDeps,
  moduleCodeRoot,
} from '../../../src/main/modules/module-service'
import {
  type ModuleEntry,
  type ModulesStateStore,
  moduleCodeDir,
  moduleDataFile,
  modulesStateFile,
  openModulesStateStore,
} from '../../../src/main/modules/module-state'
import { NO_PROMPT_CONFIG, type RepoGit } from '../../../src/main/reviews/repo-git'
import type { PermissionId } from '../../../src/shared/module-manifest'

const NO_REQUEST = 'refused: no such module request'
const DEV_ONLY = 'refused: developer modules need a development build'
const BAD_URL = 'refused: not a GitHub repository URL'
const INSTALLED = 'refused: module already installed'
const CHANGED = 'refused: the module changed'
const UNKNOWN = 'refused: unknown module'
const CLONE_FAILED = 'refused: the git clone failed'
const BAD = 'refused: bad module input'
const NOT_ALLOWED = 'refused: not allowed for this module'
const BAD_CAP = 'refused: bad daily cap'
const UNKNOWN_MODEL = 'refused: unknown model'

interface ManifestOptions {
  id?: string
  version?: string
  permissions?: PermissionId[]
  suggests?: { model: string | null; dailyCap: number | null }
  minBifrost?: string
}

function manifest(o: ManifestOptions = {}): Record<string, unknown> {
  return {
    description: 'Says hello.',
    id: o.id ?? 'hello',
    minBifrost: o.minBifrost ?? '0.1.0',
    name: 'Hello',
    panels: [{ entry: 'panels/main.html', icon: 'star', id: 'main', title: 'Hello board' }],
    permissions: (o.permissions ?? ['notify']).map(id => ({ id, reason: `Reason for ${id}.` })),
    suggests: o.suggests ?? { dailyCap: null, model: null },
    version: o.version ?? '1.0.0',
  }
}

// Write a module folder with its manifest, a panel page and a script.
async function writeModule(dir: string, o: ManifestOptions = {}, script = 'one'): Promise<void> {
  await mkdir(join(dir, 'panels'), { recursive: true })
  await writeFile(join(dir, 'bifrost-module.json'), JSON.stringify(manifest(o)))
  await writeFile(join(dir, 'panels', 'main.html'), '<p>hello</p>')
  await writeFile(join(dir, 'panels', 'main.js'), `// ${script}`)
}

let root = ''
let home = ''
let source = ''

beforeEach(async () => {
  root = await mkdtemp(join(tmpdir(), 'bifrost-module-service-'))
  home = join(root, 'bifrost')
  source = join(root, 'source')
  await mkdir(home, { recursive: true })
  await writeModule(source)
})

afterEach(async () => {
  vi.useRealTimers()
  await rm(root, { force: true, recursive: true })
})

const ok: ExecResult = { code: 0, stderr: '', stdout: '' }

// A fake git. A clone writes the module of the test into the target folder, with a .git folder.
function fakeGit(module: ManifestOptions = {}, result: ExecResult = ok) {
  const calls: { args: string[]; cwd?: string }[] = []
  const git: RepoGit = {
    run: vi.fn(async (args: string[], opts?: { cwd?: string }) => {
      calls.push({ args, cwd: opts?.cwd })
      const target = args[args.length - 1]
      if (result.code === 0) {
        await writeModule(target, module, 'from git')
        await mkdir(join(target, '.git'), { recursive: true })
        await writeFile(join(target, '.git', 'config'), '[core]')
      }
      return result
    }),
  }
  return { calls, git }
}

interface Setup {
  service: ModuleService
  store: ModulesStateStore
  data: ModuleDataStore
  cancel: ReturnType<typeof vi.fn>
  flush: ReturnType<typeof vi.fn>
  drop: ReturnType<typeof vi.fn>
  pick: ReturnType<typeof vi.fn>
  git: ReturnType<typeof fakeGit>
}

async function setup(over: Partial<ModuleServiceDeps> = {}, git = fakeGit()): Promise<Setup> {
  const store = await openModulesStateStore(modulesStateFile(home))
  const data = createModuleDataStore(home)
  const flush = vi.fn((id?: string) => data.flush(id))
  const drop = vi.fn((id: string) => data.drop(id))
  const cancel = vi.fn()
  const pick = vi.fn(async () => source)
  const service = createModuleService({
    bifrostHome: home,
    bifrostVersion: '0.5.0',
    data: { drop, flush },
    devAllowed: true,
    git: git.git,
    jobs: { cancel },
    log: () => {},
    pickFolder: pick,
    remoteBase: 'https://github.com/',
    store,
    ...over,
  })
  return { cancel, data, drop, flush, git, pick, service, store }
}

// Install the source folder and allow it.
async function installed(t: Setup): Promise<void> {
  const approval = await t.service.installFolder()
  if (approval === null) throw new Error('No approval.')
  await t.service.allow(approval.requestId)
}

const current = (id = 'hello') => moduleCodeDir(home, id, 'current')
const next = (id = 'hello') => moduleCodeDir(home, id, 'next')

describe('githubRepo', () => {
  it('accepts only https://github.com/<owner>/<repo>, with or without .git', () => {
    expect(githubRepo('https://github.com/someone/standup-timer')).toEqual({
      owner: 'someone',
      repo: 'standup-timer',
    })
    expect(githubRepo('https://github.com/Some-One/Repo.Name_1.git')).toEqual({
      owner: 'Some-One',
      repo: 'Repo.Name_1',
    })
  })

  it('refuses every other form', () => {
    for (const bad of [
      'http://github.com/a/b',
      'https://github.com/a',
      'https://github.com/a/b/c',
      'https://github.com/a/b/',
      'https://github.com/a/b?x=1',
      'https://github.com/a/b#x',
      'https://user@github.com/a/b',
      'https://github.com.evil.example/a/b',
      'https://gitlab.com/a/b',
      'git@github.com:a/b.git',
      'ssh://git@github.com/a/b',
      'file:///tmp/a/b',
      '--upload-pack=x',
      'https://github.com/-a/b',
      'https://github.com/a/..',
      'https://github.com/a/.',
      'https://github.com/a/.git',
      ' https://github.com/a/b',
      'https://github.com/a/b ',
      'https://github.com/a/b\n',
      '',
    ]) {
      expect(githubRepo(bad), bad).toBeNull()
    }
    expect(githubRepo(42)).toBeNull()
  })
})

describe('moduleCodeRoot', () => {
  it('serves a dev module from its folder, and each other module from its copy', () => {
    const of = (source: ModuleEntry['source']) => ({ source }) as ModuleEntry
    expect(moduleCodeRoot('/h', 'hello', undefined)).toBe('/h/modules/hello/current')
    expect(moduleCodeRoot('/h', 'hello', of({ kind: 'folder', path: '/src/x' }))).toBe(
      '/h/modules/hello/current',
    )
    expect(moduleCodeRoot('/h', 'hello', of({ kind: 'dev', path: '/src/x' }))).toBe('/src/x')
  })
})

describe('install from a folder', () => {
  it('needs the approval before the module runs', async () => {
    const t = await setup()
    const approval = await t.service.installFolder()
    expect(t.pick).toHaveBeenCalledTimes(1)
    expect(approval).toMatchObject({
      description: 'Says hello.',
      fromVersion: null,
      icon: 'star',
      kind: 'install',
      moduleId: 'hello',
      name: 'Hello',
      permissions: [{ added: false, id: 'notify', reason: 'Reason for notify.' }],
      source,
      sourceKind: 'folder',
      tier: 'standard',
      version: '1.0.0',
    })
    // Before Allow: no entry, so the module does not run, and the protocol serves nothing.
    expect(t.store.get().modules).toEqual({})
    expect(activeModule(t.store.get(), 'hello', true)).toBeNull()
    expect(existsSync(next())).toBe(true)
    expect(existsSync(current())).toBe(false)

    await t.service.allow(approval?.requestId ?? '')
    const entry = t.store.get().modules.hello
    expect(entry).toMatchObject({
      dailyCap: DEFAULT_DAILY_CAP,
      enabled: true,
      granted: ['notify'],
      jobs: { count: 0, day: '' },
      model: '',
      pendingUpdate: null,
      source: { kind: 'folder', path: source },
    })
    expect(entry.hash).toBe(await hashModule(current()))
    expect(existsSync(next())).toBe(false)
    expect(await readFile(join(current(), 'panels', 'main.js'), 'utf8')).toBe('// one')
    expect(activeModule(t.store.get(), 'hello', true)).not.toBeNull()
  })

  it('grants all requested permissions and uses the suggested model and cap', async () => {
    await writeModule(source, {
      permissions: ['notify', 'claude-jobs', 'claude-jobs-auto'],
      suggests: { dailyCap: 7, model: 'haiku' },
    })
    const t = await setup()
    await installed(t)
    expect(t.store.get().modules.hello).toMatchObject({
      dailyCap: 7,
      granted: ['notify', 'claude-jobs', 'claude-jobs-auto'],
      model: 'haiku',
    })
  })

  it('gives null and changes nothing when the user closes the dialog', async () => {
    const t = await setup({ pickFolder: async () => null })
    await expect(t.service.installFolder()).resolves.toBeNull()
    expect(existsSync(join(home, 'modules', 'hello'))).toBe(false)
  })

  it('deletes the copy on Cancel', async () => {
    const t = await setup()
    const approval = await t.service.installFolder()
    await t.service.decline(approval?.requestId ?? '')
    expect(existsSync(next())).toBe(false)
    expect(t.store.get().modules).toEqual({})
    await expect(t.service.allow(approval?.requestId ?? '')).rejects.toThrow(NO_REQUEST)
  })

  it('refuses a bad manifest with the reason of the parser', async () => {
    await writeModule(source, { id: 'Bad id' })
    const t = await setup()
    await expect(t.service.installFolder()).rejects.toThrow('The module id is not valid.')
    expect(existsSync(join(home, 'modules'))).toBe(false)
  })

  it('refuses a folder with a symbolic link and leaves no copy', async () => {
    const { symlink } = await import('node:fs/promises')
    await symlink('/etc/hosts', join(source, 'panels', 'hosts'))
    const t = await setup()
    await expect(t.service.installFolder()).rejects.toThrow(/symbolic link/)
    expect(existsSync(next())).toBe(false)
  })

  it('refuses a module that needs a newer Bifrost', async () => {
    await writeModule(source, { minBifrost: '0.6.0' })
    const t = await setup()
    await expect(t.service.installFolder()).rejects.toThrow(
      'This module needs a newer version of Bifrost.',
    )
  })

  it('refuses a module that is already installed', async () => {
    const t = await setup()
    await installed(t)
    await expect(t.service.installFolder()).rejects.toThrow(INSTALLED)
  })

  it('replaces an open install request with the next one', async () => {
    const t = await setup()
    const first = await t.service.installFolder()
    const second = await t.service.installFolder()
    expect(second?.requestId).not.toBe(first?.requestId)
    await expect(t.service.allow(first?.requestId ?? '')).rejects.toThrow(NO_REQUEST)
    await t.service.allow(second?.requestId ?? '')
    expect(t.store.get().modules.hello).toBeDefined()
  })

  it('refuses the approval when the copy changed after the request', async () => {
    const t = await setup()
    const approval = await t.service.installFolder()
    await writeFile(join(next(), 'panels', 'main.js'), '// changed')
    await expect(t.service.allow(approval?.requestId ?? '')).rejects.toThrow(CHANGED)
    expect(t.store.get().modules).toEqual({})
  })

  it('uses an approval request one time, also when the save fails', async () => {
    const real = await openModulesStateStore(modulesStateFile(home))
    let fail = false
    const t = await setup({
      store: {
        change: fn => {
          if (!fail) return real.change(fn)
          fail = false
          return Promise.reject(new Error('The disk is full.'))
        },
        get: () => real.get(),
      },
    })
    const approval = await t.service.installFolder()
    fail = true
    await expect(t.service.allow(approval?.requestId ?? '')).rejects.toThrow(
      'refused: module call failed',
    )
    await expect(t.service.allow(approval?.requestId ?? '')).rejects.toThrow(NO_REQUEST)
    expect(real.get().modules).toEqual({})
  })

  it('refuses an unknown request id', async () => {
    const t = await setup()
    await expect(t.service.allow('nope')).rejects.toThrow(NO_REQUEST)
    await expect(t.service.allow(42)).rejects.toThrow(NO_REQUEST)
  })
})

describe('install from a git repo', () => {
  it('refuses a URL that is not https://github.com/<owner>/<repo> and runs no git', async () => {
    const t = await setup()
    for (const bad of ['http://github.com/a/b', 'https://gitlab.com/a/b', '--upload-pack=x', 7]) {
      await expect(t.service.installGit(bad)).rejects.toThrow(BAD_URL)
    }
    expect(t.git.calls).toHaveLength(0)
  })

  it('clones with NO_PROMPT_CONFIG, copies without .git, and saves the GitHub URL', async () => {
    const git = fakeGit({ version: '2.0.0' })
    const t = await setup({}, git)
    const approval = await t.service.installGit('https://github.com/Some-One/Hello.git')
    expect(git.calls).toHaveLength(1)
    const { args } = git.calls[0]
    expect(args.slice(0, NO_PROMPT_CONFIG.length)).toEqual([...NO_PROMPT_CONFIG])
    expect(args).toContain('clone')
    expect(args).toContain('--depth')
    const dash = args.indexOf('--')
    expect(dash).toBeGreaterThan(0)
    expect(args[dash + 1]).toBe('https://github.com/some-one/hello.git')
    expect(approval).toMatchObject({
      source: 'https://github.com/Some-One/Hello',
      sourceKind: 'git',
      version: '2.0.0',
    })
    // The temporary clone is gone, and the copy has no .git folder.
    expect(existsSync(join(next(), '.git'))).toBe(false)
    const incoming = join(home, 'modules', '.incoming')
    expect(existsSync(incoming) ? await readdir(incoming) : []).toEqual([])
    await t.service.allow(approval.requestId)
    expect(t.store.get().modules.hello.source).toEqual({
      kind: 'git',
      url: 'https://github.com/Some-One/Hello',
    })
  })

  it('uses the remote base of a test home', async () => {
    const git = fakeGit()
    const t = await setup({ remoteBase: 'file:///tmp/T/git-remotes/' }, git)
    await t.service.installGit('https://github.com/a/b')
    const { args } = git.calls[0]
    expect(args[args.indexOf('--') + 1]).toBe('file:///tmp/T/git-remotes/a/b.git')
  })

  it('refuses when the clone fails, and leaves nothing', async () => {
    const git = fakeGit({}, { code: 128, stderr: 'fatal: no', stdout: '' })
    const t = await setup({}, git)
    await expect(t.service.installGit('https://github.com/a/b')).rejects.toThrow(CLONE_FAILED)
    expect(existsSync(join(home, 'modules', 'hello'))).toBe(false)
    const incoming = join(home, 'modules', '.incoming')
    expect(existsSync(incoming) ? await readdir(incoming) : []).toEqual([])
  })
})

describe('developer mode', () => {
  it('refuses installDev when the app is packaged, with no dialog', async () => {
    const t = await setup({ devAllowed: false })
    await expect(t.service.installDev()).rejects.toThrow(DEV_ONLY)
    expect(t.pick).not.toHaveBeenCalled()
  })

  it('uses the folder in place after the approval', async () => {
    const t = await setup()
    const approval = await t.service.installDev()
    expect(approval).toMatchObject({ kind: 'install', source, sourceKind: 'dev' })
    expect(existsSync(next())).toBe(false)
    await t.service.allow(approval?.requestId ?? '')
    expect(t.store.get().modules.hello.source).toEqual({ kind: 'dev', path: source })
    expect(existsSync(current())).toBe(false)
  })
})

describe('updates', () => {
  it('reports no change when the files are the same', async () => {
    const t = await setup()
    await installed(t)
    const before = t.store.get().modules.hello
    await expect(t.service.checkUpdates()).resolves.toEqual([
      { id: 'hello', name: 'Hello', outcome: 'same', version: '1.0.0' },
    ])
    expect(t.store.get().modules.hello).toEqual(before)
    expect(existsSync(next())).toBe(false)
  })

  it('swaps at once for changed code with the same or fewer permissions', async () => {
    await writeModule(source, { permissions: ['notify', 'read-usage'] })
    const t = await setup()
    await installed(t)
    await writeModule(source, { permissions: ['notify'], version: '1.1.0' }, 'two')
    await expect(t.service.checkUpdates()).resolves.toEqual([
      { id: 'hello', name: 'Hello', outcome: 'updated', version: '1.1.0' },
    ])
    const entry = t.store.get().modules.hello
    expect(entry.manifest.version).toBe('1.1.0')
    expect(entry.granted).toEqual(['notify'])
    expect(entry.pendingUpdate).toBeNull()
    expect(entry.hash).toBe(await hashModule(current()))
    expect(await readFile(join(current(), 'panels', 'main.js'), 'utf8')).toBe('// two')
    expect(t.flush).toHaveBeenCalledWith('hello')
    // An update keeps the storage of the module.
    expect(t.drop).not.toHaveBeenCalled()
  })

  it('keeps the old code and sets pendingUpdate for a new permission', async () => {
    const t = await setup()
    await installed(t)
    const before = t.store.get().modules.hello
    await writeModule(source, { permissions: ['notify', 'read-usage'], version: '1.3.0' }, 'two')
    await expect(t.service.checkUpdates()).resolves.toEqual([
      { id: 'hello', name: 'Hello', outcome: 'waiting', version: '1.3.0' },
    ])
    const entry = t.store.get().modules.hello
    expect(entry.manifest).toEqual(before.manifest)
    expect(entry.granted).toEqual(['notify'])
    expect(entry.hash).toBe(before.hash)
    expect(entry.pendingUpdate?.manifest.version).toBe('1.3.0')
    expect(await readFile(join(current(), 'panels', 'main.js'), 'utf8')).toBe('// one')
    const row = modulesSnapshot(t.store.get(), { devAllowed: true, today: '2026-11-14' }).modules[0]
    expect(row.version).toBe('1.0.0')
    expect(row.pendingUpdate).toEqual({
      added: [{ id: 'read-usage', reason: 'Reason for read-usage.' }],
      version: '1.3.0',
    })
  })

  it('swaps and grants the new permission when the user allows the update', async () => {
    const t = await setup()
    await installed(t)
    await writeModule(source, { permissions: ['notify', 'read-usage'], version: '1.3.0' }, 'two')
    await t.service.checkUpdates()
    const approval = await t.service.reviewUpdate('hello')
    expect(approval).toMatchObject({
      fromVersion: '1.0.0',
      kind: 'update',
      moduleId: 'hello',
      permissions: [
        { added: false, id: 'notify', reason: 'Reason for notify.' },
        { added: true, id: 'read-usage', reason: 'Reason for read-usage.' },
      ],
      version: '1.3.0',
    })
    await t.service.allow(approval.requestId)
    const entry = t.store.get().modules.hello
    expect(entry.manifest.version).toBe('1.3.0')
    expect(entry.granted).toEqual(['notify', 'read-usage'])
    expect(entry.pendingUpdate).toBeNull()
    expect(await readFile(join(current(), 'panels', 'main.js'), 'utf8')).toBe('// two')
    expect(existsSync(next())).toBe(false)
    expect(t.drop).not.toHaveBeenCalled()
  })

  it('refuses Allow when the waiting copy changed, and forgets the update', async () => {
    const t = await setup()
    await installed(t)
    await writeModule(source, { permissions: ['notify', 'read-usage'], version: '1.3.0' }, 'two')
    await t.service.checkUpdates()
    const approval = await t.service.reviewUpdate('hello')
    await writeFile(join(next(), 'panels', 'main.js'), '// changed')
    await expect(t.service.allow(approval.requestId)).rejects.toThrow(CHANGED)
    const entry = t.store.get().modules.hello
    expect(entry.manifest.version).toBe('1.0.0')
    expect(entry.granted).toEqual(['notify'])
    expect(entry.pendingUpdate).toBeNull()
    expect(existsSync(next())).toBe(false)
    expect(await readFile(join(current(), 'panels', 'main.js'), 'utf8')).toBe('// one')
  })

  it('keeps a removed permission removed after an update', async () => {
    await writeModule(source, { permissions: ['notify', 'read-usage'] })
    const t = await setup()
    await installed(t)
    await t.service.revoke('hello', 'notify')
    await writeModule(
      source,
      { permissions: ['notify', 'read-usage', 'read-sessions'], version: '1.1.0' },
      'two',
    )
    await t.service.checkUpdates()
    await t.service.allow((await t.service.reviewUpdate('hello')).requestId)
    expect(t.store.get().modules.hello.granted).toEqual(['read-usage', 'read-sessions'])
  })

  it('forgets the waiting update on Stay, and keeps the old code', async () => {
    const t = await setup()
    await installed(t)
    await writeModule(source, { permissions: ['notify', 'read-usage'], version: '1.3.0' }, 'two')
    await t.service.checkUpdates()
    const approval = await t.service.reviewUpdate('hello')
    await t.service.decline(approval.requestId)
    expect(t.store.get().modules.hello.pendingUpdate).toBeNull()
    expect(t.store.get().modules.hello.manifest.version).toBe('1.0.0')
    expect(existsSync(next())).toBe(false)
  })

  it('refuses a review of a module with no waiting update', async () => {
    const t = await setup()
    await installed(t)
    await expect(t.service.reviewUpdate('hello')).rejects.toThrow(NO_REQUEST)
    await expect(t.service.reviewUpdate('gone')).rejects.toThrow(UNKNOWN)
  })

  it('refuses an old review after a newer check', async () => {
    const t = await setup()
    await installed(t)
    await writeModule(source, { permissions: ['notify', 'read-usage'], version: '1.3.0' }, 'two')
    await t.service.checkUpdates()
    const old = await t.service.reviewUpdate('hello')
    await writeModule(source, { permissions: ['notify', 'discuss'], version: '1.4.0' }, 'three')
    await t.service.checkUpdates()
    await expect(t.service.allow(old.requestId)).rejects.toThrow(NO_REQUEST)
    expect(t.store.get().modules.hello.manifest.version).toBe('1.0.0')
  })

  it('updates a git module from a new clone', async () => {
    const git = fakeGit({ version: '1.0.0' })
    const t = await setup({}, git)
    await t.service.allow((await t.service.installGit('https://github.com/a/hello')).requestId)
    const later = fakeGit({ version: '1.2.0' })
    const t2 = await setup({}, later)
    await expect(t2.service.checkUpdates()).resolves.toEqual([
      { id: 'hello', name: 'Hello', outcome: 'updated', version: '1.2.0' },
    ])
    expect(later.calls[0].args.slice(0, NO_PROMPT_CONFIG.length)).toEqual([...NO_PROMPT_CONFIG])
    expect(existsSync(join(current(), '.git'))).toBe(false)
  })

  it('reports a failed check of one module and goes on', async () => {
    const t = await setup()
    await installed(t)
    await rm(source, { force: true, recursive: true })
    const [result] = await t.service.checkUpdates()
    expect(result).toMatchObject({ id: 'hello', outcome: 'failed' })
    expect(result.outcome === 'failed' ? result.reason : null).toMatch(/can't find the folder/)
    expect(t.store.get().modules.hello.manifest.version).toBe('1.0.0')
  })

  it('refuses a new version with another module id, and changes nothing', async () => {
    const t = await setup()
    await installed(t)
    const before = t.store.get().modules.hello
    await writeModule(source, { id: 'other', version: '1.1.0' }, 'two')
    await expect(t.service.checkUpdates()).resolves.toEqual([
      {
        id: 'hello',
        name: 'Hello',
        outcome: 'failed',
        reason: 'The new version has another module id.',
      },
    ])
    expect(t.store.get().modules.hello).toEqual(before)
    expect(existsSync(next())).toBe(false)
    expect(existsSync(next('other'))).toBe(false)
  })

  it('forgets a waiting update when a new check removes its copy and then fails', async () => {
    const t = await setup()
    await installed(t)
    await writeModule(source, { permissions: ['notify', 'read-usage'], version: '1.3.0' }, 'two')
    await t.service.checkUpdates()
    await writeModule(
      source,
      { minBifrost: '9.0.0', permissions: ['notify', 'read-usage'], version: '1.4.0' },
      'three',
    )
    await expect(t.service.checkUpdates()).resolves.toEqual([
      {
        id: 'hello',
        name: 'Hello',
        outcome: 'failed',
        reason: 'This module needs a newer version of Bifrost.',
      },
    ])
    expect(t.store.get().modules.hello.pendingUpdate).toBeNull()
    expect(existsSync(next())).toBe(false)
    expect(await readFile(join(current(), 'panels', 'main.js'), 'utf8')).toBe('// one')
  })

  it('forgets a waiting update when the new copy fails', async () => {
    const { symlink } = await import('node:fs/promises')
    const t = await setup()
    await installed(t)
    await writeModule(source, { permissions: ['notify', 'read-usage'], version: '1.3.0' }, 'two')
    await t.service.checkUpdates()
    await symlink('/etc/hosts', join(source, 'panels', 'hosts'))
    const [result] = await t.service.checkUpdates()
    expect(result).toMatchObject({ id: 'hello', outcome: 'failed' })
    expect(t.store.get().modules.hello.pendingUpdate).toBeNull()
    expect(existsSync(next())).toBe(false)
  })

  it('keeps a waiting update when the source folder is gone, because its copy stays', async () => {
    const t = await setup()
    await installed(t)
    await writeModule(source, { permissions: ['notify', 'read-usage'], version: '1.3.0' }, 'two')
    await t.service.checkUpdates()
    await rm(source, { force: true, recursive: true })
    const [result] = await t.service.checkUpdates()
    expect(result).toMatchObject({ id: 'hello', outcome: 'failed' })
    expect(t.store.get().modules.hello.pendingUpdate?.manifest.version).toBe('1.3.0')
    await t.service.allow((await t.service.reviewUpdate('hello')).requestId)
    expect(t.store.get().modules.hello.manifest.version).toBe('1.3.0')
  })

  it('updates a dev module in place: the manifest only, with no copy', async () => {
    const t = await setup()
    const approval = await t.service.installDev()
    await t.service.allow(approval?.requestId ?? '')
    await writeModule(source, { version: '1.1.0' }, 'two')
    await expect(t.service.checkUpdates()).resolves.toEqual([
      { id: 'hello', name: 'Hello', outcome: 'updated', version: '1.1.0' },
    ])
    expect(t.store.get().modules.hello.manifest.version).toBe('1.1.0')
    await writeModule(source, { permissions: ['notify', 'read-usage'], version: '1.2.0' }, 'three')
    await expect(t.service.checkUpdates()).resolves.toEqual([
      { id: 'hello', name: 'Hello', outcome: 'waiting', version: '1.2.0' },
    ])
    expect(t.store.get().modules.hello.granted).toEqual(['notify'])
    await t.service.allow((await t.service.reviewUpdate('hello')).requestId)
    const entry = t.store.get().modules.hello
    expect(entry.manifest.version).toBe('1.2.0')
    expect(entry.granted).toEqual(['notify', 'read-usage'])
    expect(entry.source).toEqual({ kind: 'dev', path: source })
    expect(existsSync(current())).toBe(false)
    expect(existsSync(next())).toBe(false)
    expect(t.drop).not.toHaveBeenCalled()
  })

  it('skips a dev module in a packaged app', async () => {
    const t = await setup()
    const approval = await t.service.installDev()
    await t.service.allow(approval?.requestId ?? '')
    const before = t.store.get().modules.hello
    await writeModule(source, { permissions: ['notify', 'read-usage'], version: '1.2.0' }, 'two')
    const packaged = await setup({ devAllowed: false })
    await expect(packaged.service.checkUpdates()).resolves.toEqual([])
    expect(packaged.store.get().modules.hello).toEqual(before)
  })
})

describe('permissions, model and cap', () => {
  it('removes a revoked permission from granted only', async () => {
    await writeModule(source, { permissions: ['notify', 'read-usage'] })
    const t = await setup()
    await installed(t)
    const before = t.store.get().modules.hello
    await t.service.revoke('hello', 'read-usage')
    const entry = t.store.get().modules.hello
    expect(entry.granted).toEqual(['notify'])
    expect(entry.manifest).toEqual(before.manifest)
    expect(entry.enabled).toBe(true)
    expect(t.cancel).not.toHaveBeenCalled()
  })

  it('cancels waiting jobs for claude-jobs, not for claude-jobs-auto', async () => {
    await writeModule(source, { permissions: ['claude-jobs', 'claude-jobs-auto'] })
    const t = await setup()
    await installed(t)
    // Without claude-jobs-auto, a job with no click goes back to wait for Refresh.
    await t.service.revoke('hello', 'claude-jobs-auto')
    expect(t.cancel).not.toHaveBeenCalled()
    await t.service.revoke('hello', 'claude-jobs')
    expect(t.cancel).toHaveBeenCalledWith('hello')
    expect(t.store.get().modules.hello.granted).toEqual([])
  })

  it('gives back a requested permission, and refuses one that was not asked for', async () => {
    const t = await setup()
    await installed(t)
    await t.service.revoke('hello', 'notify')
    await t.service.grant('hello', 'notify')
    expect(t.store.get().modules.hello.granted).toEqual(['notify'])
    await expect(t.service.grant('hello', 'read-usage')).rejects.toThrow(NOT_ALLOWED)
    await expect(t.service.revoke('hello', 'slack-read')).rejects.toThrow(BAD)
  })

  it('sets the model and the daily cap, and refuses bad values', async () => {
    const t = await setup()
    await installed(t)
    await t.service.setModel('hello', 'opus')
    await t.service.setCap('hello', 12)
    expect(t.store.get().modules.hello).toMatchObject({ dailyCap: 12, model: 'opus' })
    await expect(t.service.setModel('hello', 'gpt')).rejects.toThrow(UNKNOWN_MODEL)
    for (const bad of [0, 501, 1.5, '3', Number.NaN]) {
      await expect(t.service.setCap('hello', bad), String(bad)).rejects.toThrow(BAD_CAP)
    }
    await expect(t.service.setCap('gone', 3)).rejects.toThrow(UNKNOWN)
  })

  it('turns a module off: cancels its waiting jobs and writes its storage', async () => {
    const t = await setup()
    await installed(t)
    await t.service.setEnabled('hello', false)
    expect(t.store.get().modules.hello.enabled).toBe(false)
    expect(t.cancel).toHaveBeenCalledWith('hello')
    expect(t.flush).toHaveBeenCalledWith('hello')
    await t.service.setEnabled('hello', true)
    expect(t.store.get().modules.hello.enabled).toBe(true)
    await expect(t.service.setEnabled('hello', 'no')).rejects.toThrow(BAD)
  })
})

describe('remove', () => {
  it('deletes the code and the data file, and no late write makes the file again', async () => {
    const t = await setup()
    await installed(t)
    await t.data.set('hello', 'a', '1')
    await t.data.flush('hello')
    expect(existsSync(moduleDataFile(home, 'hello'))).toBe(true)
    // A set after the last write waits for the write gap. The removal drops it.
    await t.data.set('hello', 'b', '2')
    await t.service.remove('hello')
    expect(t.cancel).toHaveBeenCalledWith('hello')
    expect(t.drop).toHaveBeenCalledWith('hello')
    expect(t.store.get().modules).toEqual({})
    expect(existsSync(join(home, 'modules', 'hello'))).toBe(false)
    expect(existsSync(moduleDataFile(home, 'hello'))).toBe(false)
    await new Promise(resolve => setTimeout(resolve, 1200))
    expect(existsSync(moduleDataFile(home, 'hello'))).toBe(false)
  })

  it('refuses an unknown module', async () => {
    const t = await setup()
    await expect(t.service.remove('gone')).rejects.toThrow(UNKNOWN)
    await expect(t.service.remove('../x')).rejects.toThrow(UNKNOWN)
  })
})

describe('cleanup', () => {
  it('puts the old code back when a swap stopped between its two renames', async () => {
    const { rename } = await import('node:fs/promises')
    const t = await setup()
    await installed(t)
    const old = join(home, 'modules', 'hello', 'old')
    await rename(current(), old)
    await t.service.cleanup()
    expect(existsSync(old)).toBe(false)
    expect(await readFile(join(current(), 'panels', 'main.js'), 'utf8')).toBe('// one')
    expect(await hashModule(current())).toBe(t.store.get().modules.hello.hash)
  })

  it('removes stale copies and keeps the code that runs and a waiting update', async () => {
    const t = await setup()
    await installed(t)
    await writeModule(source, { permissions: ['notify', 'read-usage'], version: '1.3.0' }, 'two')
    await t.service.checkUpdates()
    await mkdir(join(home, 'modules', 'stale', 'next'), { recursive: true })
    await mkdir(join(home, 'modules', '.incoming', 'x'), { recursive: true })
    await t.service.cleanup()
    expect(existsSync(next())).toBe(true)
    expect(existsSync(current())).toBe(true)
    expect(existsSync(join(home, 'modules', 'stale', 'next'))).toBe(false)
    expect(existsSync(join(home, 'modules', '.incoming'))).toBe(false)
    expect(existsSync(modulesStateFile(home))).toBe(true)
  })
})
