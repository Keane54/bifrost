// The rule that decides if What's new opens by itself at the start. This file has no Electron
// import. Only a release build uses the rule (ipc.ts).
import { compareVersions, parseVersion, type WhatsNewStart } from '../../shared/release-notes'

export interface WhatsNewInput {
  // The version of the running app.
  current: string
  // The version of the last What's new, or of the first start. null when no version is stored.
  lastSeen: string | null
  // True after the setup dialog got a choice.
  setupDone: boolean
}

export interface WhatsNewDecision {
  // The view to open, or null.
  open: WhatsNewStart | null
  // True when the current version must become the last seen version. The app stores it before the
  // view opens, so a failed load does not open the view again for the same version.
  store: boolean
}

export function whatsNewRule({ current, lastSeen, setupDone }: WhatsNewInput): WhatsNewDecision {
  if (parseVersion(current) === null) return { open: null, store: false }
  // A stored text that is not a version counts as no stored version.
  const seen = lastSeen !== null && parseVersion(lastSeen) !== null ? lastSeen : null
  if (seen === null) {
    // No setup choice: a fresh install. It has no news. An existing user who updates to the first
    // version with What's new gets the notes of that version.
    return setupDone
      ? { open: { since: null, version: current }, store: true }
      : { open: null, store: true }
  }
  if ((compareVersions(seen, current) ?? 0) < 0) {
    return { open: { since: seen, version: current }, store: true }
  }
  return { open: null, store: false }
}
