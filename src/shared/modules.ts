import type { ModuleIcon, ModulePanel, ModulePermission, PermissionId } from './module-manifest'
import type { ModelChoice } from './new-session'

// One module as the UI shows it.
export interface ModuleRow {
  id: string
  name: string
  version: string
  description: string
  tier: 'standard' | 'permissive'
  // True when the module runs. A packaged app gives false for a dev module.
  enabled: boolean
  dev: boolean
  sourceKind: 'folder' | 'git' | 'dev'
  // The folder or the GitHub URL of the source, as text. A folder in the home folder starts
  // with ~.
  source: string
  panels: ModulePanel[]
  requested: ModulePermission[]
  granted: PermissionId[]
  model: ModelChoice
  dailyCap: number
  jobsToday: number
  waitingJobs: number
  pendingUpdate: { version: string; added: ModulePermission[] } | null
  // The reason when Bifrost keeps the module off and the user did not turn it off, else null.
  offReason: string | null
}

export interface ModulesSnapshot {
  modules: ModuleRow[]
}

// One permission in Heimdall's approval view. added is true for a permission that an update
// adds.
export interface ApprovalPermission {
  id: PermissionId
  reason: string
  added: boolean
}

// An approval request of Heimdall (Modules design 7). Bifrost shows it in Heimdall's panel. The
// texts come from the manifest that the parser accepted. The page shows them as plain text only.
export interface ModuleApproval {
  requestId: string
  kind: 'install' | 'update'
  moduleId: string
  name: string
  version: string
  // The version that runs now, for an update. null for an install.
  fromVersion: string | null
  description: string
  tier: 'standard' | 'permissive'
  // The icon of the first panel. It is a name of the fixed list.
  icon: ModuleIcon
  sourceKind: 'folder' | 'git' | 'dev'
  // The folder or the GitHub URL of the source.
  source: string
  // All permissions of the manifest that the user allows, in the order of the manifest.
  permissions: ApprovalPermission[]
}

// One text card of a module in the Discuss view (Modules design 8.4). Claude does not see it. The
// user can copy it through Heimdall.
export interface DiscussCard {
  label: string
  text: string
}

// A request of a module for Discuss with Claude (plan Task 10). Heimdall shows it in its panel.
// It holds no prompt, so the prompt box always starts empty. The page shows the texts as plain
// text only. Heimdall removed their invisible characters.
export interface ModuleDiscuss {
  requestId: string
  moduleId: string
  // The approved name of the module.
  moduleName: string
  title: string
  cards: DiscussCard[]
}

// The result of Check for updates for one module. same: no change. updated: the new version
// runs. waiting: the new version needs a new permission, so the old version runs until the user
// allows it. failed: Bifrost could not check the module, and reason says why.
export type ModuleUpdateResult =
  | { id: string; name: string; outcome: 'same' | 'updated' | 'waiting'; version: string }
  | { id: string; name: string; outcome: 'failed'; reason: string }

// The caps of the module bridge (plan Task 5). The bridge in the renderer and Heimdall in the
// main process both apply them. The safety comes only from the check in the main process.
// The most calls that one module can make in one second.
export const MODULE_RATE = 100
// The most calls of one module that can wait for an answer at the same time.
export const MODULE_IN_FLIGHT = 32
// The most UTF-8 bytes of the JSON of one message, in each direction.
export const MODULE_MESSAGE_BYTES = 256 * 1024
// The longest call name.
export const MODULE_CALL_NAME_MAX = 64

// The refusal codes of a module call. A module gets the code as the error of its call.
export const REFUSED_MODULE_OFF = 'refused: module off'
export const REFUSED_NOT_ALLOWED = 'refused: not allowed for this module'
export const REFUSED_UNKNOWN_CALL = 'refused: unknown module call'
export const REFUSED_BAD_MODULE_INPUT = 'refused: bad module input'
export const REFUSED_TOO_MANY_CALLS = 'refused: too many module calls'
export const REFUSED_MESSAGE_TOO_LARGE = 'refused: module message too large'
export const REFUSED_STORAGE_FULL = 'refused: module storage is full'
export const REFUSED_CALL_FAILED = 'refused: module call failed'
// The refusal codes of a module job of a module (plan Task 7).
export const REFUSED_JOB_CAP = 'refused: daily job cap reached'
export const REFUSED_JOB_CANCELLED = 'refused: job cancelled'
export const REFUSED_JOB_TOO_LONG = 'refused: the job took too long'
export const REFUSED_JOB_FAILED = 'refused: the job failed'
export const REFUSED_JOB_NOT_JSON = 'refused: the job result is not JSON'
// The refusal codes of the install, the update and the settings of a module (plan Task 9).
export const REFUSED_NO_REQUEST = 'refused: no such module request'
export const REFUSED_DEV_ONLY = 'refused: developer modules need a development build'
export const REFUSED_BAD_GIT_URL = 'refused: not a GitHub repository URL'
export const REFUSED_MODULE_INSTALLED = 'refused: module already installed'
export const REFUSED_MODULE_CHANGED = 'refused: the module changed'
export const REFUSED_UNKNOWN_MODULE = 'refused: unknown module'
export const REFUSED_CLONE_FAILED = 'refused: the git clone failed'
export const REFUSED_BAD_CAP = 'refused: bad daily cap'
export const REFUSED_UNKNOWN_MODEL = 'refused: unknown model'
// The refusal codes of Discuss with Claude (plan Task 10).
export const REFUSED_DISCUSS_OPEN = 'refused: a discuss request is open'
export const REFUSED_DISCUSS_WAIT = 'refused: discuss asked too soon'

// The UTF-8 bytes of the JSON text of a value, or null when JSON cannot hold the value (a cycle
// or a BigInt). undefined gives 0.
export function jsonBytes(value: unknown): number | null {
  let text: string | undefined
  try {
    text = JSON.stringify(value)
  } catch {
    return null
  }
  return text === undefined ? 0 : new TextEncoder().encode(text).length
}
