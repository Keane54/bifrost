// The labels of the rows of Settings > Updates, and the text of its status block. UPDATES_ROWS is
// the one source of the labels: the row uses it, and the search of Settings finds the row by it.
import { causeText, UPDATE_TEXTS, type UpdatesSnapshot } from '../../../shared/updates'

export const UPDATES_ROWS = {
  auto: UPDATE_TEXTS.switchLabel,
} as const

export type UpdatesActionId = 'check' | 'restart' | 'retry' | 'show-log'

export const UPDATES_ACTION_LABELS: Readonly<Record<UpdatesActionId, string>> = {
  check: UPDATE_TEXTS.check,
  restart: UPDATE_TEXTS.restart,
  retry: UPDATE_TEXTS.retry,
  'show-log': UPDATE_TEXTS.showLog,
}

// The state line of the status block.
export function updatesStateLine(snapshot: UpdatesSnapshot): string {
  if (!snapshot.available) return "This build doesn't update itself."
  const { state } = snapshot
  switch (state.kind) {
    case 'idle':
      return "You're up to date."
    case 'checking':
      return 'Checking for updates…'
    case 'downloading':
      return `Downloading Bifrost ${state.version} (${Math.round(state.percent)}%)…`
    case 'ready':
      return `Bifrost ${state.version} is ready.`
    case 'failed':
      // The service already fills message with the masked cause text. Use the cause text when
      // the message is empty.
      return state.message || causeText(state.cause, '')
    case 'off':
      return 'Automatic updates are off.'
  }
}

// The buttons of the status block, in order. A build that cannot update has no button.
export function updatesActions(snapshot: UpdatesSnapshot): UpdatesActionId[] {
  if (!snapshot.available) return []
  const ids: UpdatesActionId[] = ['check']
  if (snapshot.state.kind === 'ready') ids.push('restart')
  if (snapshot.state.kind === 'failed') ids.push('retry')
  ids.push('show-log')
  return ids
}
