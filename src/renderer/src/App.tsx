import { Tooltip } from '@base-ui/react/tooltip'
import { RegistryProvider } from './data/registry'
import { SettingsProvider } from './settings/settings-context'
import Background from './wm/Background'
import WindowManager from './wm/WindowManager'

// The app: one registry subscription, the animated background, and the window manager with all
// panels. All tooltips share one delay of 300 ms.
function App(): React.JSX.Element {
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
