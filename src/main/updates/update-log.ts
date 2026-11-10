// The update log. The updater writes one line for each step to updater.log in the logs folder.
// It is a rotating log (see src/main/log/rotating-log.ts) with a fixed name.
import {
  createRotatingLog,
  ROTATING_LOG_MAX_BYTES,
  type RotatingLog,
  type RotatingLogDeps,
} from '../log/rotating-log'

export const LOG_NAME = 'updater.log'
export const OLD_LOG_NAME = 'updater.old.log'
export const LOG_MAX_BYTES = ROTATING_LOG_MAX_BYTES

export type UpdateLog = RotatingLog
export type UpdateLogDeps = RotatingLogDeps

export function createUpdateLog(dir: string, deps: UpdateLogDeps): UpdateLog {
  return createRotatingLog(dir, LOG_NAME, deps)
}
