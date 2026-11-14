// Source checks of the module bridge wiring. ipc.ts, index.ts and the preload import Electron, so
// a unit test cannot load them. These checks read their text.
import { readFileSync } from 'node:fs'
import { join } from 'node:path'
import { describe, expect, it } from 'vitest'

function flat(path: string): string {
  return readFileSync(join(__dirname, '../../..', path), 'utf8').replace(/\s+/g, ' ')
}

const ipc = flat('src/main/ipc.ts')
const index = flat('src/main/index.ts')
const preload = flat('src/preload/index.ts')

describe('the module bridge wiring', () => {
  // fromPage refuses a frame inside the page (test/main/page-guard.test.ts).
  it('handles modules:call once, through fromPage', () => {
    expect(ipc.split("ipcMain.handle('modules:call'")).toHaveLength(2)
    expect(ipc).toContain(
      "ipcMain.handle('modules:call', (e, moduleId: unknown, name: unknown, args: unknown) => " +
        'fromPage(e, () => moduleCall(moduleId, name, args)), )',
    )
  })

  it('writes the module storage at the quit, and looks up PRs with the Info panel cache', () => {
    expect(ipc).toMatch(
      /export function stopRegistry\(\): void \{[^}]*moduleDataStore\?\.flushSync\(\)/,
    )
    expect(ipc).toContain('pr: row => prs.lookup(row.cwd, row.branch)')
  })

  it('sends module events on modules:event', () => {
    expect(ipc).toContain("send('modules:event', moduleId, name, data)")
  })

  it('gives modules:call and modules:event to the page', () => {
    expect(preload).toContain(
      "call: (moduleId, name, args) => invoke('modules:call', moduleId, name, args)",
    )
    expect(preload).toContain("onEvent: cb => subscribe('modules:event', cb)")
  })

  it('serves the built client library from the folder of the main build', () => {
    expect(index).toContain('apiScript: moduleApiScript')
    expect(index).toContain('readFile(moduleApiFile(import.meta.dirname))')
  })
})

describe('the module rows wiring (plan Task 6)', () => {
  it('handles modules:snapshot once, through fromPage, after the state opens', () => {
    expect(ipc.split("ipcMain.handle('modules:snapshot'")).toHaveLength(2)
    expect(ipc).toContain(
      "ipcMain.handle('modules:snapshot', e => fromPage(e, async () => { await modulesReady " +
        'return moduleRows() }), )',
    )
  })

  it('sends modules:changed after each change of the state, and when the state opens', () => {
    expect(ipc).toContain("send('modules:changed', moduleRows())")
    expect(ipc).toMatch(
      /store => \{ modulesStore = store store\.onChange\(sendModules\) sendModules\(\) \}/,
    )
  })

  it('treats a dev module as off in a packaged app', () => {
    expect(ipc).toMatch(/modulesSnapshot\(modulesState\(\), \{ devAllowed: !app\.isPackaged,/)
  })

  it('gives modules.snapshot and modules.onUpdate to the page', () => {
    expect(preload).toContain("snapshot: () => invoke('modules:snapshot')")
    expect(preload).toContain("onUpdate: cb => subscribe('modules:changed', cb)")
  })
})

describe('the module jobs wiring (plan Task 7)', () => {
  it('gives the jobs to Heimdall, so claude.job is a known call', () => {
    expect(ipc).toMatch(
      /const heimdall = createHeimdall\(\{ devAllowed: !app\.isPackaged, [^;]*? jobs, /,
    )
    expect(ipc).toContain('emit: (moduleId, name, data) => heimdall.event(moduleId, name, data)')
  })

  it('runs each job with the job runner, the claude path and the login env', () => {
    expect(ipc).toContain('path ? createRunClaudeJob(path, env) : null')
    // The system temp folder holds no user name (ruling S-A10). A test home keeps its own.
    expect(ipc).toContain("jobsRoot: moduleJobsRoot(home ? home.home : app.getPath('temp'))")
  })

  it('handles modules:refresh once, through fromPage', () => {
    expect(ipc.split("ipcMain.handle('modules:refresh'")).toHaveLength(2)
    expect(ipc).toContain(
      "ipcMain.handle('modules:refresh', (e, moduleId: unknown) => fromPage(e, async () => { " +
        "if (typeof moduleId !== 'string') throw new Error(REFUSED_BAD_MODULE_INPUT)",
    )
    expect(ipc).toContain('moduleJobs?.refresh(moduleId)')
  })

  it('gives the waiting count to the rows, and sends the rows at local midnight', () => {
    expect(ipc).toContain('waiting: id => moduleJobs?.waiting(id) ?? 0')
    expect(ipc).toContain('changed: sendModules')
    expect(ipc).toContain(
      'stopModulesDay = watchLocalDay(sendModules, { log: message => console.error(message) })',
    )
  })

  it('stops the jobs and the midnight timer at the quit', () => {
    expect(ipc).toMatch(/export function stopRegistry\(\): void \{[^}]*moduleJobs\?\.stop\(\)/)
    expect(ipc).toMatch(/export function stopRegistry\(\): void \{[^}]*stopModulesDay\?\.\(\)/)
  })

  it('gives modules.refresh to the page', () => {
    expect(preload).toContain("refresh: moduleId => invoke('modules:refresh', moduleId)")
  })
})

describe('the module service wiring (plan Task 9)', () => {
  const channels: [string, string][] = [
    ['modules:install-folder', 'e => fromPage(e, () => moduleService.installFolder())'],
    [
      'modules:install-git',
      '(e, url: unknown) => fromPage(e, () => moduleService.installGit(url))',
    ],
    ['modules:install-dev', 'e => fromPage(e, () => moduleService.installDev())'],
    ['modules:check-updates', 'e => fromPage(e, () => moduleService.checkUpdates())'],
    [
      'modules:review-update',
      '(e, id: unknown) => fromPage(e, () => moduleService.reviewUpdate(id))',
    ],
    [
      'modules:approve',
      '(e, requestId: unknown) => fromPage(e, () => moduleService.allow(requestId))',
    ],
    [
      'modules:decline',
      '(e, requestId: unknown) => fromPage(e, () => moduleService.decline(requestId))',
    ],
    [
      'modules:set-enabled',
      '(e, id: unknown, on: unknown) => fromPage(e, () => moduleService.setEnabled(id, on))',
    ],
    [
      'modules:revoke',
      '(e, id: unknown, permission: unknown) => fromPage(e, () => ' +
        'moduleService.revoke(id, permission))',
    ],
    [
      'modules:grant',
      '(e, id: unknown, permission: unknown) => fromPage(e, () => ' +
        'moduleService.grant(id, permission))',
    ],
    [
      'modules:set-model',
      '(e, id: unknown, model: unknown) => fromPage(e, () => ' +
        'moduleService.setModel(id, model))',
    ],
    [
      'modules:set-cap',
      '(e, id: unknown, cap: unknown) => fromPage(e, () => moduleService.setCap(id, cap))',
    ],
    ['modules:remove', '(e, id: unknown) => fromPage(e, () => moduleService.remove(id))'],
  ]

  it.each(channels)('handles %s once, through fromPage', (channel, body) => {
    expect(ipc.split(`ipcMain.handle('${channel}'`)).toHaveLength(2)
    expect(ipc).toContain(`ipcMain.handle('${channel}', ${body}`)
  })

  it('gives the service the jobs, the data store, gh git with no prompt and the dev rule', () => {
    expect(ipc).toMatch(/createModuleService\(\{[^;]*devAllowed: !app\.isPackaged,/)
    expect(ipc).toMatch(/createModuleService\(\{[^;]*jobs: \{ cancel: id => jobs\.cancel\(id\) \}/)
    expect(ipc).toMatch(/createModuleService\(\{[^;]*data: moduleData,/)
    expect(ipc).toMatch(/createModuleService\(\{[^;]*git: modulesGit,/)
    expect(ipc).toMatch(
      /createModuleService\(\{[^;]*remoteBase: remoteBase\(home\?\.home \?\? null\)/,
    )
    expect(ipc).toContain('const modulesGit = createRepoGit({')
  })

  it('serves a dev module from its folder, and cleans the old copies after the state opens', () => {
    expect(ipc).toContain(
      'moduleCodeRoot(modulesHome, id, Object.hasOwn(modules, id) ? modules[id] : undefined)',
    )
    expect(ipc).toMatch(/modulesReady\s*\.then\(\(\) => moduleService\.cleanup\(\)\)/)
  })

  it('gives the module actions to the page', () => {
    for (const [name, channel] of [
      ['installFolder: () =>', "invoke('modules:install-folder')"],
      ['installGit: url =>', "invoke('modules:install-git', url)"],
      ['installDev: () =>', "invoke('modules:install-dev')"],
      ['checkUpdates: () =>', "invoke('modules:check-updates')"],
      ['reviewUpdate: id =>', "invoke('modules:review-update', id)"],
      ['approve: requestId =>', "invoke('modules:approve', requestId)"],
      ['decline: requestId =>', "invoke('modules:decline', requestId)"],
      ['setEnabled: (id, on) =>', "invoke('modules:set-enabled', id, on)"],
      ['revoke: (id, permission) =>', "invoke('modules:revoke', id, permission)"],
      ['grant: (id, permission) =>', "invoke('modules:grant', id, permission)"],
      ['setModel: (id, model) =>', "invoke('modules:set-model', id, model)"],
      ['setCap: (id, cap) =>', "invoke('modules:set-cap', id, cap)"],
      ['remove: id =>', "invoke('modules:remove', id)"],
    ]) {
      expect(preload).toContain(`${name} ${channel}`)
    }
  })
})

describe('the Discuss with Claude wiring (plan Task 10)', () => {
  it('gives discuss to Heimdall, so discuss.request is a known call (ruling P2)', () => {
    expect(ipc).toMatch(
      /const heimdall = createHeimdall\(\{ devAllowed: !app\.isPackaged, discuss, /,
    )
    expect(ipc).toContain('const discuss = createDiscuss({')
  })

  it('starts each session through the New session path, and copies from main', () => {
    expect(ipc).toMatch(/createDiscuss\(\{[^;]*createSession: spec => sessions\.create\(spec\),/)
    expect(ipc).toMatch(
      /createDiscuss\(\{[^;]*writeClipboard: text => clipboard\.writeText\(text\),/,
    )
    expect(ipc).toMatch(/createDiscuss\(\{[^;]*open: view => send\('modules:discuss', view\),/)
  })

  it('blocks the module folders, the storage folder and the job folders', () => {
    const list = /blockedFolders: \[([^\]]*)\]/.exec(ipc)?.[1] ?? ''
    expect(list).toContain("join(paths.bifrostHome, 'modules'),")
    expect(list).toContain("join(paths.bifrostHome, 'modules-data'),")
    // The job folders of a test home, and the job folders in the system temp folder.
    expect(list).toContain("moduleJobsRoot(home ? home.home : app.getPath('temp')),")
    expect(list).toContain("moduleJobsRoot(app.getPath('temp')),")
    expect(ipc).toMatch(/createDiscuss\(\{[^;]*realpath: path => realpath\(path\),/)
  })

  const channels: [string, string][] = [
    [
      'modules:discuss-start',
      '(e, requestId: unknown, input: unknown) => fromPage(e, () => ' +
        'discuss.start(requestId, input))',
    ],
    [
      'modules:discuss-copy',
      '(e, requestId: unknown, cardIndex: unknown) => fromPage(e, () => ' +
        'discuss.copy(requestId, cardIndex))',
    ],
    [
      'modules:discuss-cancel',
      '(e, requestId: unknown) => fromPage(e, async () => discuss.cancel(requestId))',
    ],
  ]

  it.each(channels)('handles %s once, through fromPage', (channel, body) => {
    expect(ipc.split(`ipcMain.handle('${channel}'`)).toHaveLength(2)
    expect(ipc).toContain(`ipcMain.handle('${channel}', ${body}`)
  })

  it('compares each folder by its identity (fix round 1)', () => {
    expect(ipc).toMatch(/createDiscuss\(\{[^;]*stat: async path => \{/)
    expect(ipc).toContain('const info = await stat(path, { bigint: true })')
  })

  it('keeps a Discuss session hidden after a hand-over (ruling P12)', () => {
    expect(ipc).toContain(
      'carryOver: (from, to) => { liveService?.carryOver(from, to) ' +
        'moduleDiscuss?.carryOver(from, to) },',
    )
  })

  it('saves the Discuss sessions in the modules state, and forgets them (ruling P12)', () => {
    expect(ipc).toContain('saveSession: id => saveModules(s => withDiscussSession(s, id)),')
    expect(ipc).toContain(
      'carrySession: (from, to) => saveModules(s => carriedDiscussSession(s, from, to)),',
    )
    // Only a forget of the registry drops a saved id, never an update of the list (fix round 3).
    expect(ipc).toContain('service.onForget(forgetDiscussSession)')
    expect(ipc).not.toContain('pruneDiscussSessions')
    expect(ipc).toContain('.change(s => withoutDiscussSession(s, sessionId))')
  })

  it('drops the open request when the page ends', () => {
    expect(ipc).toMatch(/function endPage\(\): void \{[^}]*moduleDiscuss\?\.clear\(\)/)
  })

  it('gives the Discuss actions to the page', () => {
    for (const [name, channel] of [
      ['discussStart: (requestId, input) =>', "invoke('modules:discuss-start', requestId, input)"],
      [
        'discussCopy: (requestId, cardIndex) =>',
        "invoke('modules:discuss-copy', requestId, cardIndex)",
      ],
      ['discussCancel: requestId =>', "invoke('modules:discuss-cancel', requestId)"],
      ['onDiscuss: cb =>', "subscribe('modules:discuss', cb)"],
    ]) {
      expect(preload).toContain(`${name} ${channel}`)
    }
  })
})
