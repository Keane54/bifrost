// The texts of the confirmation dialogs (spec 9.1, 9.2).

import type { SessionRow, WorktreeCheck } from '../../../shared/types'
import { worktreeRoot } from '../../../shared/worktree'
import { actionLabel, type LabelSet } from './action-model'

export interface ConfirmText {
  title: string
  body: string
  confirm: string
  // The first click changes the confirm button to this label. Only a second click confirms.
  confirmAgain?: string
  // A folder that the dialog can open, so the user can look at the work first.
  openFolder?: string
}

// A worktree session has a cwd in .claude/worktrees or a branch that starts with worktree-.
export function isWorktreeRow(row: SessionRow): boolean {
  return row.cwd.includes('/.claude/worktrees/') || (row.branch?.startsWith('worktree-') ?? false)
}

// The dots after a label mean that the action opens a dialog. The dialog itself has no dots.
function bareLabel(id: 'stop' | 'delete' | 'take-control', labels: LabelSet): string {
  return actionLabel(id, labels).replace(/\.\.\.$/, '')
}

export function confirmFor(
  id: 'stop' | 'delete' | 'take-control',
  row: SessionRow,
  labels: LabelSet,
  check?: WorktreeCheck | null,
): ConfirmText | null {
  if (id === 'stop') {
    if (row.state !== 'working') return null
    const label = bareLabel('stop', labels)
    return {
      body: `${row.name} is working right now. Stop it anyway? The current turn will end.`,
      confirm: label,
      title: label,
    }
  }
  if (id === 'delete') {
    const label = bareLabel('delete', labels)
    // The title names the session. The word "session" of the plain label goes, because the name
    // follows it: "Delete bifrost-a1b2", or "Self-destruct bifrost-a1b2" with the space labels.
    const title = `${label.replace(/ session$/, '')} ${row.name}`
    const plain = `Delete ${row.name}? This removes the session and its conversation.`
    const ask = 'Are you sure you want to delete this?'
    const again = 'Delete anyway'
    if (check === null) {
      const folder = worktreeRoot(row.cwd)?.worktree
      return {
        body: `Bifrost could not check this session for unmerged work. ${ask}`,
        confirm: label,
        confirmAgain: again,
        title,
        ...(folder === undefined ? {} : { openFolder: folder }),
      }
    }
    if (check === undefined || check.worktree === null) {
      return { body: plain, confirm: label, title }
    }
    const parts: string[] = []
    if (check.unmergedCommits > 0) {
      const n = check.unmergedCommits
      parts.push(`${n} ${n === 1 ? 'commit' : 'commits'} that ${n === 1 ? 'is' : 'are'} not merged`)
    }
    if (check.changedFiles > 0) {
      const n = check.changedFiles
      parts.push(`${n} changed ${n === 1 ? 'file' : 'files'}`)
    }
    if (parts.length === 0) return { body: plain, confirm: label, title }
    const where = check.branch === null ? 'in its worktree' : `on ${check.branch}`
    return {
      body: `This session has ${parts.join(' and ')} ${where}. ${ask}`,
      confirm: label,
      confirmAgain: again,
      openFolder: check.worktree,
      title,
    }
  }
  const label = bareLabel('take-control', labels)
  return {
    body: `This closes the session in ${row.terminalApp ?? 'its terminal'} and moves it into Bifrost.`,
    confirm: label,
    title: label,
  }
}
