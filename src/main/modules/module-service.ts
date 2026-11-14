// The install, the update and the removal of modules (Modules design 7, plan Task 9).
//
// An install copies the module into modules/<id>/next, or clones a GitHub repository first. The
// module does not run until the user clicks Allow in Heimdall's panel. Allow moves next to
// current and saves the entry with all requested permissions. Cancel deletes next. A dev module
// (only in a development build) runs from its folder in place, and nothing is copied.
//
// Check for updates copies or clones each module again. A new version with the same or fewer
// permissions runs at once. A new version that asks for more permissions waits in next, and the
// old version runs until the user allows the update.
//
// The module itself can change nothing here. Only Bifrost's own Settings and Heimdall's panel
// send these actions.

import { randomUUID } from 'node:crypto'
import { mkdir, readdir, readFile, rename, rm, stat } from 'node:fs/promises'
import { dirname, join } from 'node:path'
import {
  MODULE_ID_PATTERN,
  type ModuleManifest,
  PERMISSION_IDS,
  type PermissionId,
  parseManifest,
  permissionDiff,
} from '../../shared/module-manifest'
import {
  type ModuleApproval,
  type ModuleUpdateResult,
  REFUSED_BAD_CAP,
  REFUSED_BAD_GIT_URL,
  REFUSED_BAD_MODULE_INPUT,
  REFUSED_CALL_FAILED,
  REFUSED_CLONE_FAILED,
  REFUSED_DEV_ONLY,
  REFUSED_MODULE_CHANGED,
  REFUSED_MODULE_INSTALLED,
  REFUSED_NO_REQUEST,
  REFUSED_NOT_ALLOWED,
  REFUSED_UNKNOWN_MODEL,
  REFUSED_UNKNOWN_MODULE,
} from '../../shared/modules'
import { MODEL_VALUES, type ModelChoice } from '../../shared/new-session'
import { compareVersions } from '../../shared/release-notes'
import { NO_PROMPT_CONFIG, type RepoGit } from '../reviews/repo-git'
import { copyModule, hashModule } from './module-files'
import {
  type ModuleEntry,
  type ModuleSource,
  type ModulesState,
  moduleCodeDir,
  moduleDataFile,
} from './module-state'

// The daily cap of the module jobs of a module that suggests no cap.
export const DEFAULT_DAILY_CAP = 50
// The longest time of the clone of a module repository.
export const MODULE_CLONE_TIMEOUT_MS = 300_000

const MANIFEST_FILE = 'bifrost-module.json'
const NEWER_BIFROST = 'This module needs a newer version of Bifrost.'
// The folder of the temporary clones, in the modules folder. The name starts with a dot, so it is
// never a module id.
const INCOMING = '.incoming'
// The slot of the old code during the swap of an update.
const OLD_SLOT = 'old'
const MAX_CAP = 500
const MAX_LOG_TEXT = 200
// https://github.com/<owner>/<repo>, with or without .git. An owner has letters, digits and
// hyphens, and does not start with a hyphen. A repository has letters, digits, ".", "_" and "-".
const GITHUB_URL =
  /^https:\/\/github\.com\/([A-Za-z0-9][A-Za-z0-9-]{0,38})\/([A-Za-z0-9._-]{1,100})$/

export interface ModuleServiceDeps {
  // The Bifrost folder. The modules go to modules/ and their storage to modules-data/.
  bifrostHome: string
  // The modules state. Each change runs in the queue of the store.
  store: {
    get(): ModulesState
    change(fn: (s: ModulesState) => ModulesState): Promise<ModulesState>
  }
  // The storage of the modules (module-data.ts).
  data: {
    flush(moduleId: string): Promise<void>
    drop(moduleId: string): Promise<void>
  }
  // The module jobs (jobs.ts).
  jobs: { cancel(moduleId: string): void }
  // git with GIT_CONFIG: the gh login gives the credentials. The service adds NO_PROMPT_CONFIG.
  git: RepoGit
  // The start of the clone URL: https://github.com/, or the local remotes of a test home.
  remoteBase: string
  // False in a packaged app. Then Bifrost refuses a dev module.
  devAllowed: boolean
  // The version of Bifrost. A module with a higher minBifrost is refused.
  bifrostVersion: string
  // Ask the user for a folder. null when the user closes the dialog.
  pickFolder(): Promise<string | null>
  // The log of the main process.
  log?(message: string): void
}

export interface ModuleService {
  // Each install gives the approval for Heimdall's panel, or null when the user closes the folder
  // dialog. It rejects with a reason or a "refused: ..." code.
  installFolder(): Promise<ModuleApproval | null>
  installGit(url: unknown): Promise<ModuleApproval>
  installDev(): Promise<ModuleApproval | null>
  // Check each module for a new version.
  checkUpdates(): Promise<ModuleUpdateResult[]>
  // The approval of the waiting update of a module.
  reviewUpdate(id: unknown): Promise<ModuleApproval>
  // Allow: run the new module or the new version. (The preload calls it approve.)
  allow(requestId: unknown): Promise<void>
  // Cancel an install, or forget a waiting update. An unknown request does nothing.
  decline(requestId: unknown): Promise<void>
  setEnabled(id: unknown, on: unknown): Promise<void>
  revoke(id: unknown, permission: unknown): Promise<void>
  // Give back a permission that the approved manifest asks for.
  grant(id: unknown, permission: unknown): Promise<void>
  setModel(id: unknown, model: unknown): Promise<void>
  setCap(id: unknown, cap: unknown): Promise<void>
  remove(id: unknown): Promise<void>
  // Remove the temporary clones and the copies that no request or update uses. Call it after the
  // state opens.
  cleanup(): Promise<void>
}

// The owner and the repository of a GitHub URL, or null for each other text.
export function githubRepo(url: unknown): { owner: string; repo: string } | null {
  if (typeof url !== 'string') return null
  const match = GITHUB_URL.exec(url)
  if (match === null) return null
  const [, owner, name] = match
  const repo = name.endsWith('.git') ? name.slice(0, -'.git'.length) : name
  if (repo === '' || repo === '.' || repo === '..') return null
  return { owner, repo }
}

// The folder that the module protocol serves for a module. A dev module runs from its folder in
// place. Each other module runs from its approved copy.
export function moduleCodeRoot(
  bifrostHome: string,
  id: string,
  entry: ModuleEntry | undefined,
): string {
  return entry?.source.kind === 'dev'
    ? entry.source.path
    : moduleCodeDir(bifrostHome, id, 'current')
}

// A refusal that the user reads: a friendly reason or a "refused: ..." code.
class Refusal extends Error {}

function refuse(text: string): never {
  throw new Refusal(text)
}

function own(modules: ModulesState['modules'], id: string): ModuleEntry | undefined {
  return Object.hasOwn(modules, id) ? modules[id] : undefined
}

function idOf(value: unknown): string {
  if (typeof value !== 'string' || !MODULE_ID_PATTERN.test(value)) refuse(REFUSED_UNKNOWN_MODULE)
  return value
}

function permissionOf(value: unknown): PermissionId {
  if (typeof value !== 'string' || !(PERMISSION_IDS as readonly string[]).includes(value)) {
    refuse(REFUSED_BAD_MODULE_INPUT)
  }
  return value as PermissionId
}

function sameManifest(a: ModuleManifest, b: ModuleManifest): boolean {
  return JSON.stringify(a) === JSON.stringify(b)
}

function sourceText(source: ModuleSource): string {
  return source.kind === 'git' ? source.url : source.path
}

function approvalOf(
  requestId: string,
  manifest: ModuleManifest,
  from: ModuleManifest | null,
  source: ModuleSource,
): ModuleApproval {
  const before = new Set(from?.permissions.map(p => p.id) ?? [])
  return {
    description: manifest.description,
    fromVersion: from?.version ?? null,
    icon: manifest.panels[0].icon,
    kind: from === null ? 'install' : 'update',
    moduleId: manifest.id,
    name: manifest.name,
    permissions: manifest.permissions.map(p => ({
      added: from !== null && !before.has(p.id),
      id: p.id,
      reason: p.reason,
    })),
    requestId,
    source: sourceText(source),
    sourceKind: source.kind,
    // Phase 1 has only the permissions of the Standard tier (Modules design 8.2).
    tier: 'standard',
    version: manifest.version,
  }
}

interface InstallRequest {
  kind: 'install'
  manifest: ModuleManifest
  hash: string
  source: ModuleSource
}

interface UpdateRequest {
  kind: 'update'
  moduleId: string
  // The hash of the waiting update that the user saw.
  hash: string
}

export function createModuleService(deps: ModuleServiceDeps): ModuleService {
  const log = deps.log ?? ((message: string) => console.error(message))
  const home = deps.bifrostHome
  const modulesRoot = join(home, 'modules')
  const moduleFolder = (id: string): string => join(modulesRoot, id)
  const next = (id: string): string => moduleCodeDir(home, id, 'next')
  const current = (id: string): string => moduleCodeDir(home, id, 'current')
  const requests = new Map<string, InstallRequest | UpdateRequest>()

  // The install, update and removal steps run one at a time.
  let queue: Promise<unknown> = Promise.resolve()
  function serial<T>(fn: () => Promise<T>): Promise<T> {
    const run = queue.then(fn)
    queue = run.catch(() => {})
    return run
  }

  // A refusal keeps its text. Each other error goes to the log, and the user gets a short code.
  function textOf(error: unknown): string {
    if (error instanceof Refusal) return error.message
    log(`A module action failed. ${error}`)
    return REFUSED_CALL_FAILED
  }

  // Run an action. A failure rejects with a plain Error that has the text for the user.
  async function guard<T>(fn: () => Promise<T>): Promise<T> {
    try {
      return await fn()
    } catch (error) {
      throw new Error(textOf(error))
    }
  }

  const remove = (path: string): Promise<void> => rm(path, { force: true, recursive: true })
  const exists = (path: string): Promise<boolean> =>
    stat(path).then(
      () => true,
      () => false,
    )

  // The manifest of a module folder, or a refusal with the reason of the parser.
  async function readManifestAt(dir: string): Promise<ModuleManifest> {
    try {
      if (!(await stat(dir)).isDirectory()) refuse(`${dir} isn't a folder.`)
    } catch (error) {
      if (error instanceof Refusal) throw error
      refuse(`Bifrost can't find the folder ${dir}.`)
    }
    let text: string
    try {
      text = await readFile(join(dir, MANIFEST_FILE), 'utf8')
    } catch {
      refuse(`The module has no ${MANIFEST_FILE} file.`)
    }
    let data: unknown
    try {
      data = JSON.parse(text)
    } catch {
      refuse(`The ${MANIFEST_FILE} file is not valid JSON.`)
    }
    const result = parseManifest(data)
    if (!result.ok) refuse(result.reason)
    return result.manifest
  }

  function checkVersion(manifest: ModuleManifest): void {
    const order = compareVersions(deps.bifrostVersion, manifest.minBifrost)
    if (order !== null && order < 0) refuse(NEWER_BIFROST)
  }

  function checkNew(manifest: ModuleManifest): void {
    if (own(deps.store.get().modules, manifest.id)) refuse(REFUSED_MODULE_INSTALLED)
    checkVersion(manifest)
  }

  // Clone the repository into a new temporary folder, with no prompt. The caller removes the
  // folder.
  async function cloneRepo(repo: { owner: string; repo: string }): Promise<string> {
    const incoming = join(modulesRoot, INCOMING)
    await mkdir(incoming, { mode: 0o700, recursive: true })
    const dir = join(incoming, randomUUID())
    const url = `${deps.remoteBase}${repo.owner.toLowerCase()}/${repo.repo.toLowerCase()}.git`
    const result = await deps.git.run(
      [
        ...NO_PROMPT_CONFIG,
        'clone',
        '--quiet',
        '--depth',
        '1',
        '--no-tags',
        '--single-branch',
        '--origin',
        'origin',
        '--',
        url,
        dir,
      ],
      { cwd: incoming, timeoutMs: MODULE_CLONE_TIMEOUT_MS },
    )
    if (result.code !== 0) {
      await remove(dir)
      const why = result.stderr.replace(/\s+/g, ' ').trim().slice(0, MAX_LOG_TEXT)
      log(`Bifrost cannot clone ${repo.owner}/${repo.repo} for a module. ${why}`)
      refuse(REFUSED_CLONE_FAILED)
    }
    return dir
  }

  // Copy a module folder into the next slot of its id. The copy must have the same id.
  async function copyToNext(
    from: string,
    id: string,
  ): Promise<{ manifest: ModuleManifest; hash: string }> {
    const target = next(id)
    await mkdir(dirname(target), { mode: 0o700, recursive: true })
    await remove(target)
    const copied = await copyModule(from, target)
    if (!copied.ok) refuse(copied.reason)
    try {
      const manifest = await readManifestAt(target)
      if (manifest.id !== id) refuse('The module changed while Bifrost copied it.')
      return { hash: copied.hash, manifest }
    } catch (error) {
      await remove(target)
      throw error
    }
  }

  // Forget the open install requests and delete their copies. Bifrost keeps one open install.
  async function dropInstalls(): Promise<void> {
    for (const [requestId, request] of [...requests]) {
      if (request.kind !== 'install') continue
      requests.delete(requestId)
      const id = request.manifest.id
      if (request.source.kind !== 'dev' && !own(deps.store.get().modules, id)) {
        await remove(moduleFolder(id))
      }
    }
  }

  async function prepareInstall(source: ModuleSource, from: string): Promise<ModuleApproval> {
    const first = await readManifestAt(from)
    checkNew(first)
    await dropInstalls()
    let manifest = first
    let hash: string
    if (source.kind === 'dev') {
      hash = await hashModule(from).catch(error =>
        refuse(error instanceof Error ? error.message : String(error)),
      )
    } else {
      const copy = await copyToNext(from, first.id)
      manifest = copy.manifest
      hash = copy.hash
      try {
        checkNew(manifest)
      } catch (error) {
        await remove(moduleFolder(manifest.id))
        throw error
      }
    }
    const requestId = randomUUID()
    requests.set(requestId, { hash, kind: 'install', manifest, source })
    return approvalOf(requestId, manifest, null, source)
  }

  // Swap the code of a module: next becomes current, and the old current goes.
  async function swapCode(id: string): Promise<void> {
    const old = join(moduleFolder(id), OLD_SLOT)
    await remove(old)
    if (await exists(current(id))) await rename(current(id), old)
    await rename(next(id), current(id))
    await remove(old)
  }

  // Run the new version of a module. The added permissions are granted only when the user
  // allowed them. A permission that the user removed stays removed.
  async function applyUpdate(
    id: string,
    entry: ModuleEntry,
    manifest: ModuleManifest,
    hash: string,
    grantAdded: boolean,
  ): Promise<void> {
    if (entry.source.kind !== 'dev') {
      const now = await hashModule(next(id)).catch(() => null)
      if (now !== hash) refuse(REFUSED_MODULE_CHANGED)
    }
    // The storage of the module stays. Its waiting changes go to the file before the swap.
    await deps.data.flush(id)
    if (entry.source.kind !== 'dev') await swapCode(id)
    const added = permissionDiff(entry.manifest, manifest).added.map(p => p.id)
    await deps.store.change(s => {
      const e = own(s.modules, id)
      if (!e) return s
      const wanted = new Set(manifest.permissions.map(p => p.id))
      const granted = e.granted.filter(g => wanted.has(g))
      if (grantAdded) for (const a of added) if (!granted.includes(a)) granted.push(a)
      return {
        ...s,
        modules: { ...s.modules, [id]: { ...e, granted, hash, manifest, pendingUpdate: null } },
      }
    })
  }

  async function allowInstall(request: InstallRequest): Promise<void> {
    const { manifest, source } = request
    const id = manifest.id
    if (own(deps.store.get().modules, id)) refuse(REFUSED_MODULE_INSTALLED)
    let hash = request.hash
    if (source.kind === 'dev') {
      const now = await readManifestAt(source.path).catch(() => null)
      if (now === null || !sameManifest(now, manifest)) refuse(REFUSED_MODULE_CHANGED)
      hash = await hashModule(source.path).catch(() => refuse(REFUSED_MODULE_CHANGED))
    } else {
      const now = await hashModule(next(id)).catch(() => null)
      if (now !== hash) {
        await remove(moduleFolder(id))
        refuse(REFUSED_MODULE_CHANGED)
      }
      await remove(current(id))
      await rename(next(id), current(id))
    }
    const entry: ModuleEntry = {
      dailyCap: manifest.suggests.dailyCap ?? DEFAULT_DAILY_CAP,
      enabled: true,
      granted: manifest.permissions.map(p => p.id),
      hash,
      jobs: { count: 0, day: '' },
      manifest,
      model: manifest.suggests.model ?? '',
      pendingUpdate: null,
      source,
    }
    await deps.store.change(s =>
      own(s.modules, id) ? s : { ...s, modules: { ...s.modules, [id]: entry } },
    )
  }

  async function allowUpdate(request: UpdateRequest): Promise<void> {
    const id = request.moduleId
    const entry = own(deps.store.get().modules, id)
    const pending = entry?.pendingUpdate
    if (!entry || !pending || pending.hash !== request.hash) refuse(REFUSED_MODULE_CHANGED)
    try {
      await applyUpdate(id, entry, pending.manifest, pending.hash, true)
    } catch (error) {
      // A copy that changed after the check can never be allowed. The row then loses the note,
      // and the next check finds the update again.
      if (error instanceof Refusal && error.message === REFUSED_MODULE_CHANGED) {
        await forgetUpdate(id, pending.hash)
      }
      throw error
    }
  }

  // The review requests of a module go stale after a new check or the removal.
  function dropReviews(id: string): void {
    for (const [requestId, request] of [...requests]) {
      if (request.kind === 'update' && request.moduleId === id) requests.delete(requestId)
    }
  }

  async function forgetUpdate(id: string, hash: string | null): Promise<void> {
    let cleared = false
    await deps.store.change(s => {
      const e = own(s.modules, id)
      if (!e?.pendingUpdate || (hash !== null && e.pendingUpdate.hash !== hash)) return s
      cleared = true
      return { ...s, modules: { ...s.modules, [id]: { ...e, pendingUpdate: null } } }
    })
    if (cleared) await remove(next(id))
  }

  // Check one module. A dev module compares only its manifest, because its code runs in place.
  async function updateOne(id: string, entry: ModuleEntry): Promise<ModuleUpdateResult> {
    const name = entry.manifest.name
    const same: ModuleUpdateResult = { id, name, outcome: 'same', version: entry.manifest.version }
    let manifest: ModuleManifest
    let hash: string
    if (entry.source.kind === 'dev') {
      manifest = await readManifestAt(entry.source.path)
      if (manifest.id !== id) refuse('The new version has another module id.')
      checkVersion(manifest)
      if (sameManifest(manifest, entry.manifest)) {
        if (entry.pendingUpdate) await forgetUpdate(id, null)
        return same
      }
      hash = await hashModule(entry.source.path).catch(error =>
        refuse(error instanceof Error ? error.message : String(error)),
      )
    } else {
      let from = entry.source.kind === 'folder' ? entry.source.path : ''
      if (entry.source.kind === 'git') {
        const repo = githubRepo(entry.source.url)
        if (repo === null) refuse(REFUSED_BAD_GIT_URL)
        from = await cloneRepo(repo)
      }
      // The copy replaces the next slot, so a waiting update loses its code from that step on.
      let copied = false
      try {
        const first = await readManifestAt(from)
        if (first.id !== id) refuse('The new version has another module id.')
        copied = true
        const copy = await copyToNext(from, id)
        manifest = copy.manifest
        hash = copy.hash
        checkVersion(manifest)
      } catch (error) {
        if (copied) {
          await remove(next(id))
          if (entry.pendingUpdate) await forgetUpdate(id, null)
        }
        throw error
      } finally {
        if (entry.source.kind === 'git') await remove(from)
      }
      if (hash === entry.hash) {
        await remove(next(id))
        // The code went back to the approved version, so an older waiting update goes.
        if (entry.pendingUpdate) await forgetUpdate(id, null)
        return same
      }
    }
    dropReviews(id)
    if (permissionDiff(entry.manifest, manifest).added.length === 0) {
      await applyUpdate(id, entry, manifest, hash, false)
      return { id, name, outcome: 'updated', version: manifest.version }
    }
    await deps.store.change(s => {
      const e = own(s.modules, id)
      if (!e) return s
      return { ...s, modules: { ...s.modules, [id]: { ...e, pendingUpdate: { hash, manifest } } } }
    })
    return { id, name, outcome: 'waiting', version: manifest.version }
  }

  // Change the entry of a module in one step of the store queue. An unknown module is refused.
  async function changeEntry(id: string, fn: (e: ModuleEntry) => ModuleEntry): Promise<void> {
    let found = false
    await deps.store.change(s => {
      const e = own(s.modules, id)
      if (!e) return s
      found = true
      return { ...s, modules: { ...s.modules, [id]: fn(e) } }
    })
    if (!found) refuse(REFUSED_UNKNOWN_MODULE)
  }

  return {
    allow: requestId =>
      guard(() =>
        serial(async () => {
          const request = typeof requestId === 'string' ? requests.get(requestId) : undefined
          if (request === undefined || typeof requestId !== 'string') refuse(REFUSED_NO_REQUEST)
          // A request is used one time, also when a step after this fails.
          requests.delete(requestId)
          if (request.kind === 'install') await allowInstall(request)
          else await allowUpdate(request)
        }),
      ),

    checkUpdates: () =>
      guard(() =>
        serial(async () => {
          const results: ModuleUpdateResult[] = []
          const entries = Object.entries(deps.store.get().modules).sort(
            ([a, x], [b, y]) => x.manifest.name.localeCompare(y.manifest.name) || (a < b ? -1 : 1),
          )
          for (const [id] of entries) {
            const entry = own(deps.store.get().modules, id)
            // A packaged app keeps a dev module off, so it does not check it.
            if (!entry || (entry.source.kind === 'dev' && !deps.devAllowed)) continue
            try {
              results.push(await updateOne(id, entry))
            } catch (error) {
              results.push({
                id,
                name: entry.manifest.name,
                outcome: 'failed',
                reason: textOf(error),
              })
            }
          }
          return results
        }),
      ),

    cleanup: () =>
      guard(() =>
        serial(async () => {
          await remove(join(modulesRoot, INCOMING))
          let names: string[]
          try {
            names = await readdir(modulesRoot)
          } catch {
            return
          }
          const open = new Set(
            [...requests.values()].flatMap(r => (r.kind === 'install' ? [r.manifest.id] : [])),
          )
          for (const name of names) {
            if (!MODULE_ID_PATTERN.test(name) || open.has(name)) continue
            const old = join(moduleFolder(name), OLD_SLOT)
            // A stop between the two renames of a swap leaves the old code in the old slot and no
            // current. The state still names the old code, so it goes back.
            if (!(await exists(current(name))) && (await exists(old))) {
              await rename(old, current(name))
            }
            await remove(old)
            if (!own(deps.store.get().modules, name)?.pendingUpdate) await remove(next(name))
          }
        }),
      ),

    decline: requestId =>
      guard(() =>
        serial(async () => {
          if (typeof requestId !== 'string') return
          const request = requests.get(requestId)
          if (request === undefined) return
          requests.delete(requestId)
          if (request.kind === 'update') {
            await forgetUpdate(request.moduleId, request.hash)
            return
          }
          const id = request.manifest.id
          if (request.source.kind !== 'dev' && !own(deps.store.get().modules, id)) {
            await remove(moduleFolder(id))
          }
        }),
      ),

    grant: (id, permission) =>
      guard(async () => {
        const moduleId = idOf(id)
        const perm = permissionOf(permission)
        let requested = true
        await changeEntry(moduleId, e => {
          if (!e.manifest.permissions.some(p => p.id === perm)) {
            requested = false
            return e
          }
          const granted = e.manifest.permissions
            .map(p => p.id)
            .filter(p => p === perm || e.granted.includes(p))
          return { ...e, granted }
        })
        if (!requested) refuse(REFUSED_NOT_ALLOWED)
      }),

    installDev: () =>
      guard(async () => {
        if (!deps.devAllowed) refuse(REFUSED_DEV_ONLY)
        const path = await deps.pickFolder()
        if (path === null) return null
        return serial(() => prepareInstall({ kind: 'dev', path }, path))
      }),

    installFolder: () =>
      guard(async () => {
        const path = await deps.pickFolder()
        if (path === null) return null
        return serial(() => prepareInstall({ kind: 'folder', path }, path))
      }),

    installGit: url =>
      guard(async () => {
        const repo = githubRepo(url)
        if (repo === null) refuse(REFUSED_BAD_GIT_URL)
        const source: ModuleSource = {
          kind: 'git',
          url: `https://github.com/${repo.owner}/${repo.repo}`,
        }
        return serial(async () => {
          const clone = await cloneRepo(repo)
          try {
            return await prepareInstall(source, clone)
          } finally {
            await remove(clone)
          }
        })
      }),

    remove: id =>
      guard(async () => {
        const moduleId = idOf(id)
        await serial(async () => {
          if (!own(deps.store.get().modules, moduleId)) refuse(REFUSED_UNKNOWN_MODULE)
          dropReviews(moduleId)
          // The state goes first, so Heimdall and the protocol refuse the module at once. Then
          // no new job or storage write can start.
          await deps.store.change(s => ({
            ...s,
            modules: Object.fromEntries(Object.entries(s.modules).filter(([k]) => k !== moduleId)),
          }))
          deps.jobs.cancel(moduleId)
          // The drop forgets a waiting write, so no late write makes the data file again.
          await deps.data.drop(moduleId)
          await rm(moduleDataFile(home, moduleId), { force: true })
          await remove(moduleFolder(moduleId))
        })
      }),

    reviewUpdate: id =>
      guard(async () => {
        const moduleId = idOf(id)
        const entry = own(deps.store.get().modules, moduleId)
        if (!entry) refuse(REFUSED_UNKNOWN_MODULE)
        const pending = entry.pendingUpdate
        if (!pending) refuse(REFUSED_NO_REQUEST)
        dropReviews(moduleId)
        const requestId = randomUUID()
        requests.set(requestId, { hash: pending.hash, kind: 'update', moduleId })
        return approvalOf(requestId, pending.manifest, entry.manifest, entry.source)
      }),

    revoke: (id, permission) =>
      guard(async () => {
        const moduleId = idOf(id)
        const perm = permissionOf(permission)
        await changeEntry(moduleId, e => ({ ...e, granted: e.granted.filter(g => g !== perm) }))
        // Without claude-jobs-auto, the jobs step sends a job with no click back to wait for
        // Refresh. So only the removal of claude-jobs cancels the jobs.
        if (perm === 'claude-jobs') deps.jobs.cancel(moduleId)
      }),

    setCap: (id, cap) =>
      guard(async () => {
        const moduleId = idOf(id)
        if (typeof cap !== 'number' || !Number.isInteger(cap) || cap < 1 || cap > MAX_CAP) {
          refuse(REFUSED_BAD_CAP)
        }
        await changeEntry(moduleId, e => ({ ...e, dailyCap: cap }))
      }),

    setEnabled: (id, on) =>
      guard(async () => {
        const moduleId = idOf(id)
        if (typeof on !== 'boolean') refuse(REFUSED_BAD_MODULE_INPUT)
        await changeEntry(moduleId, e => ({ ...e, enabled: on }))
        if (!on) {
          deps.jobs.cancel(moduleId)
          await deps.data.flush(moduleId)
        }
      }),

    setModel: (id, model) =>
      guard(async () => {
        const moduleId = idOf(id)
        if (typeof model !== 'string' || !MODEL_VALUES.includes(model as ModelChoice)) {
          refuse(REFUSED_UNKNOWN_MODEL)
        }
        await changeEntry(moduleId, e => ({ ...e, model: model as ModelChoice }))
      }),
  }
}
