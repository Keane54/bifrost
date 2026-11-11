import { describe, expect, it, vi } from 'vitest'
import { openUpdateLog, UPDATE_LOG_TEXTS } from '../../../src/main/updates/open-log'
import { LOG_NAME, updateLogPath } from '../../../src/main/updates/update-log'

const PATH = '/logs/updater.log'

function makeDeps(opts: { exists?: boolean; updaterRuns?: boolean; openError?: string } = {}) {
  return {
    ensureFile: vi.fn(async () => {}),
    exists: vi.fn(async () => opts.exists ?? true),
    openPath: vi.fn(async () => opts.openError ?? ''),
    showItemInFolder: vi.fn(),
    updaterRuns: opts.updaterRuns ?? false,
  }
}

describe('updateLogPath', () => {
  it('joins the logs folder and the fixed log name', () => {
    expect(updateLogPath('/logs')).toBe(`/logs/${LOG_NAME}`)
  })
})

describe('openUpdateLog', () => {
  it('opens an existing file even when no updater runs', async () => {
    const deps = makeDeps({ exists: true, updaterRuns: false })
    await openUpdateLog(PATH, deps)
    expect(deps.openPath).toHaveBeenCalledWith(PATH)
    expect(deps.ensureFile).not.toHaveBeenCalled()
  })

  it('shows the file in Finder when the open gives an error', async () => {
    const deps = makeDeps({ openError: 'no app' })
    await openUpdateLog(PATH, deps)
    expect(deps.showItemInFolder).toHaveBeenCalledWith(PATH)
  })

  it('rejects and makes no file when no updater runs and the file is missing', async () => {
    const deps = makeDeps({ exists: false, updaterRuns: false })
    await expect(openUpdateLog(PATH, deps)).rejects.toThrow(UPDATE_LOG_TEXTS.none)
    expect(deps.ensureFile).not.toHaveBeenCalled()
    expect(deps.openPath).not.toHaveBeenCalled()
  })

  it('makes the file, then opens it, when the updater runs and the file is missing', async () => {
    const deps = makeDeps({ exists: false, updaterRuns: true })
    await openUpdateLog(PATH, deps)
    expect(deps.ensureFile).toHaveBeenCalledWith(PATH)
    expect(deps.openPath).toHaveBeenCalledWith(PATH)
  })

  it('rejects with a friendly text when the file cannot be made', async () => {
    const deps = makeDeps({ exists: false, updaterRuns: true })
    deps.ensureFile.mockRejectedValue(new Error('EACCES'))
    await expect(openUpdateLog(PATH, deps)).rejects.toThrow(UPDATE_LOG_TEXTS.unreadable)
    expect(deps.openPath).not.toHaveBeenCalled()
  })
})
