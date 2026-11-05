// The class lookups of the watch colours. Tailwind finds only full class names in the source.
// So these lookups hold full names. The tokens are in styles/app.css.
import type { WatchColour } from '../../../shared/types'

// The row background: the watch colour at about 25%.
export const WATCH_ROW_BG: Record<WatchColour, string> = {
  blue: 'bg-watch-blue/25',
  cyan: 'bg-watch-cyan/25',
  green: 'bg-watch-green/25',
  lime: 'bg-watch-lime/25',
  orange: 'bg-watch-orange/25',
  pink: 'bg-watch-pink/25',
  purple: 'bg-watch-purple/25',
  white: 'bg-watch-white/25',
}

// The small square of a colour in the colour menu.
export const WATCH_SWATCH: Record<WatchColour, string> = {
  blue: 'bg-watch-blue',
  cyan: 'bg-watch-cyan',
  green: 'bg-watch-green',
  lime: 'bg-watch-lime',
  orange: 'bg-watch-orange',
  pink: 'bg-watch-pink',
  purple: 'bg-watch-purple',
  white: 'bg-watch-white',
}
