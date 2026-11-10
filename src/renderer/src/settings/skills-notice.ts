// The texts and the rules of Settings > Skills and the skills step of the setup dialog.
// The functions are pure, so the tests can check each rule.
import type { SkillGroup, SkillsStatus } from '../../../shared/skills'
import type { ConfirmText } from '../actions/confirm'
import type { LiveActionId } from './live-notice'

export const SKILLS_ABOUT =
  'Bifrost skills give Claude tested steps for common jobs: review a PR, resolve PR comments, ' +
  'humanise text, grill a plan and hand over a session. Start one by typing its name in a chat, ' +
  "for example /bifrost-review. They're a small Claude Code plugin that Bifrost keeps up to date."

const CHANGES_LEAD = ' Bifrost makes these changes only if you install them:'
export const SKILLS_SETUP_INTRO = SKILLS_ABOUT + CHANGES_LEAD

// The changes of Install, in the order that Install makes them.
export const SKILLS_STEPS: readonly string[] = [
  'Copy the skills plugin files to the folder ~/.bifrost/skills.',
  'Add that folder as the plugin marketplace "bifrost-skills", then install the plugin ' +
    '"bifrost" for your user with claude plugin.',
]

export const WITHOUT_SKILLS =
  'You can install the skills later in Settings > Skills. The Hand over button works without them.'

export const SKILLS_REMOVE_CONFIRM: ConfirmText = {
  body:
    'Bifrost turns off its skills, removes the plugin "bifrost" and the marketplace ' +
    '"bifrost-skills", and deletes the folder ~/.bifrost/skills.',
  confirm: 'Remove',
  title: 'Remove skills',
}

export const GROUP_LABELS: Readonly<Record<SkillGroup, string>> = {
  'called-by-name': 'Called by name',
  listed: 'Listed',
}

export const GROUP_HINT =
  "Listed skills are in Claude's skill list, so Claude can start them by itself. " +
  'Skills called by name cost no context until you type their name.'

const NOT_CHECKED = "Bifrost couldn't check the skills."
const FILES_DIFFER =
  "The skills use files that don't match this Bifrost. Turn them off, then on again."

export type SkillsNotice =
  | { kind: 'loading' }
  | { kind: 'not-installed' }
  | { kind: 'off' }
  | { kind: 'on' }
  | { kind: 'problem'; message: string }

// The state of the skills for the user. A null status is still loading.
export function skillsNotice(status: SkillsStatus | null): SkillsNotice {
  if (status === null) return { kind: 'loading' }
  switch (status.plugin) {
    case 'unknown':
      return { kind: 'problem', message: status.error ?? NOT_CHECKED }
    case 'not-installed':
      return { kind: 'not-installed' }
    case 'disabled':
      return { kind: 'off' }
    case 'enabled':
      return status.folderCurrent ? { kind: 'on' } : { kind: 'problem', message: FILES_DIFFER }
  }
}

// The state line of the Skills section.
export function skillsStateLine(notice: SkillsNotice): string {
  switch (notice.kind) {
    case 'loading':
      return 'Checking the skills...'
    case 'not-installed':
      return 'Not installed.'
    case 'off':
      return 'Off.'
    case 'on':
      return 'On.'
    case 'problem':
      return notice.message
  }
}

// The line of the done view. A problem message names the skills itself.
export function skillsDoneLine(notice: SkillsNotice): string {
  const line = skillsStateLine(notice)
  return notice.kind === 'problem' ? line : `Skills: ${line}`
}

// The buttons follow the table of Live details. The labels are LIVE_ACTION_LABELS.
export function skillsActions(status: SkillsStatus | null): LiveActionId[] {
  if (status === null) return []
  switch (status.plugin) {
    case 'unknown':
      return ['retry']
    case 'not-installed':
      return ['install']
    case 'disabled':
      return ['enable', 'remove']
    case 'enabled':
      return skillsNotice(status).kind === 'on'
        ? ['disable', 'remove']
        : ['disable', 'enable', 'remove']
  }
}

// The setup dialog offers the skills only when the plugin is not installed.
export function skillsStepNeeded(status: SkillsStatus | null): boolean {
  return status !== null && status.plugin === 'not-installed'
}

// The step after the Live step or the skills step. installed holds what the user installed in
// this open of the dialog. The result close means that the dialog closes.
export function nextSetupPhase(
  from: 'live' | 'skills',
  skills: SkillsStatus | null,
  installed: { live: boolean; skills: boolean },
): 'skills' | 'done' | 'close' {
  if (from === 'live' && skillsStepNeeded(skills)) return 'skills'
  return installed.live || installed.skills ? 'done' : 'close'
}
