import './styles/app.css'
import '@xterm/xterm/css/xterm.css'

import { createRoot } from 'react-dom/client'
import App from './App'

// No StrictMode here. In dev it runs each effect two times.
// That would end the chat terminals and start each claude attach again.
const root = document.getElementById('root')
if (!root) throw new Error('Bifrost cannot start: index.html has no element with the ID root.')
createRoot(root).render(<App />)
