// Source checks of the updater wiring in ipc.ts (updater design sections 4 and 5). ipc.ts imports
// Electron, so a unit test cannot load it. These checks read its text.
import { readFileSync } from 'node:fs'
import { join } from 'node:path'
import { describe, expect, it } from 'vitest'

const source = readFileSync(join(__dirname, '../../../src/main/ipc.ts'), 'utf8')

// The text with each run of white space as one space, and with no space after "(" or "[" or
// before ")" or "]". So a line break that the formatter adds does not change a match.
function flat(text: string): string {
  return text
    .replace(/\s+/g, ' ')
    .replace(/([([]) /g, '$1')
    .replace(/ ([)\]])/g, '$1')
}

// The text of the call that starts at index, up to its closing parenthesis.
function callAt(text: string, index: number): string {
  const open = text.indexOf('(', index)
  let depth = 0
  for (let i = open; i < text.length; i += 1) {
    if (text[i] === '(') depth += 1
    if (text[i] === ')') depth -= 1
    if (depth === 0) return text.slice(index, i + 1)
  }
  throw new Error(`The call at ${index} has no closing parenthesis.`)
}

// Each call in the text that starts with the pattern.
function calls(text: string, pattern: RegExp): string[] {
  return [...text.matchAll(pattern)].map(match => callAt(text, match.index ?? 0))
}

// The text of a top-level function, from its declaration to its closing "}" line.
function functionBody(name: string): string {
  const start = source.search(new RegExp(`\\n(export )?(async )?function ${name}\\b`))
  expect(start, `function ${name}`).toBeGreaterThan(-1)
  const end = source.indexOf('\n}\n', start)
  expect(end, `end of function ${name}`).toBeGreaterThan(start)
  return source.slice(start, end + 2)
}

// The text of the one ipcMain.handle call of the channel.
function handler(channel: string): string {
  const found = calls(source, new RegExp(`ipcMain\\.handle\\('${channel}'`, 'g'))
  expect(found, channel).toHaveLength(1)
  return flat(found[0] ?? '')
}

const RELEASE_BUILD =
  "app.isPackaged && home === null && existsSync(join(process.resourcesPath, 'app-update.yml'))"

describe('the updater wiring in ipc.ts', () => {
  it('makes the updater only in a release build, with the real home and app-update.yml', () => {
    const text = flat(source)
    // What's new uses the same value (release notes wiring test).
    expect(text).toContain(`const releaseBuild = ${RELEASE_BUILD}`)
    expect(text.match(/\breleaseBuild =/g)).toHaveLength(1)
    expect(text).toContain('if (releaseBuild) { startUpdater(settings, health)')
    // startUpdater has its declaration and this one call. createUpdater has one call, in it.
    expect(text.match(/\bstartUpdater\(/g)).toHaveLength(2)
    expect(text.match(/\bcreateUpdater\(/g)).toHaveLength(1)
    expect(functionBody('startUpdater')).toContain('createUpdater(')
  })

  it('reads autoUpdater of the CommonJS electron-updater only in startUpdater', () => {
    expect(source).toContain("import electronUpdater from 'electron-updater'")
    // The read of autoUpdater makes the Squirrel.Mac updater. So no other code reads it.
    expect(source.match(/\belectronUpdater\b/g)).toHaveLength(2)
    const body = functionBody('startUpdater')
    expect(body).toContain('const { autoUpdater } = electronUpdater')
    // electron-updater must not write to the console.
    expect(body).toContain('autoUpdater.logger = null')
  })

  it('starts the updater after the settings store and the state file open', () => {
    const body = flat(functionBody('startUpdater'))
    const opened = body.indexOf(
      "await Promise.all([openUpdateStateStore(join(app.getPath('userData'), 'updates.json')), settingsReady,])",
    )
    expect(opened).toBeGreaterThan(-1)
    const stopped = body.indexOf('if (serviceStopped) return')
    const start = body.indexOf('service.start()')
    expect(stopped).toBeGreaterThan(opened)
    expect(start).toBeGreaterThan(stopped)
    expect(body).toContain("createUpdateLog(app.getPath('logs'),")
  })

  it('gives the updater the deps of the app', () => {
    const call = flat(calls(functionBody('startUpdater'), /\bcreateUpdater\(/g)[0] ?? '')
    expect(call).toContain('engine: autoUpdater')
    expect(call).toContain('version: app.getVersion()')
    expect(call).toContain("appPath: appBundlePath(app.getPath('exe'))")
    expect(call).toContain('canWrite: canWriteFolder')
    expect(call).toContain('online: () => net.isOnline()')
    expect(call).toContain('settings: () => settings.get()')
    expect(call).toContain('showWindow: () => showWindowFn?.()')
    expect(call).toContain('emit: sendUpdates')
    // The notification of a ready update uses the label 'update' and logs a refusal.
    expect(call).toContain(
      "notify: (title, body, onClick) => showNotification({ body, label: 'update', sessionId: null, title }, () => onClick(), logRefusedNotification,)",
    )
  })

  it('gives the staged signal from the update-downloaded event of the Electron autoUpdater', () => {
    // Squirrel.Mac sends this event when it has staged the update. electron-updater listens to
    // the same object and adds its listener first, when startUpdater reads its autoUpdater.
    expect(source).toMatch(/import \{[^}]*\bautoUpdater as nativeUpdater\b[^}]*\} from 'electron'/)
    expect(source.match(/\bnativeUpdater\b/g)).toHaveLength(2)
    const body = flat(functionBody('startUpdater'))
    const read = body.indexOf('const { autoUpdater } = electronUpdater')
    const staged = body.indexOf(
      "onStaged: listener => { nativeUpdater.on('update-downloaded', () => listener()) }",
    )
    expect(read).toBeGreaterThan(-1)
    expect(staged).toBeGreaterThan(read)
  })

  it('checks the folder with W_OK, and an error gives false', () => {
    const body = flat(functionBody('canWriteFolder'))
    expect(body).toContain('access(folder, constants.W_OK).then(() => true, () => false,)')
  })

  it('never throws when it sends a new update state to the page', () => {
    const body = flat(functionBody('sendUpdates'))
    expect(body).toMatch(
      /try \{ send\('updates:update', snapshot\) \} catch \(err\) \{ console\.error\(/,
    )
  })

  it('stops the updater in stopRegistry', () => {
    expect(functionBody('stopRegistry')).toContain('updater?.stop()')
  })

  it('gives the switch to the updater in the updates effect', () => {
    expect(flat(functionBody('runSettingsEffect'))).toContain(
      "case 'updates': updater?.setAuto(effect.on) return",
    )
  })

  it('runs each updates handler only for the Bifrost page', () => {
    const channels = [...source.matchAll(/ipcMain\.handle\('(updates:[a-z-]+)'/g)].map(m => m[1])
    expect(channels.sort()).toEqual([
      'updates:check',
      'updates:restart',
      'updates:show-log',
      'updates:snapshot',
    ])
    for (const channel of channels) {
      expect(handler(channel ?? '')).toMatch(
        /^ipcMain\.handle\('updates:[a-z-]+', e => fromPage\(e, /,
      )
    }
  })

  it('gives a snapshot with available false and does nothing else when no updater exists', () => {
    expect(handler('updates:snapshot')).toContain(
      'updater?.snapshot() ?? { ...EMPTY_UPDATES, available: false, version: app.getVersion() }',
    )
    expect(handler('updates:check')).toContain('updater?.checkNow()')
    expect(handler('updates:restart')).toContain('updater?.restart()')
    expect(handler('updates:show-log')).toContain('updateLog?.path ?? null')
  })

  it('opens the update log with shell.openPath through openUpdateLog', () => {
    expect(handler('updates:show-log')).toContain('await openUpdateLog(')
    expect(handler('updates:show-log')).toContain('shell.openPath(path)')
  })

  it('has no console or update log call with a token in it', () => {
    const found = calls(source, /\b(console\.(log|warn|error|info)|log\.line)\(/g)
    expect(found.length).toBeGreaterThan(0)
    for (const call of found) expect(call).not.toMatch(/token/i)
  })
})
