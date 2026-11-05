import './styles/app.css'
import '@xterm/xterm/css/xterm.css'

import { createRoot } from 'react-dom/client'
import App from './App'

// No StrictMode here. In dev it mounts each TerminalView twice.
// That would start an extra claude attach for each view.
createRoot(document.getElementById('root')!).render(<App />)
