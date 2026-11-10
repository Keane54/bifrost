// The section of the Settings panel, and a way to open the panel at a section.
// It also asks the setup dialog to show the introduction again (spec 11.1), and asks the release
// notes view to open (Settings > Updates).
import { createContext, useCallback, useContext, useMemo, useState } from 'react'
import { useWmControls } from '../wm/context'

export type SettingsSection = 'general' | 'slash' | 'keys' | 'reviews' | 'live' | 'updates'

export interface SettingsNav {
  section: SettingsSection
  setSection(section: SettingsSection): void
  // Open the Settings panel. A section argument also selects that section.
  open(section?: SettingsSection): void
  // The number of the last request to show the introduction. 0 means no request.
  introRequest: number
  // Ask the setup dialog to show the introduction again.
  showIntro(): void
  // The number of the last request to show the release notes. 0 means no request.
  releaseNotesRequest: number
  // Ask the release notes view to open with the last releases.
  showReleaseNotes(): void
  // True while the setup dialog is open. What's new waits until it is false.
  setupOpen: boolean
  // The setup dialog gives its open state here at each change.
  setSetupOpen(open: boolean): void
}

const SettingsNavContext = createContext<SettingsNav | null>(null)

// It must be inside the window manager controls.
export function SettingsNavProvider({
  children,
}: {
  children: React.ReactNode
}): React.JSX.Element {
  const { dispatch } = useWmControls()
  const [section, setSection] = useState<SettingsSection>('general')
  const [introRequest, setIntroRequest] = useState(0)
  const [releaseNotesRequest, setReleaseNotesRequest] = useState(0)
  const [setupOpen, setSetupOpen] = useState(false)
  const open = useCallback(
    (next?: SettingsSection) => {
      if (next !== undefined) setSection(next)
      dispatch({ panelId: 'settings', type: 'open' })
    },
    [dispatch],
  )
  const showIntro = useCallback(() => setIntroRequest(n => n + 1), [])
  const showReleaseNotes = useCallback(() => setReleaseNotesRequest(n => n + 1), [])
  const value = useMemo(
    () => ({
      introRequest,
      open,
      releaseNotesRequest,
      section,
      setSection,
      setSetupOpen,
      setupOpen,
      showIntro,
      showReleaseNotes,
    }),
    [introRequest, open, releaseNotesRequest, section, setupOpen, showIntro, showReleaseNotes],
  )
  return <SettingsNavContext value={value}>{children}</SettingsNavContext>
}

export function useSettingsNav(): SettingsNav {
  const value = useContext(SettingsNavContext)
  if (!value) throw new Error('useSettingsNav needs a SettingsNavProvider.')
  return value
}
