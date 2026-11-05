// The pure logic of the New session form (spec 8.9).
import {
  checkNewSessionSpec,
  type DirInfo,
  type ModelChoice,
  type NewSessionSpec,
  REASON_DIR_CHECK,
  REASON_DIR_CHECK_FAILED,
  REASON_DIR_MISSING,
  REASON_NO_FOLDER,
  REASON_NO_GIT,
  REASON_WORKTREE_OFF,
  WORKTREE_OK,
} from '../../../shared/new-session'
import type { ActionState } from '../actions/action-model'
import type { History } from './history'

export {
  REASON_DIR_CHECK,
  REASON_DIR_CHECK_FAILED,
  REASON_DIR_MISSING,
  REASON_NO_FOLDER,
  REASON_NO_GIT,
  REASON_WORKTREE_OFF,
}

const MAX_BASE = 40

export interface NewSessionForm {
  cwd: string
  name: string
  nameEdited: boolean
  suffix: string
  model: ModelChoice
  permissionMode: string
  prompt: string
  worktree: boolean
}

export type FormAction =
  | { type: 'cwd'; cwd: string }
  | { type: 'name'; name: string }
  | { type: 'model'; model: ModelChoice }
  | { type: 'mode'; mode: string }
  | { type: 'prompt'; prompt: string }
  | { type: 'worktree'; on: boolean }

// The last part of the path, cut to 40 characters, then "-" and the suffix.
export function suggestName(cwd: string, suffix: string): string {
  const last = cwd
    .split('/')
    .filter(part => part !== '')
    .pop()
  return last === undefined ? `session-${suffix}` : `${last.slice(0, MAX_BASE)}-${suffix}`
}

export function initialForm(history: History, suffix: string): NewSessionForm {
  const cwd = history.recentDirs[0] ?? ''
  return {
    cwd,
    model: history.model,
    name: suggestName(cwd, suffix),
    nameEdited: false,
    permissionMode: history.permissionMode,
    prompt: '',
    suffix,
    worktree: false,
  }
}

export function formReducer(form: NewSessionForm, action: FormAction): NewSessionForm {
  switch (action.type) {
    case 'cwd':
      if (action.cwd === form.cwd) return form
      return {
        ...form,
        cwd: action.cwd,
        name: form.nameEdited ? form.name : suggestName(action.cwd, form.suffix),
        worktree: false,
      }
    case 'name':
      return action.name === form.name && form.nameEdited
        ? form
        : { ...form, name: action.name, nameEdited: true }
    case 'model':
      return action.model === form.model ? form : { ...form, model: action.model }
    case 'mode':
      return action.mode === form.permissionMode ? form : { ...form, permissionMode: action.mode }
    case 'prompt':
      return action.prompt === form.prompt ? form : { ...form, prompt: action.prompt }
    case 'worktree':
      return action.on === form.worktree ? form : { ...form, worktree: action.on }
  }
}

export function toSpec(
  form: NewSessionForm,
): { ok: true; spec: NewSessionSpec } | { ok: false; reason: string } {
  return checkNewSessionSpec({
    cwd: form.cwd,
    model: form.model,
    name: form.name,
    permissionMode: form.permissionMode,
    prompt: form.prompt,
    worktree: form.worktree,
  })
}

// True when the folder, after the trim, starts with "/". The folder check and the worktree
// reason use this rule.
export function isAbsoluteDir(cwd: string): boolean {
  return cwd.trim().startsWith('/')
}

// Tell if the worktree option works for the folder. No check runs for a folder that does not
// start with "/". For that folder, the reason is the same as the reason of the start button.
export function worktreeState(
  info: DirInfo | null,
  worktreeOk: boolean = WORKTREE_OK,
  checkFailed = false,
  cwd?: string,
): ActionState {
  if (!worktreeOk) return { enabled: false, reason: REASON_WORKTREE_OFF }
  if (cwd !== undefined && !isAbsoluteDir(cwd)) {
    return { enabled: false, reason: REASON_NO_FOLDER }
  }
  if (checkFailed) return { enabled: false, reason: REASON_DIR_CHECK_FAILED }
  if (info === null) return { enabled: false, reason: REASON_DIR_CHECK }
  if (info.kind !== 'dir') return { enabled: false, reason: REASON_DIR_MISSING }
  if (!info.git) return { enabled: false, reason: REASON_NO_GIT }
  return { enabled: true, reason: null }
}
