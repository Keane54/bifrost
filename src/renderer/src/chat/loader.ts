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

// The time limit of a loader that waits only for the first output, after a good Take control
// (review Important 2). Then the window shows the terminal, with its note when it cannot attach.
export const LOADER_WAIT_MS = 20_000

export type LoaderEvent = 'start' | 'finish' | 'shown' | 'stop' | 'timeout'

// True when the loader waits only for the first output. The time limit then runs.
export function loaderWaits(state: LoaderState | null): boolean {
  return state !== null && !state.running
}

// start: Take control starts. finish: it worked. shown: the terminal shows Claude, or it shows
// why it ended. stop: Take control failed. timeout: the time limit of a loader that waits only for
// the first output. The loader stays until Take control worked and the terminal shows Claude, or
// until the time limit. null means no loader.
export function loaderStep(state: LoaderState | null, event: LoaderEvent): LoaderState | null {
  switch (event) {
    case 'timeout':
      return loaderWaits(state) ? null : state
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
