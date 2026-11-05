import type { WatchColour } from './types'

// The colours that a watched session can have, in the order of the colour picker.
export const WATCH_COLOURS: readonly WatchColour[] = [
  'dark-red',
  'red',
  'amber',
  'yellow',
  'green',
  'light-blue',
  'dark-blue',
  'white',
]

// The names that earlier versions saved, and the colour that replaces each name.
export const OLD_WATCH_COLOURS: Record<string, WatchColour> = {
  blue: 'dark-blue',
  cyan: 'light-blue',
  green: 'green',
  lime: 'green',
  orange: 'amber',
  pink: 'red',
  purple: 'dark-blue',
  white: 'white',
}

// Return true if the value is one of the watch colours.
export function isWatchColour(value: unknown): value is WatchColour {
  return WATCH_COLOURS.some(colour => colour === value)
}

// The colour that a watch button without a colour choice uses.
export const DEFAULT_WATCH_COLOUR: WatchColour = 'light-blue'
