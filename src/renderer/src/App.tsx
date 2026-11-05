import { RegistryProvider } from './data/registry'
import WindowManager from './wm/WindowManager'

// The app: one registry subscription, and the window manager with all panels.
function App(): React.JSX.Element {
  return (
    <RegistryProvider>
      <WindowManager />
    </RegistryProvider>
  )
}

export default App
