// The section of the Settings panel, and a way to open the panel at a section.
import { createContext, useCallback, useContext, useMemo, useState } from 'react'
import { useWmControls } from '../wm/context'

export type SettingsSection = 'general' | 'slash' | 'keys' | 'live'

export interface SettingsNav {
  section: SettingsSection
  setSection(section: SettingsSection): void
  // Open the Settings panel. A section argument also selects that section.
  open(section?: SettingsSection): void
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
  const open = useCallback(
    (next?: SettingsSection) => {
      if (next !== undefined) setSection(next)
      dispatch({ panelId: 'settings', type: 'open' })
    },
    [dispatch],
  )
  const value = useMemo(() => ({ open, section, setSection }), [open, section])
  return <SettingsNavContext value={value}>{children}</SettingsNavContext>
}

export function useSettingsNav(): SettingsNav {
  const value = useContext(SettingsNavContext)
  if (!value) throw new Error('useSettingsNav needs a SettingsNavProvider.')
  return value
}
