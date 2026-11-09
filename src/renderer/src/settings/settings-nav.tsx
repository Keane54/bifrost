// The section of the Settings panel, and a way to open the panel at a section.
// It also asks the setup dialog to show the introduction again (spec 11.1).
import { createContext, useCallback, useContext, useMemo, useState } from 'react'
import { useWmControls } from '../wm/context'

export type SettingsSection = 'general' | 'slash' | 'keys' | 'reviews' | 'live'

export interface SettingsNav {
  section: SettingsSection
  setSection(section: SettingsSection): void
  // Open the Settings panel. A section argument also selects that section.
  open(section?: SettingsSection): void
  // The number of the last request to show the introduction. 0 means no request.
  introRequest: number
  // Ask the setup dialog to show the introduction again.
  showIntro(): void
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
  const open = useCallback(
    (next?: SettingsSection) => {
      if (next !== undefined) setSection(next)
      dispatch({ panelId: 'settings', type: 'open' })
    },
    [dispatch],
  )
  const showIntro = useCallback(() => setIntroRequest(n => n + 1), [])
  const value = useMemo(
    () => ({ introRequest, open, section, setSection, showIntro }),
    [introRequest, open, section, showIntro],
  )
  return <SettingsNavContext value={value}>{children}</SettingsNavContext>
}

export function useSettingsNav(): SettingsNav {
  const value = useContext(SettingsNavContext)
  if (!value) throw new Error('useSettingsNav needs a SettingsNavProvider.')
  return value
}
