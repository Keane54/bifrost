// The settings of the app for the renderer (spec 12). The main process keeps the real values.
// This context shows them and sends each change (D1).
import { createContext, useCallback, useContext, useEffect, useMemo, useState } from 'react'
import { DEFAULT_SETTINGS, type Settings, type SettingsPatch } from '../../../shared/settings'

export interface SettingsValue {
  // The defaults until the first settings.get resolves.
  settings: Settings
  ready: boolean
  // Rejects with the reason of the main process.
  update(patch: SettingsPatch): Promise<void>
}

const SettingsContext = createContext<SettingsValue | null>(null)

export function SettingsProvider({ children }: { children: React.ReactNode }): React.JSX.Element {
  const [settings, setSettings] = useState<Settings>(DEFAULT_SETTINGS)
  const [ready, setReady] = useState(false)

  useEffect(() => {
    let active = true
    // A change event can come before the first get resolves. The event is newer, so it wins.
    let gotEvent = false
    const off = window.bifrost.settings.onChange(next => {
      gotEvent = true
      if (active) setSettings(next)
    })
    window.bifrost.settings.get().then(
      first => {
        if (!active) return
        if (!gotEvent) setSettings(first)
        setReady(true)
      },
      err => console.error('Bifrost cannot get the settings. It uses the defaults.', err),
    )
    return () => {
      active = false
      off()
    }
  }, [])

  const update = useCallback(async (patch: SettingsPatch): Promise<void> => {
    setSettings(await window.bifrost.settings.set(patch))
  }, [])

  const value = useMemo(() => ({ ready, settings, update }), [ready, settings, update])

  // Panel transparency (ruling C1): the panels use --panel-alpha for their background.
  useEffect(() => {
    document.documentElement.style.setProperty(
      '--panel-alpha',
      String(1 - settings.panelTransparency / 100),
    )
  }, [settings.panelTransparency])

  return <SettingsContext value={value}>{children}</SettingsContext>
}

export function useSettings(): SettingsValue {
  const value = useContext(SettingsContext)
  if (!value) throw new Error('useSettings needs a SettingsProvider.')
  return value
}
