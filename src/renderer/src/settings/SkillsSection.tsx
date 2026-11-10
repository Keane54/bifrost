// Settings > Skills: the state, the buttons, the reload note and the list of skills.
import { useEffect, useState } from 'react'
import { DIALOG_BUTTON, useConfirm } from '../actions/ConfirmDialog'
import { cx } from '../lib/cx'
import { ErrorLine } from '../lib/ErrorLine'
import { errorMessage } from '../lib/error-message'
import { useLive } from './live-context'
import { LIVE_ACTION_LABELS, type LiveActionId, RELOAD_NOTE } from './live-notice'
import { useSkills } from './skills-context'
import {
  GROUP_HINT,
  GROUP_LABELS,
  SKILLS_REMOVE_CONFIRM,
  SKILLS_STEPS,
  skillsActions,
  skillsStateLine,
  WITHOUT_SKILLS,
} from './skills-notice'

// The changes of Install, as a numbered list.
export function SkillsSteps(): React.JSX.Element {
  return (
    <ol className='list-decimal space-y-1 pl-5 select-text' data-skills-steps={true}>
      {SKILLS_STEPS.map(step => (
        <li key={step}>{step}</li>
      ))}
    </ol>
  )
}

// readStatus: the status read of the Settings view. It reads the status one time for each view.
export default function SkillsSection({
  readStatus,
}: {
  readStatus: () => void
}): React.JSX.Element {
  const skills = useSkills()
  const { busy, changed, notice, refresh, status } = skills
  // One integration action runs at a time, also across Live details and the skills.
  const liveBusy = useLive().busy
  const disabled = busy || liveBusy
  const confirm = useConfirm()
  const [error, setError] = useState<string | null>(null)
  // True after the first Install click. The steps then show with Install and Cancel.
  const [showSteps, setShowSteps] = useState(false)

  useEffect(() => {
    readStatus()
  }, [readStatus])

  // Run a call. A failure shows its message. The result is true when the call worked.
  const run = async (fn: () => Promise<void>): Promise<boolean> => {
    setError(null)
    try {
      await fn()
      return true
    } catch (err) {
      setError(errorMessage(err))
      return false
    }
  }

  const onAction = (id: LiveActionId): void => {
    switch (id) {
      case 'install':
        setError(null)
        setShowSteps(true)
        return
      case 'enable':
        void run(skills.enable)
        return
      case 'disable':
        void run(skills.disable)
        return
      case 'retry':
        void run(refresh)
        return
      case 'remove':
        void confirm(SKILLS_REMOVE_CONFIRM).then(ok => {
          if (ok) void run(skills.uninstall)
        })
        return
    }
  }

  const steps = showSteps && notice.kind === 'not-installed'
  const actions = skillsActions(status)

  return (
    <div className='flex flex-col text-xs'>
      <div className='border-b border-panel-edge px-3 py-2'>
        <p className='text-text-strong select-text' data-skills-state={notice.kind}>
          {skillsStateLine(notice)}
        </p>
        {notice.kind === 'not-installed' && (
          <p className='mt-1 text-text-dim select-text'>{WITHOUT_SKILLS}</p>
        )}
        {steps ? (
          <div className='mt-2 text-text'>
            <p className='mb-1'>Install makes these changes:</p>
            <SkillsSteps />
            <div className='mt-2 flex items-center gap-2'>
              <button
                className={DIALOG_BUTTON}
                data-skills-action='install-confirm'
                disabled={disabled}
                onClick={() => {
                  void run(skills.install).then(ok => {
                    if (ok) setShowSteps(false)
                  })
                }}
                type='button'
              >
                Install
              </button>
              <button
                className={DIALOG_BUTTON}
                data-skills-action='install-cancel'
                disabled={disabled}
                onClick={() => setShowSteps(false)}
                type='button'
              >
                Cancel
              </button>
            </div>
          </div>
        ) : (
          actions.length > 0 && (
            <div className='mt-2 flex items-center gap-2'>
              {actions.map(id => (
                <button
                  className={DIALOG_BUTTON}
                  data-skills-action={id}
                  disabled={disabled}
                  key={id}
                  onClick={() => onAction(id)}
                  type='button'
                >
                  {LIVE_ACTION_LABELS[id]}
                </button>
              ))}
            </div>
          )
        )}
        {changed && (
          <p className='mt-2 text-text select-text' data-skills-note='reload'>
            {RELOAD_NOTE}
          </p>
        )}
      </div>
      <ErrorLine message={error} onClose={() => setError(null)} />
      {status !== null && status.skills.length > 0 && (
        <div className='px-3 py-2'>
          <p className='mb-2 text-text-dim select-text'>{GROUP_HINT}</p>
          <ul className='space-y-2'>
            {status.skills.map(skill => (
              <li data-skill-name={skill.name} key={skill.name}>
                <div className='flex items-baseline gap-2'>
                  <span className='font-medium text-text-strong select-text'>/{skill.name}</span>
                  <span
                    className={cx(skill.group === 'listed' ? 'text-text' : 'text-text-dim')}
                    data-skill-group={skill.group}
                  >
                    {GROUP_LABELS[skill.group]}
                  </span>
                </div>
                <p className='text-text select-text'>{skill.description}</p>
              </li>
            ))}
          </ul>
        </div>
      )}
    </div>
  )
}
