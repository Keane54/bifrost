// The page check of each IPC handler (global constraint: each handler goes through fromPage).
// Only the top frame of the live Bifrost page can send a message. The preload runs only in that
// frame, so a frame inside the page, for example a module frame, has no ipcRenderer. This check
// refuses such a frame also when a bug gives it a way to send.

export const REFUSED_NOT_PAGE = 'refused: not the Bifrost page'

// The parts of an IPC event that the check reads. Electron gives the same object for a frame at
// each event, so a compare of the objects finds the top frame. senderFrame is null when the frame
// is gone.
export interface PageEvent<S extends { mainFrame: unknown }> {
  sender: S
  senderFrame: unknown
}

export type FromPage<S extends { mainFrame: unknown }> = <T>(
  e: PageEvent<S>,
  fn: () => Promise<T>,
) => Promise<T>

// fromPage with the check of the live page. The live check comes first, because a web contents
// that is destroyed can throw when a call reads its main frame.
export function createFromPage<S extends { mainFrame: unknown }>(
  isLive: (sender: S) => boolean,
): FromPage<S> {
  return (e, fn) => {
    if (!isLive(e.sender) || e.senderFrame === null || e.senderFrame !== e.sender.mainFrame) {
      return Promise.reject(new Error(REFUSED_NOT_PAGE))
    }
    return fn()
  }
}
