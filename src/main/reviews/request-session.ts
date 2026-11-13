// The start of a request session for a PR of the user (design 6 and 12): a claude --bg session in
// the worktree of the PR. It fixes and answers the review comments, and writes its result file.
// Bash runs in the sandbox of Claude Code. The network allows only the package registries, and no
// GitHub host. The session cannot commit, cannot send the fix to GitHub and cannot run gh.
// Bifrost does these steps itself after it checks the result. The start uses ReviewSessions.start,
// so a request session gets the same PR session rule as a review session. Before the start,
// readUserSandboxProblem checks the user settings, because they load in the session.

import { constants, realpathSync } from 'node:fs'
import { type FileHandle, open } from 'node:fs/promises'
import { join } from 'node:path'
import type { ModelChoice } from '../../shared/new-session'
import { isRecord } from '../../shared/plain-object'
import { NO_STATUSLINE_SETTINGS } from '../actions/session-actions'
import {
  REASON_USER_FOLDERS,
  REASON_USER_SANDBOX,
  REASON_USER_SANDBOX_OFF,
  REASON_USER_SETTINGS_UNREADABLE,
} from './round-text'

// The tools of a request session. It has no AskUserQuestion tool, so it never waits for a person.
export const REQUEST_TOOLS: readonly string[] = [
  'Bash',
  'Read',
  'Glob',
  'Grep',
  'Edit',
  'Write',
  'Skill',
]

// The package registries that the sandbox network allows. No entry is a GitHub host. No entry is a
// proxy that fetches a module from any host, as the Go module proxy does.
export const REGISTRY_DOMAINS: readonly string[] = [
  'registry.npmjs.org',
  'registry.yarnpkg.com',
  'repo.yarnpkg.com',
  'pypi.org',
  'files.pythonhosted.org',
  'index.crates.io',
  'static.crates.io',
  'rubygems.org',
  'index.rubygems.org',
  'repo.maven.apache.org',
  'repo1.maven.org',
  'plugins.gradle.org',
  'services.gradle.org',
  'api.nuget.org',
]

// The secret files and folders in the home folder. The session cannot read them.
export const SECRET_PATHS: readonly string[] = [
  '~/.ssh',
  '~/.gnupg',
  '~/.aws',
  '~/.config/gh',
  '~/.netrc',
  '~/.git-credentials',
  '~/.docker',
  '~/.kube',
  '~/Library/Keychains',
]

// The secret paths that are files. Each other secret path is a folder.
const SECRET_FILES: ReadonlySet<string> = new Set(['~/.netrc', '~/.git-credentials'])

// The setting sources of a request session: the user settings only. The settings of the PR head
// do not load. So the CLAUDE.md of the repository does not load either, and the skill reads it
// with the Read tool.
export const REQUEST_SETTING_SOURCES = 'user'

// The deny rule for the reads of a secret path. A rule with /** does not match a file, so the
// rule of a file names the file. The rule of a folder names all of its files.
const readRule = (path: string): string =>
  SECRET_FILES.has(path) ? `Read(${path})` : `Read(${path}/**)`

// The --settings value of a request session, for the clone of the PR. One argument, and no shell
// reads it.
// - No statusline, and no hooks at all. A PR head can hold a .claude folder with hooks.
// - The sandbox is on. Bash runs in it with no prompt, and no command can run outside it.
// - The network allows only REGISTRY_DOMAINS. The strict allow list also refuses a Bash call
//   that asks for one more host.
// - Bash cannot write the .git folder of the clone. The worktree of the PR is a linked worktree,
//   so its git data is in that folder, and Bifrost runs git there.
// - Edit and Write cannot write outside the worktree and the input folder.
// - The deny list stops a commit, the push, gh, the web tools and the reads of SECRET_PATHS. It
//   also stops Edit and Write in the .git folder of the clone, so that block does not rest on
//   one key only. A rule path that starts with // is an absolute path.
// The clone path must be the real path that Claude Code compares. requestSessionArgs gives it.
export function requestSettings(clone: string): string {
  const gitDir = join(clone, '.git')
  return JSON.stringify({
    ...JSON.parse(NO_STATUSLINE_SETTINGS),
    disableAllHooks: true,
    permissions: {
      blockWritesOutsideWorkingDirectories: true,
      deny: [
        'Bash(git push:*)',
        'Bash(git commit:*)',
        'Bash(gh:*)',
        'WebFetch',
        'WebSearch',
        ...SECRET_PATHS.map(readRule),
        `Edit(/${gitDir}/**)`,
        `Write(/${gitDir}/**)`,
      ],
    },
    sandbox: {
      allowUnsandboxedCommands: false,
      autoAllowBashIfSandboxed: true,
      enabled: true,
      filesystem: { denyWrite: [gitDir] },
      network: { allowedDomains: [...REGISTRY_DOMAINS], strictAllowlist: true },
    },
  })
}

// The prompt of a request session. It names the input file.
export function requestPrompt(inputFile: string): string {
  return `/bifrost-resolve-comments bifrost-input=${inputFile}`
}

// The arguments of "claude --bg" for a request session. The prompt is last. A flag with many
// values (--tools, --add-dir, --plugin-dir) never comes right before it. There is no
// --restricted, because the session needs Bash and the CLAUDE.md of the repository. Claude Code
// compares real paths, so the path rules use the real path of the clone, and --add-dir gets the
// real path of the input folder. A folder with no real path throws.
export function requestSessionArgs(o: {
  clone: string
  ioDir: string
  pluginDir: string
  model: ModelChoice
  name: string
  prompt: string
}): string[] {
  const clone = realpathSync.native(o.clone)
  const ioDir = realpathSync.native(o.ioDir)
  const args = [
    '--bg',
    '--setting-sources',
    REQUEST_SETTING_SOURCES,
    '--strict-mcp-config',
    '--tools',
    ...REQUEST_TOOLS,
    '--permission-mode',
    'auto',
    '--add-dir',
    ioDir,
    '--plugin-dir',
    o.pluginDir,
    '--settings',
    requestSettings(clone),
  ]
  if (o.model !== '') args.push('--model', o.model)
  args.push('--name', o.name, o.prompt)
  return args
}

// Bifrost refuses a user settings file above this size.
export const MAX_USER_SETTINGS_BYTES = 1024 * 1024

// The user settings file of Claude Code in the home folder. Bifrost gives the same home folder as
// for ~/.claude.json, so a test home uses its own file.
export function claudeSettingsFile(home: string): string {
  return join(home, '.claude', 'settings.json')
}

// The problem of the user settings for a request session, or null. The user settings load in the
// session (REQUEST_SETTING_SOURCES), and Claude Code merges some of their sandbox and permission
// values with the values of requestSettings. So the sandbox of the user settings can hold only
// enabled: true and autoAllowBashIfSandboxed. Each other key, also a key that a later Claude Code
// adds, can change the network or the file rules. The user settings must also give no more
// working folders. A text that is not a JSON object is a problem too. A reason names no value.
export function userSandboxProblem(text: string): string | null {
  let data: unknown
  try {
    data = JSON.parse(text)
  } catch {
    return REASON_USER_SETTINGS_UNREADABLE
  }
  if (!isRecord(data)) return REASON_USER_SETTINGS_UNREADABLE
  if (Object.hasOwn(data, 'sandbox')) {
    const { sandbox } = data
    if (!isRecord(sandbox)) return REASON_USER_SANDBOX
    if (sandbox.enabled === false) return REASON_USER_SANDBOX_OFF
    for (const [name, value] of Object.entries(sandbox)) {
      if (name === 'autoAllowBashIfSandboxed' || (name === 'enabled' && value === true)) continue
      return REASON_USER_SANDBOX
    }
  }
  const { permissions } = data
  if (isRecord(permissions) && Object.hasOwn(permissions, 'additionalDirectories')) {
    const more = permissions.additionalDirectories
    if (!Array.isArray(more) || more.length > 0) return REASON_USER_FOLDERS
  }
  return null
}

// Read the user settings file, and give its problem for a request session, or null. A missing
// file is no problem. A file that is not a regular file, is over MAX_USER_SETTINGS_BYTES or
// cannot be read is a problem. A link to a regular file counts as that file, because Claude Code
// reads the file that it links to. Bifrost never writes the file and never logs its content.
export async function readUserSandboxProblem(file: string): Promise<string | null> {
  let handle: FileHandle
  try {
    // With O_NONBLOCK, the open of a FIFO does not wait for a writer.
    handle = await open(file, constants.O_RDONLY | constants.O_NONBLOCK)
  } catch (error) {
    const code = (error as { code?: unknown } | null)?.code
    return code === 'ENOENT' ? null : REASON_USER_SETTINGS_UNREADABLE
  }
  try {
    const info = await handle.stat()
    if (!info.isFile() || info.size > MAX_USER_SETTINGS_BYTES) {
      return REASON_USER_SETTINGS_UNREADABLE
    }
    // The file can get larger after the stat, so the read stops after the cap.
    const buffer = Buffer.alloc(MAX_USER_SETTINGS_BYTES + 1)
    let length = 0
    while (length < buffer.length) {
      const { bytesRead } = await handle.read(buffer, length, buffer.length - length, length)
      if (bytesRead === 0) break
      length += bytesRead
    }
    if (length > MAX_USER_SETTINGS_BYTES) return REASON_USER_SETTINGS_UNREADABLE
    return userSandboxProblem(buffer.toString('utf8', 0, length))
  } catch {
    return REASON_USER_SETTINGS_UNREADABLE
  } finally {
    await handle.close().catch(() => undefined)
  }
}
