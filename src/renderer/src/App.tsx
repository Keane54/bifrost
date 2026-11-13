import { Tooltip } from '@base-ui/react/tooltip'
import { useEffect } from 'react'
import { RegistryProvider } from './data/registry'
import { SettingsProvider } from './settings/settings-context'
import Background from './wm/Background'
import WindowManager from './wm/WindowManager'

// The app: one registry subscription, the animated background, and the window manager with all
// panels. All tooltips share one delay of 300 ms.
function App(): React.JSX.Element {
  // Tell the main process when the page is visible or not. A hidden page polls more slowly.
  useEffect(() => {
    const report = (): void => {
      window.bifrost.window.setVisible(document.visibilityState === 'visible').catch(() => {})
    }
    report()
    document.addEventListener('visibilitychange', report)
    return () => document.removeEventListener('visibilitychange', report)
  }, [])
  return (
    <Tooltip.Provider delay={300}>
      <RegistryProvider>
        <SettingsProvider>
          <Background />
          <WindowManager />
        </SettingsProvider>
      </RegistryProvider>
    </Tooltip.Provider>
  )
}

export default App
