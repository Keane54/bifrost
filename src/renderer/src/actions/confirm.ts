// The texts of the confirmation dialogs (spec 9.1, 9.2).

import type { SessionRow } from '../../../shared/types'
import { actionLabel, type LabelSet } from './action-model'

export interface ConfirmText {
  title: string
  body: string
  confirm: string
}

// A worktree session has a cwd in .claude/worktrees or a branch that starts with worktree-.
export function isWorktreeRow(row: SessionRow): boolean {
  return row.cwd.includes('/.claude/worktrees/') || (row.branch?.startsWith('worktree-') ?? false)
}

export function confirmFor(
  id: 'stop' | 'delete' | 'take-control',
  row: SessionRow,
  labels: LabelSet,
): ConfirmText | null {
  if (id === 'stop') {
    if (row.state !== 'working') return null
    const label = actionLabel('stop', labels)
    return {
      body: `${row.name} is working right now. Stop it anyway? The current turn will end.`,
      confirm: label,
      title: label,
    }
  }
  if (id === 'delete') {
    const label = actionLabel('delete', labels)
    return {
      body: `Delete ${row.name}? This removes the session and its conversation.`,
      confirm: label,
      title: label,
    }
  }
  const label = actionLabel('take-control', labels)
  return {
    body: `This closes the session in ${row.terminalApp ?? 'its terminal'} and moves it into Bifrost.`,
    confirm: label,
    title: label,
  }
}
