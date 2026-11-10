// The state of the Bifrost skills for the renderer. The setup dialog and Settings > Skills read
// it. Each action runs one at a time, as in Live details.
import { createContext, useCallback, useContext, useEffect, useMemo, useRef, useState } from 'react'
import { BUSY_MESSAGE } from '../../../shared/live'
import type { SkillsStatus } from '../../../shared/skills'
import { friendlyError } from '../actions/errors'
import { errorMessage } from '../lib/error-message'
import { type SkillsNotice, skillsNotice } from './skills-notice'

export interface SkillsValue {
  // null until the first skills.status() resolves.
  status: SkillsStatus | null
  notice: SkillsNotice
  // True while a call runs. One call runs at a time.
  busy: boolean
  // True after a good install or enable, until the next action.
  changed: boolean
  // Load the status again. It never rejects: a failure gives an unknown status with the reason.
  refresh(): Promise<void>
  // Each action rejects with the friendly message of the skills.* call.
  install(): Promise<void>
  enable(): Promise<void>
  disable(): Promise<void>
  uninstall(): Promise<void>
}

const SkillsContext = createContext<SkillsValue | null>(null)

// The status when the status call fails. The notice then shows the reason and Try again.
function unknownStatus(message: string): SkillsStatus {
  return { error: message, folderCurrent: false, plugin: 'unknown', skills: [] }
}

function loadStatus(): Promise<SkillsStatus> {
  return window.bifrost.skills
    .status()
    .catch(err => unknownStatus(friendlyError(errorMessage(err))))
}

export function SkillsProvider({ children }: { children: React.ReactNode }): React.JSX.Element {
  const [status, setStatus] = useState<SkillsStatus | null>(null)
  const [busy, setBusy] = useState(false)
  const [changed, setChanged] = useState(false)
  // The ref stops a second call before the next render shows busy.
  const running = useRef(false)
  const mounted = useRef(true)

  // Load the status one time at mount.
  useEffect(() => {
    mounted.current = true
    void loadStatus().then(next => {
      if (mounted.current) setStatus(prev => prev ?? next)
    })
    return () => {
      mounted.current = false
    }
  }, [])

  // Run one call with the lock. A call that comes while another call runs rejects.
  const locked = useCallback(async (fn: () => Promise<void>): Promise<void> => {
    if (running.current) throw new Error(BUSY_MESSAGE)
    running.current = true
    setBusy(true)
    try {
      await fn()
    } finally {
      running.current = false
      if (mounted.current) setBusy(false)
    }
  }, [])

  const refresh = useCallback(async (): Promise<void> => {
    // A refresh during an action does nothing. The action sets the status when it ends.
    if (running.current) return
    await locked(async () => {
      const next = await loadStatus()
      if (mounted.current) setStatus(next)
    })
  }, [locked])

  // Run an action. A good install or enable sets changed, so the reload note shows. A failure
  // reads the status again, and then rejects with the message of the call.
  const action = useCallback(
    (call: () => Promise<SkillsStatus>, marksChange: boolean) => (): Promise<void> =>
      locked(async () => {
        setChanged(false)
        try {
          const next = await call()
          if (!mounted.current) return
          setStatus(next)
          if (marksChange) setChanged(true)
        } catch (err) {
          const next = await loadStatus()
          if (mounted.current) setStatus(next)
          throw new Error(friendlyError(errorMessage(err)))
        }
      }),
    [locked],
  )

  const value = useMemo<SkillsValue>(
    () => ({
      busy,
      changed,
      disable: action(() => window.bifrost.skills.disable(), false),
      enable: action(() => window.bifrost.skills.enable(), true),
      install: action(() => window.bifrost.skills.install(), true),
      notice: skillsNotice(status),
      refresh,
      status,
      uninstall: action(() => window.bifrost.skills.uninstall(), false),
    }),
    [action, busy, changed, refresh, status],
  )

  return <SkillsContext value={value}>{children}</SkillsContext>
}

export function useSkills(): SkillsValue {
  const value = useContext(SkillsContext)
  if (!value) throw new Error('useSkills needs a SkillsProvider.')
  return value
}
