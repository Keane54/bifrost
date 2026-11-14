// The path of the speech helper: next to the app executable in the packaged app, and the build of
// "pnpm build:dictation" in a dev run.
import { dirname, join } from 'node:path'
import { describe, expect, it, vi } from 'vitest'
import { HELPER_OUT } from '../../../scripts/build-dictation'

const place = { appPath: '/repo', isPackaged: false }
vi.mock('electron', () => ({
  app: {
    getAppPath: () => place.appPath,
    get isPackaged() {
      return place.isPackaged
    },
  },
}))

const { dictationHelperPath, helperPathFor, helperToRun } = await import(
  '../../../src/main/dictation/helper-path'
)

describe('helperPathFor', () => {
  it('gives Contents/MacOS/bifrost-dictation in the packaged app', () => {
    expect(
      helperPathFor({
        appPath: '/Applications/Bifrost.app/Contents/Resources/app.asar',
        execPath: '/Applications/Bifrost.app/Contents/MacOS/Bifrost',
        packaged: true,
      }),
    ).toBe('/Applications/Bifrost.app/Contents/MacOS/bifrost-dictation')
  })

  it('gives the output of the build script in a dev run', () => {
    expect(
      helperPathFor({
        appPath: '/repo',
        execPath: '/repo/node_modules/electron/dist/Electron.app/Contents/MacOS/Electron',
        packaged: false,
      }),
    ).toBe(`/repo/${HELPER_OUT}`)
  })
})

describe('dictationHelperPath', () => {
  it('reads the place from Electron', () => {
    place.isPackaged = false
    place.appPath = '/work/bifrost'
    expect(dictationHelperPath()).toBe(`/work/bifrost/${HELPER_OUT}`)
    place.isPackaged = true
    expect(dictationHelperPath()).toBe(join(dirname(process.execPath), 'bifrost-dictation'))
  })
})

describe('helperToRun', () => {
  const fake = '/repo/test/smoke/fake-dictation/bifrost-dictation'

  it('gives the first bifrost-dictation on the PATH in a test home', () => {
    const pathEnv = '/repo/test/smoke/fake-claude:/repo/test/smoke/fake-dictation:/usr/bin'
    expect(helperToRun(true, pathEnv, path => path === fake)).toBe(fake)
  })

  it('gives null in a test home with no fake helper, so a test never runs the real helper', () => {
    place.isPackaged = false
    place.appPath = '/work/bifrost'
    expect(helperToRun(true, '/usr/bin:/bin', () => false)).toBeNull()
  })

  it('gives the helper of the app outside a test home', () => {
    place.isPackaged = false
    place.appPath = '/work/bifrost'
    expect(helperToRun(false, '/repo/test/smoke/fake-dictation', () => true)).toBe(
      `/work/bifrost/${HELPER_OUT}`,
    )
  })
})
