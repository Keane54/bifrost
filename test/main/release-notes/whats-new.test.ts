import { describe, expect, it, vi } from 'vitest'
import type { ReleaseNotesStore } from '../../../src/main/release-notes/state-store'
import { createWhatsNew } from '../../../src/main/release-notes/whats-new'

function memoryStore(lastSeenVersion: string | null) {
  let value = { lastSeenVersion }
  const store: ReleaseNotesStore = {
    get: () => value,
    set: vi.fn(async next => {
      value = next
    }),
  }
  return store
}

function setup(lastSeen: string | null, setupDone: boolean, version = '0.5.0') {
  const store = memoryStore(lastSeen)
  const openStore = vi.fn(async () => store)
  const whatsNew = createWhatsNew({
    openStore,
    setupDone: async () => setupDone,
    version,
  })
  return { openStore, store, whatsNew }
}

describe('createWhatsNew', () => {
  it('opens nothing for a fresh install, and stores the version', async () => {
    const { store, whatsNew } = setup(null, false)
    expect(await whatsNew.take()).toBeNull()
    expect(store.get()).toEqual({ lastSeenVersion: '0.5.0' })
  })

  it("stores the version before it opens What's new, so a failed load cannot open it again", async () => {
    const { store, whatsNew } = setup('0.4.0', true)
    const start = await whatsNew.take()
    expect(start).toEqual({ since: '0.4.0', version: '0.5.0' })
    expect(store.set).toHaveBeenCalledWith({ lastSeenVersion: '0.5.0' })
  })

  it('opens the current version for an existing user with no stored version', async () => {
    const { whatsNew } = setup(null, true)
    expect(await whatsNew.take()).toEqual({ since: null, version: '0.5.0' })
  })

  it('opens nothing and writes nothing for the same version', async () => {
    const { store, whatsNew } = setup('0.5.0', true)
    expect(await whatsNew.take()).toBeNull()
    expect(store.set).not.toHaveBeenCalled()
  })

  it('gives the start only to the first call, so a reload of the page does not open it again', async () => {
    const { openStore, whatsNew } = setup('0.4.0', true)
    const [first, second] = await Promise.all([whatsNew.take(), whatsNew.take()])
    expect(first).toEqual({ since: '0.4.0', version: '0.5.0' })
    expect(second).toBeNull()
    expect(await whatsNew.take()).toBeNull()
    expect(openStore).toHaveBeenCalledTimes(1)
  })

  it('opens nothing when the store or the settings fail, and never rejects', async () => {
    const whatsNew = createWhatsNew({
      openStore: async () => {
        throw new Error('no store')
      },
      setupDone: async () => true,
      version: '0.5.0',
    })
    await expect(whatsNew.take()).resolves.toBeNull()
  })
})
