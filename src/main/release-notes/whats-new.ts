// What's new at the start. The page asks one time after it loads. The first answer of the process
// applies the rule (rules.ts) and stores the version. Each later answer is null, so a reload of
// the page does not open the view again. This file has no Electron import. ipc.ts makes it only in
// a release build.
import type { WhatsNewStart } from '../../shared/release-notes'
import { whatsNewRule } from './rules'
import type { ReleaseNotesStore } from './state-store'

export interface WhatsNewDeps {
  // The version of the running app.
  version: string
  // Open the state file. The service calls it at most one time.
  openStore(): Promise<ReleaseNotesStore>
  // True after the setup dialog got a choice.
  setupDone(): Promise<boolean>
}

export interface WhatsNew {
  // The view to open, or null. This never rejects.
  take(): Promise<WhatsNewStart | null>
}

export function createWhatsNew(deps: WhatsNewDeps): WhatsNew {
  let taken = false

  async function decide(): Promise<WhatsNewStart | null> {
    const [store, setupDone] = await Promise.all([deps.openStore(), deps.setupDone()])
    const decision = whatsNewRule({
      current: deps.version,
      lastSeen: store.get().lastSeenVersion,
      setupDone,
    })
    // Store first. The view then opens only one time for this version, also when its load fails.
    if (decision.store) await store.set({ lastSeenVersion: deps.version })
    return decision.open
  }

  return {
    async take() {
      if (taken) return null
      taken = true
      try {
        return await decide()
      } catch (err) {
        console.error("Bifrost cannot read the state of What's new.", err)
        return null
      }
    },
  }
}
