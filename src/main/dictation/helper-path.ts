import { dirname, join } from 'node:path'
import { app } from 'electron'
import { findOnPath } from '../test-home'

const HELPER_NAME = 'bifrost-dictation'

export interface HelperPlace {
  packaged: boolean
  // The path of the app executable (process.execPath).
  execPath: string
  // The path of the app (app.getAppPath()).
  appPath: string
}

// electron-builder puts the speech helper next to the app executable, in Contents/MacOS
// (electron-builder.yml). A dev run uses the output of "pnpm build:dictation".
export function helperPathFor(place: HelperPlace): string {
  if (place.packaged) return join(dirname(place.execPath), HELPER_NAME)
  return join(place.appPath, 'resources', 'bin', HELPER_NAME)
}

// The path of the speech helper of this app.
export function dictationHelperPath(): string {
  return helperPathFor({
    appPath: app.getAppPath(),
    execPath: process.execPath,
    packaged: app.isPackaged,
  })
}

// The helper that the dictation service runs. A test home runs the first bifrost-dictation on the
// PATH, which is the fake helper of the smoke tests. So a test never runs the real helper and never
// opens the microphone. A test home with no fake helper on the PATH gives null.
export function helperToRun(
  inTestHome: boolean,
  pathEnv: string | undefined,
  isExecutable: (path: string) => boolean,
): string | null {
  if (inTestHome) return findOnPath(HELPER_NAME, pathEnv, isExecutable)
  return dictationHelperPath()
}
