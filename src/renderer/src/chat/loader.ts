// The rules of the Take control loader of a chat window (spec 9.2). This module is pure.

// The line of the loader.
export function loaderText(name: string | null): string {
  return name ? `Taking control of ${name}...` : 'Taking control...'
}

// The loader of one session. running: Take control runs. shown: the terminal showed Claude.
export interface LoaderState {
  running: boolean
  shown: boolean
}

// start: Take control starts. finish: it worked. shown: the terminal shows Claude, or it shows
// why it ended. stop: Take control failed. The loader stays until Take control worked and the
// terminal shows Claude. null means no loader.
export function loaderStep(
  state: LoaderState | null,
  event: 'start' | 'finish' | 'shown' | 'stop',
): LoaderState | null {
  switch (event) {
    case 'start':
      return { running: true, shown: false }
    case 'stop':
      return null
    case 'finish':
      if (state === null || state.shown) return null
      return { running: false, shown: false }
    case 'shown':
      if (state === null || !state.running) return null
      return { running: true, shown: true }
  }
}
