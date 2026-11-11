import { describe, expect, it, vi } from 'vitest'
import { openUpdateLog, UPDATE_LOG_TEXTS } from '../../../src/main/updates/open-log'

function makeDeps(openError = '') {
  return {
    ensureFile: vi.fn(async () => {}),
    openPath: vi.fn(async () => openError),
    showItemInFolder: vi.fn(),
  }
}

describe('openUpdateLog', () => {
  it('opens the log file when the open works', async () => {
    const deps = makeDeps()
    await openUpdateLog('/logs/updater.log', deps)
    expect(deps.ensureFile).toHaveBeenCalledWith('/logs/updater.log')
    expect(deps.openPath).toHaveBeenCalledWith('/logs/updater.log')
    expect(deps.showItemInFolder).not.toHaveBeenCalled()
  })

  it('shows the file in Finder when the open gives an error', async () => {
    const deps = makeDeps('no app')
    await openUpdateLog('/logs/updater.log', deps)
    expect(deps.showItemInFolder).toHaveBeenCalledWith('/logs/updater.log')
  })

  it('rejects with a friendly text when there is no log', async () => {
    const deps = makeDeps()
    await expect(openUpdateLog(null, deps)).rejects.toThrow(UPDATE_LOG_TEXTS.none)
    expect(deps.openPath).not.toHaveBeenCalled()
  })

  it('rejects with a friendly text when the file cannot be made', async () => {
    const deps = makeDeps()
    deps.ensureFile.mockRejectedValue(new Error('EACCES'))
    await expect(openUpdateLog('/logs/updater.log', deps)).rejects.toThrow(
      UPDATE_LOG_TEXTS.unreadable,
    )
    expect(deps.openPath).not.toHaveBeenCalled()
  })
})
