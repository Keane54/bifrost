import type { WatchColour } from './types'

// The colours that a watched session can have, in the order of the colour picker.
export const WATCH_COLOURS: readonly WatchColour[] = [
  'orange',
  'green',
  'lime',
  'cyan',
  'blue',
  'purple',
  'pink',
  'white',
]

// Return true if the value is one of the watch colours.
export function isWatchColour(value: unknown): value is WatchColour {
  return WATCH_COLOURS.some(colour => colour === value)
}
