// The setup dialog at the first start (spec 11.1, D10). It offers Live details or Skip, then the
// skills or Skip, and it lists each change before Bifrost makes it. Esc and a click outside do
// nothing.
// "Show introduction" in Settings > General opens it again. Then an installed plugin shows its
// state and Done, and Skip only closes the dialog.
import { AlertDialog } from '@base-ui/react/alert-dialog'
import { useEffect, useRef, useState } from 'react'
import { DIALOG_BACKDROP, DIALOG_BUTTON, DIALOG_POPUP_WIDE } from '../actions/ConfirmDialog'
import { ErrorLine } from '../lib/ErrorLine'
import { errorMessage } from '../lib/error-message'
import LiveSteps from './LiveSteps'
import { useLive } from './live-context'
import {
  claudeVersionNotice,
  INTRO_CHANGE_NOTE,
  introStateLine,
  LIVE_ABOUT,
  liveVersionNote,
  RELOAD_NOTE,
  SETUP_INTRO,
  type SetupMode,
  setupChosen,
  setupView,
  shouldShowSetup,
  skipSavesChoice,
  WITHOUT_LIVE,
} from './live-notice'
import { SkillsSteps } from './SkillsSection'
import { useSettings } from './settings-context'
import { useSettingsNav } from './settings-nav'
import { useSkills } from './skills-context'
import { nextSetupPhase, SKILLS_SETUP_INTRO, skillsDoneLine, WITHOUT_SKILLS } from './skills-notice'

// ask: the Live details choice. skills: the skills choice. done: an install worked, and the
// dialog shows the reload note.
type Phase = 'ask' | 'skills' | 'done'

// What the user installed in this open of the dialog.
interface Installed {
  live: boolean
  skills: boolean
}
const NOTHING: Installed = { live: false, skills: false }

function logSaveError(err: unknown): void {
  console.error('Bifrost cannot save the end of the setup.', err)
}

export default function SetupDialog(): React.JSX.Element {
  const { ready, settings, update } = useSettings()
  const { busy, install, notice, refresh, status, version, versionFailed } = useLive()
  const skills = useSkills()
  const { introRequest, setSetupOpen } = useSettingsNav()
  const [open, setOpen] = useState(false)
  const [mode, setMode] = useState<SetupMode>('first')
  const [phase, setPhase] = useState<Phase>('ask')
  const [error, setError] = useState<string | null>(null)
  const [installed, setInstalled] = useState<Installed>(NOTHING)
  // After Skip or Done, the dialog does not open again by itself in this page.
  const closed = useRef(false)
  const skipRef = useRef<HTMLButtonElement>(null)
  const skipSkillsRef = useRef<HTMLButtonElement>(null)
  const doneRef = useRef<HTMLButtonElement>(null)
  const chosen = setupChosen(status)
  // The dialog waits for the skills status too, so the skills step never shows late.
  const show = ready && skills.status !== null && shouldShowSetup(settings, status)

  // An installed plugin, on or off, is already a choice. Then save it and show nothing.
  useEffect(() => {
    if (ready && chosen && !settings.setupDone) {
      update({ setupDone: true }).catch(logSaveError)
    }
  }, [chosen, ready, settings.setupDone, update])

  // The dialog opens one time. It stays open until Skip or Done, also when the status changes.
  useEffect(() => {
    if (show && !closed.current) setOpen(true)
  }, [show])

  // The release notes view waits while this dialog is open, also in the done phase after the
  // save of setupDone. So What's new never opens over this dialog.
  useEffect(() => {
    setSetupOpen(open)
  }, [open, setSetupOpen])
  useEffect(() => () => setSetupOpen(false), [setSetupOpen])

  // "Show introduction" opens the dialog again. The open saves nothing.
  useEffect(() => {
    if (introRequest === 0) return
    setMode('again')
    setPhase('ask')
    setInstalled(NOTHING)
    setError(null)
    setOpen(true)
  }, [introRequest])

  const close = (): void => {
    closed.current = true
    setOpen(false)
  }

  // The step after the Live step or the skills step. The dialog stays open for the next step and
  // for the done view. Only close() closes it.
  const advance = (from: 'live' | 'skills', now: Installed): void => {
    setError(null)
    const next = nextSetupPhase(from, skills.status, now)
    if (next === 'close') close()
    else setPhase(next)
  }

  // At the first start, Skip saves the choice and goes to the next step. A failed save does not
  // keep the dialog open. The dialog then shows again at the next start. When the dialog opens
  // again, Skip saves nothing.
  const skip = (): void => {
    if (skipSavesChoice(mode)) update({ setupDone: true }).catch(logSaveError)
    advance('live', installed)
  }

  // Done of the installed view ends the Live step too.
  const doneLive = (): void => advance('live', installed)

  const skipSkills = (): void => advance('skills', installed)

  // Install the skills. A failure keeps the buttons and shows the error.
  const installSkills = async (): Promise<void> => {
    setError(null)
    try {
      await skills.install()
    } catch (err) {
      setError(errorMessage(err))
      return
    }
    const now = { ...installed, skills: true }
    setInstalled(now)
    advance('skills', now)
  }

  // Install the plugin (Live D11: the plugin is not installed). A failure keeps the buttons.
  const turnOn = async (): Promise<void> => {
    setError(null)
    try {
      await install()
    } catch (err) {
      setError(errorMessage(err))
      return
    }
    update({ setupDone: true }).catch(logSaveError)
    const now = { ...installed, live: true }
    setInstalled(now)
    advance('live', now)
  }

  const versionText = claudeVersionNotice(version, versionFailed)
  const liveVersionText = liveVersionNote(status)
  const view = setupView(mode, phase, status)
  const initialFocus = view === 'ask' ? skipRef : view === 'skills' ? skipSkillsRef : doneRef

  return (
    <AlertDialog.Root
      // Esc and a click outside do nothing. Only Skip and Done close the dialog.
      onOpenChange={() => {}}
      open={open}
    >
      <AlertDialog.Portal>
        <AlertDialog.Backdrop className={DIALOG_BACKDROP} />
        <AlertDialog.Popup
          className={DIALOG_POPUP_WIDE}
          data-setup-dialog={view}
          data-setup-mode={mode}
          initialFocus={initialFocus}
        >
          <AlertDialog.Title className='font-semibold text-text-strong'>
            Set up Bifrost
          </AlertDialog.Title>
          {view === 'installed' && (
            <>
              <AlertDialog.Description className='select-text'>
                {LIVE_ABOUT}
              </AlertDialog.Description>
              <p className='text-text-strong select-text' data-setup-state={notice.kind}>
                {introStateLine(notice)}
              </p>
              <p className='text-text-dim select-text'>{INTRO_CHANGE_NOTE}</p>
              <div className='flex items-center gap-2'>
                <span className='flex-1' />
                <button
                  className={DIALOG_BUTTON}
                  data-setup-action='done'
                  onClick={doneLive}
                  ref={doneRef}
                  type='button'
                >
                  Done
                </button>
              </div>
            </>
          )}
          {view === 'done' && (
            <>
              <AlertDialog.Description className='select-text'>
                {installed.live ? introStateLine(notice) : skillsDoneLine(skills.notice)}
              </AlertDialog.Description>
              {installed.live && installed.skills && (
                <p className='select-text'>{skillsDoneLine(skills.notice)}</p>
              )}
              <p className='select-text'>{RELOAD_NOTE}</p>
              <div className='flex items-center gap-2'>
                <span className='flex-1' />
                <button
                  className={DIALOG_BUTTON}
                  data-setup-action='done'
                  onClick={close}
                  ref={doneRef}
                  type='button'
                >
                  Done
                </button>
              </div>
            </>
          )}
          {view === 'skills' && (
            <>
              <AlertDialog.Description className='select-text'>
                {SKILLS_SETUP_INTRO}
              </AlertDialog.Description>
              <SkillsSteps />
              <p className='text-text-dim select-text'>{WITHOUT_SKILLS}</p>
              <ErrorLine message={error} onClose={() => setError(null)} />
              <div className='flex items-center gap-2'>
                <span className='flex-1' />
                <button
                  className={DIALOG_BUTTON}
                  data-setup-action='skip-skills'
                  disabled={skills.busy}
                  onClick={skipSkills}
                  ref={skipSkillsRef}
                  type='button'
                >
                  Skip
                </button>
                <button
                  className={DIALOG_BUTTON}
                  data-setup-action='install-skills'
                  disabled={skills.busy}
                  onClick={() => void installSkills()}
                  type='button'
                >
                  Install skills
                </button>
              </div>
            </>
          )}
          {view === 'ask' && (
            <>
              <AlertDialog.Description className='select-text'>
                {SETUP_INTRO}
              </AlertDialog.Description>
              {status && <LiveSteps status={status} />}
              {versionText !== null && <p className='select-text'>{versionText}</p>}
              {liveVersionText !== null && <p className='select-text'>{liveVersionText}</p>}
              {notice.kind === 'problem' && (
                <div className='flex items-start gap-2'>
                  <p className='min-w-0 flex-1 select-text' data-setup-problem={true}>
                    {notice.message}
                  </p>
                  <button
                    className={DIALOG_BUTTON}
                    data-setup-action='retry'
                    disabled={busy}
                    onClick={() => void refresh()}
                    type='button'
                  >
                    Try again
                  </button>
                </div>
              )}
              <p className='text-text-dim select-text'>{WITHOUT_LIVE}</p>
              <ErrorLine message={error} onClose={() => setError(null)} />
              <div className='flex items-center gap-2'>
                <span className='flex-1' />
                <button
                  className={DIALOG_BUTTON}
                  data-setup-action='skip'
                  disabled={busy}
                  onClick={skip}
                  ref={skipRef}
                  type='button'
                >
                  Skip
                </button>
                <button
                  className={DIALOG_BUTTON}
                  data-setup-action='turn-on'
                  disabled={busy}
                  onClick={() => void turnOn()}
                  type='button'
                >
                  Turn on Live details
                </button>
              </div>
            </>
          )}
        </AlertDialog.Popup>
      </AlertDialog.Portal>
    </AlertDialog.Root>
  )
}
