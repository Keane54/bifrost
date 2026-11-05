// The values of the New session dialog and the checks on them (spec 8.9, D8).
// The renderer uses the checks to show a reason early. The main process checks the values again.
import { cleanText, MAX_TEXT, REASON_TOO_LONG } from './input'

export type ModelChoice = '' | 'opus' | 'sonnet' | 'haiku'

// The empty value gives no --model flag. Then claude uses its default model.
export const MODEL_CHOICES: readonly { value: ModelChoice; label: string }[] = Object.freeze([
  { label: 'Default', value: '' },
  { label: 'Opus', value: 'opus' },
  { label: 'Sonnet', value: 'sonnet' },
  { label: 'Haiku', value: 'haiku' },
])

// The choices of "claude --help" without bypassPermissions (M4 Task 1).
// The empty value means Default and gives no flag.
export const PERMISSION_MODES: readonly string[] = Object.freeze([
  'acceptEdits',
  'auto',
  'manual',
  'dontAsk',
  'plan',
])

// M4 Task 1: "--worktree <name>" works in a trusted repository.
export const WORKTREE_OK: boolean = true

export const MAX_NAME = 64
// The maximum length of a worktree name. Claude Code adds "worktree-" to it for the branch name.
const MAX_WORKTREE_NAME = 40

// The top-level commands and aliases of claude, also the hidden ones, and "help".
// The prompt is the last argument of "claude --bg". claude reads a prompt that is only
// one of these names as that command, for example "update" (Task 4 review).
// test/fixtures/claude-commands.txt holds the "claude --help" text of 2.1.318. The list also
// keeps "config" and "migrate-installer" from older versions. An extra name only refuses
// a one-word prompt, so the list can have more names than claude.
export const CLAUDE_COMMANDS: readonly string[] = Object.freeze([
  'agents',
  'attach',
  'auth',
  'auto-mode',
  'config',
  'design-login',
  'doctor',
  'drop-worktree-registrations',
  'edit-chrome-settings',
  'edit-hook',
  'edit-memory-settings',
  'edit-permission-rules',
  'edit-sandbox-settings',
  'edit-skill-overrides',
  'gateway',
  'help',
  'import',
  'import-conversations',
  'install',
  'kill',
  'logs',
  'mcp',
  'migrate-installer',
  'plugin',
  'plugins',
  'project',
  'purge',
  'rc',
  'remote-control',
  'respawn',
  'rm',
  'sandbox',
  'setup-token',
  'stop',
  'ultrareview',
  'update',
  'upgrade',
])

export const REASON_PROMPT_IS_COMMAND =
  'That prompt is also a Claude command name. Add a few more words.'
export const REASON_PROMPT_FLAG = 'The first prompt cannot start with "-".'

// True when the text, after the trim, is a claude command name.
export function isClaudeCommand(text: string): boolean {
  return CLAUDE_COMMANDS.includes(text.trim())
}

export interface NewSessionSpec {
  cwd: string
  name: string
  model: ModelChoice
  permissionMode: string
  prompt: string
  worktree: boolean
}

// What the main process found at a path. git is true for a directory in a git repository.
export interface DirInfo {
  kind: 'dir' | 'missing' | 'other'
  git: boolean
}

// Texts that users read in the app. The main process and the renderer use the same strings.
export const REASON_WORKTREE_OFF =
  "Worktrees don't work with background sessions in this version of Claude Code."
export const REASON_DIR_CHECK = 'Checking the folder...'
export const REASON_DIR_CHECK_FAILED = "Bifrost couldn't check this folder."
export const REASON_DIR_MISSING = "This folder doesn't exist."
export const REASON_NO_GIT = "This folder isn't in a git repository, so it can't use a worktree."

export type SpecCheck = { ok: true; spec: NewSessionSpec } | { ok: false; reason: string }

const BAD_DATA = 'refused: bad new session data'

function refuse(reason: string): SpecCheck {
  return { ok: false, reason }
}

// Remove the trailing "/" characters. The root directory stays "/".
function trimDir(path: string): string {
  const trimmed = path.replace(/\/+$/, '')
  return trimmed === '' && path.startsWith('/') ? '/' : trimmed
}

// Check the values of the dialog. The first failure gives the reason.
// The result holds the clean values. A name or a prompt cannot start with "-",
// because claude then reads it as a flag. A prompt cannot be only a command name.
export function checkNewSessionSpec(input: unknown): SpecCheck {
  if (typeof input !== 'object' || input === null || Array.isArray(input)) return refuse(BAD_DATA)
  const v = input as Record<string, unknown>
  const cwd = typeof v.cwd === 'string' ? trimDir(v.cwd.trim()) : ''
  if (!cwd.startsWith('/')) return refuse('Choose a project folder.')
  if (typeof v.name !== 'string') return refuse(BAD_DATA)
  const name = cleanText(v.name).trim()
  if (name === '') return refuse('Type a name.')
  if (name.length > MAX_NAME) {
    return refuse(`The name is too long. The maximum is ${MAX_NAME} characters.`)
  }
  if (/[\t\n]/.test(name)) return refuse('The name has one line.')
  if (name.startsWith('-')) return refuse('The name cannot start with "-".')
  const model = MODEL_CHOICES.find(choice => choice.value === v.model)?.value
  if (model === undefined) return refuse('refused: unknown model')
  const mode = v.permissionMode
  if (typeof mode !== 'string' || (mode !== '' && !PERMISSION_MODES.includes(mode))) {
    return refuse('refused: unknown permission mode')
  }
  if (typeof v.prompt !== 'string') return refuse(BAD_DATA)
  const prompt = cleanText(v.prompt).trim()
  if (prompt.length > MAX_TEXT) return refuse(REASON_TOO_LONG)
  if (prompt.startsWith('-')) return refuse(REASON_PROMPT_FLAG)
  if (isClaudeCommand(prompt)) return refuse(REASON_PROMPT_IS_COMMAND)
  if (typeof v.worktree !== 'boolean') return refuse(BAD_DATA)
  if (v.worktree && !WORKTREE_OK) return refuse('refused: the worktree option is off')
  return {
    ok: true,
    spec: { cwd, model, name, permissionMode: mode, prompt, worktree: v.worktree },
  }
}

// Make the name of the git worktree from the session name.
// Each run of characters outside a-z and 0-9 becomes one "-". An empty result gives "session".
export function worktreeName(name: string): string {
  const trimEnds = (text: string): string => text.replace(/^-+|-+$/g, '')
  const base = trimEnds(name.toLowerCase().replace(/[^a-z0-9]+/g, '-'))
  const cut = trimEnds(base.slice(0, MAX_WORKTREE_NAME))
  return cut === '' ? 'session' : cut
}
