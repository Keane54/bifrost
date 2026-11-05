// The class lookups of the watch colours. Tailwind finds only full class names in the source.
// So these lookups hold full names. The tokens are in styles/app.css.
import type { WatchColour } from '../../../shared/types'

// The row background: the watch colour at 12%.
export const WATCH_ROW_BG: Record<WatchColour, string> = {
  amber: 'bg-watch-amber/12',
  'dark-blue': 'bg-watch-dark-blue/12',
  'dark-red': 'bg-watch-dark-red/12',
  green: 'bg-watch-green/12',
  'light-blue': 'bg-watch-light-blue/12',
  red: 'bg-watch-red/12',
  white: 'bg-watch-white/12',
  yellow: 'bg-watch-yellow/12',
}

// The small square of a colour in the colour menu.
export const WATCH_SWATCH: Record<WatchColour, string> = {
  amber: 'bg-watch-amber',
  'dark-blue': 'bg-watch-dark-blue',
  'dark-red': 'bg-watch-dark-red',
  green: 'bg-watch-green',
  'light-blue': 'bg-watch-light-blue',
  red: 'bg-watch-red',
  white: 'bg-watch-white',
  yellow: 'bg-watch-yellow',
}
