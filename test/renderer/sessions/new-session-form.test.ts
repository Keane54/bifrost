import { describe, expect, it } from 'vitest'
import { EMPTY_HISTORY } from '../../../src/renderer/src/sessions/history'
import {
  formReducer,
  initialForm,
  REASON_DIR_CHECK,
  REASON_DIR_MISSING,
  REASON_NO_GIT,
  REASON_WORKTREE_OFF,
  suggestName,
  toSpec,
  worktreeState,
} from '../../../src/renderer/src/sessions/new-session-form'

describe('new session form', () => {
  it('suggestName gives the directory name and the suffix', () => {
    expect(suggestName('/Users/o/Developer/bifrost', 'a1b2')).toBe('bifrost-a1b2')
    expect(suggestName('/', 'a1b2')).toBe('session-a1b2')
    expect(suggestName(`/${'x'.repeat(60)}`, 'a1b2')).toBe(`${'x'.repeat(40)}-a1b2`)
  })

  it('initialForm uses the last directory, the last model and the last mode', () => {
    const form = initialForm(
      { ...EMPTY_HISTORY, model: 'haiku', permissionMode: 'plan', recentDirs: ['/p/app', '/q'] },
      'a1b2',
    )
    expect(form).toMatchObject({
      cwd: '/p/app',
      model: 'haiku',
      name: 'app-a1b2',
      nameEdited: false,
      permissionMode: 'plan',
      prompt: '',
      worktree: false,
    })
    expect(initialForm(EMPTY_HISTORY, 'a1b2').name).toBe('session-a1b2')
  })

  it('a new directory changes a suggested name but not an edited name', () => {
    const form = initialForm({ ...EMPTY_HISTORY, recentDirs: ['/p/app'] }, 'a1b2')
    expect(formReducer(form, { cwd: '/p/web', type: 'cwd' }).name).toBe('web-a1b2')
    const edited = formReducer(form, { name: 'mine', type: 'name' })
    expect(edited.nameEdited).toBe(true)
    expect(formReducer(edited, { cwd: '/p/web', type: 'cwd' }).name).toBe('mine')
    expect(formReducer(form, { cwd: '/p/app', type: 'cwd' })).toBe(form)
  })

  it('a new directory turns the worktree option off', () => {
    const form = formReducer(initialForm(EMPTY_HISTORY, 'a1b2'), { on: true, type: 'worktree' })
    expect(form.worktree).toBe(true)
    expect(formReducer(form, { cwd: '/x', type: 'cwd' }).worktree).toBe(false)
  })

  it('the other actions change one field and keep the same object for the same value', () => {
    const form = initialForm(EMPTY_HISTORY, 'a1b2')
    expect(formReducer(form, { model: 'opus', type: 'model' }).model).toBe('opus')
    expect(formReducer(form, { mode: 'plan', type: 'mode' }).permissionMode).toBe('plan')
    expect(formReducer(form, { prompt: 'hi', type: 'prompt' }).prompt).toBe('hi')
    expect(formReducer(form, { model: '', type: 'model' })).toBe(form)
    expect(formReducer(form, { on: false, type: 'worktree' })).toBe(form)
  })

  it('toSpec refuses a bad form with the shared reason', () => {
    const form = initialForm(EMPTY_HISTORY, 'a1b2')
    expect(toSpec(form)).toEqual({ ok: false, reason: 'Choose a project folder.' })
    const ok = toSpec({ ...form, cwd: '/p/app', name: 'app-a1b2' })
    expect(ok).toMatchObject({ ok: true, spec: { cwd: '/p/app', name: 'app-a1b2' } })
  })

  it('worktreeState gives each reason, and enabled for a git directory', () => {
    expect(worktreeState(null, true)).toEqual({ enabled: false, reason: REASON_DIR_CHECK })
    expect(worktreeState({ git: false, kind: 'missing' }, true).reason).toBe(REASON_DIR_MISSING)
    expect(worktreeState({ git: false, kind: 'other' }, true).reason).toBe(REASON_DIR_MISSING)
    expect(worktreeState({ git: false, kind: 'dir' }, true).reason).toBe(REASON_NO_GIT)
    expect(worktreeState({ git: true, kind: 'dir' }, true)).toEqual({ enabled: true, reason: null })
    for (const info of [
      null,
      { git: false, kind: 'missing' as const },
      { git: true, kind: 'dir' as const },
    ]) {
      expect(worktreeState(info, false)).toEqual({ enabled: false, reason: REASON_WORKTREE_OFF })
    }
  })
})
