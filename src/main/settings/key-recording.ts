// The state of the key recorder of Settings > Keys. While the recorder records, the menu gives
// its keys to the page, so Cmd+W gets to the recorder and does not close the panel.
export interface KeyRecording {
  // True while the recorder records. The menu builder reads it.
  get(): boolean
  // The settings:recording handler. It refuses a value that is not a boolean.
  set(on: unknown): void
  // End the recording. A new page, a gone render process or a closed window calls it, because
  // the old page cannot say that it ended.
  reset(): void
}

// A change of the state builds the menu again.
export function createKeyRecording(rebuild: () => void): KeyRecording {
  let recording = false
  const change = (on: boolean): void => {
    if (recording === on) return
    recording = on
    rebuild()
  }
  return {
    get: () => recording,
    reset: () => change(false),
    set: on => {
      if (typeof on !== 'boolean') throw new Error('refused: bad input')
      change(on)
    },
  }
}

// The part of a BrowserWindow that resetOnPageEnd uses. A test passes a fake.
export interface PageEvents {
  on(event: 'closed', listener: () => void): unknown
  webContents: {
    on(event: 'did-navigate', listener: () => void): unknown
    on(event: 'render-process-gone', listener: () => void): unknown
  }
}

// End the recording when the page of the window ends.
export function resetOnPageEnd(win: PageEvents, recording: KeyRecording): void {
  win.webContents.on('did-navigate', () => recording.reset())
  win.webContents.on('render-process-gone', () => recording.reset())
  win.on('closed', () => recording.reset())
}
