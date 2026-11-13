import { mkdirSync, mkdtempSync, realpathSync, rmSync, symlinkSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { describe, expect, it, test, vi } from 'vitest'
import {
  type BranchFs,
  branchOfHead,
  createBranchReader,
  readBranch,
} from '../../../src/main/registry/git-branch'

test('readBranch returns the trimmed branch or null', async () => {
  const exec = vi.fn().mockResolvedValue({ code: 0, stderr: '', stdout: 'main\n' })
  expect(await readBranch(exec, '/p')).toBe('main')
  expect(exec).toHaveBeenCalledWith('git', ['-C', '/p', 'rev-parse', '--abbrev-ref', 'HEAD'], {
    timeoutMs: 2000,
  })
  const failing = vi.fn().mockResolvedValue({ code: 128, stderr: 'fatal', stdout: '' })
  expect(await readBranch(failing, '/p')).toBeNull()
})

// An in-memory file system for the branch reader. The paths of files map to text. The folders
// are a set, and each parent of a path is a folder. A path in neither gives an error, as the
// real file system does.
function memoryFs(
  files: Record<string, string>,
  folders: string[],
  mtimes: Record<string, number> = {},
) {
  const reads: string[] = []
  const fs: BranchFs = {
    async readFile(path) {
      reads.push(path)
      const text = files[path]
      if (text === undefined) throw new Error('ENOENT')
      return text
    },
    async stat(path) {
      const isFile = path in files
      const known = [...Object.keys(files), ...folders]
      const isDir = folders.includes(path) || known.some(other => other.startsWith(`${path}/`))
      if (!isFile && !isDir) throw new Error('ENOENT')
      return { isDirectory: () => isDir, isFile: () => isFile, mtimeMs: mtimes[path] ?? 1 }
    },
  }
  return { fs, reads }
}

const noExec = () => vi.fn().mockResolvedValue({ code: 0, stderr: '', stdout: 'from-git\n' })

describe('branchOfHead', () => {
  it('reads a branch, a detached head and other text', () => {
    expect(branchOfHead('ref: refs/heads/feat/a\n')).toBe('feat/a')
    expect(branchOfHead(`${'a'.repeat(40)}\n`)).toBe('HEAD')
    expect(branchOfHead(`${'B'.repeat(64)}\n`)).toBe('HEAD')
    expect(branchOfHead('ref: refs/remotes/origin/x')).toBeUndefined()
    expect(branchOfHead('')).toBeUndefined()
  })
})

describe('createBranchReader', () => {
  it('returns null for a folder that does not exist, with no walk up to a parent repo', async () => {
    const { fs } = memoryFs({ '/r/.git/HEAD': 'ref: refs/heads/main\n' }, ['/r/.git'])
    const exec = vi.fn().mockResolvedValue({ code: 128, stderr: 'fatal', stdout: '' })
    const reader = createBranchReader(exec, { fs })
    expect(await reader.read('/r/.claude/worktrees/fix-a')).toBeNull()
  })

  it('reads the branch of a repo and of its subfolder with no git process', async () => {
    const { fs } = memoryFs({ '/r/.git/HEAD': 'ref: refs/heads/main\n' }, ['/r/.git', '/r/a/b'])
    const exec = noExec()
    const reader = createBranchReader(exec, { fs })
    expect(await reader.read('/r')).toBe('main')
    expect(await reader.read('/r/a/b')).toBe('main')
    expect(exec).not.toHaveBeenCalled()
  })

  it('reads a worktree whose .git file has a relative gitdir', async () => {
    const { fs } = memoryFs(
      {
        '/r/.git/worktrees/w/HEAD': 'ref: refs/heads/wt\n',
        '/w/.git': 'gitdir: ../r/.git/worktrees/w\n',
      },
      ['/w/sub'],
    )
    const exec = noExec()
    const reader = createBranchReader(exec, { fs })
    expect(await reader.read('/w')).toBe('wt')
    expect(await reader.read('/w/sub')).toBe('wt')
    expect(exec).not.toHaveBeenCalled()
  })

  it('reads a worktree whose .git file has an absolute gitdir', async () => {
    const { fs } = memoryFs(
      {
        '/r/.git/worktrees/w/HEAD': 'ref: refs/heads/a',
        '/w/.git': 'gitdir: /r/.git/worktrees/w\n',
      },
      [],
    )
    expect(await createBranchReader(noExec(), { fs }).read('/w')).toBe('a')
  })

  it('reads the HEAD file again only when its mtime changes', async () => {
    const files: Record<string, string> = { '/r/.git/HEAD': 'ref: refs/heads/one\n' }
    const mtimes: Record<string, number> = { '/r/.git/HEAD': 10 }
    const { fs, reads } = memoryFs(files, ['/r/.git'], mtimes)
    const reader = createBranchReader(noExec(), { fs })
    expect(await reader.read('/r')).toBe('one')
    expect(await reader.read('/r')).toBe('one')
    expect(reads).toEqual(['/r/.git/HEAD'])
    files['/r/.git/HEAD'] = 'ref: refs/heads/two\n'
    mtimes['/r/.git/HEAD'] = 20
    expect(await reader.read('/r')).toBe('two')
    expect(reads).toHaveLength(2)
  })

  it('shows HEAD for a detached head, as git does', async () => {
    const { fs } = memoryFs({ '/r/.git/HEAD': `${'c'.repeat(40)}\n` }, ['/r/.git'])
    const exec = noExec()
    expect(await createBranchReader(exec, { fs }).read('/r')).toBe('HEAD')
    expect(exec).not.toHaveBeenCalled()
  })

  it('shows the name of a branch with no commit yet, where git gives nothing', async () => {
    const { fs } = memoryFs({ '/r/.git/HEAD': 'ref: refs/heads/unborn\n' }, ['/r/.git'])
    expect(await createBranchReader(noExec(), { fs }).read('/r')).toBe('unborn')
  })

  it('shows the plain name for a branch named like a tag, where git gives heads/name', async () => {
    const { fs } = memoryFs({ '/r/.git/HEAD': 'ref: refs/heads/v1\n' }, ['/r/.git'])
    expect(await createBranchReader(noExec(), { fs }).read('/r')).toBe('v1')
  })

  it('uses git for a HEAD it cannot read', async () => {
    const { fs } = memoryFs({ '/r/.git/HEAD': 'ref: refs/remotes/x\n' }, ['/r/.git'])
    const exec = noExec()
    expect(await createBranchReader(exec, { fs }).read('/r')).toBe('from-git')
    expect(exec).toHaveBeenCalledWith('git', ['-C', '/r', 'rev-parse', '--abbrev-ref', 'HEAD'], {
      timeoutMs: 2000,
    })
  })

  it('uses git for a .git file with no gitdir and for a missing HEAD file', async () => {
    const a = memoryFs({ '/r/.git': 'nonsense\n' }, [])
    const exec = noExec()
    expect(await createBranchReader(exec, { fs: a.fs }).read('/r')).toBe('from-git')
    const b = memoryFs({}, ['/r/.git'])
    expect(await createBranchReader(exec, { fs: b.fs }).read('/r')).toBe('from-git')
    expect(exec).toHaveBeenCalledTimes(2)
  })

  it('gives null with no .git up to the root, and does not call git', async () => {
    const { fs } = memoryFs({}, ['/a/b'])
    const exec = noExec()
    expect(await createBranchReader(exec, { fs }).read('/a/b')).toBeNull()
    expect(exec).not.toHaveBeenCalled()
  })

  it('reads no HEAD file and runs no git in the reviews folder of PR sessions', async () => {
    const root = '/h/.bifrost/reviews/repos'
    const { fs, reads } = memoryFs(
      {
        [`${root}/acme/api/.git/HEAD`]: 'ref: refs/heads/fix\n',
        '/p/.git/HEAD': 'ref: refs/heads/main\n',
      },
      [`${root}/acme/api/.git`, `${root}/acme/api/.bifrost-worktrees/9`, '/p/.git'],
    )
    const exec = noExec()
    const reader = createBranchReader(exec, { fs, skipRoot: root })
    for (const cwd of [root, `${root}/acme/api`, `${root}/acme/api/.bifrost-worktrees/9`]) {
      expect(await reader.read(cwd)).toBeNull()
    }
    expect(reads).toEqual([])
    expect(exec).not.toHaveBeenCalled()
    // A folder outside the reviews folder is a normal folder.
    expect(await reader.read('/p')).toBe('main')
  })

  it('reads no HEAD file in the reviews folder through a .git file outside it', async () => {
    const root = '/h/.bifrost/reviews/repos'
    const { fs, reads } = memoryFs(
      {
        [`${root}/acme/api/.git/worktrees/w/HEAD`]: 'ref: refs/heads/fix\n',
        '/elsewhere/.git': `gitdir: ${root}/acme/api/.git/worktrees/w\n`,
      },
      ['/elsewhere'],
    )
    const exec = noExec()
    const reader = createBranchReader(exec, { fs, skipRoot: root })
    expect(await reader.read('/elsewhere')).toBeNull()
    expect(reads).toEqual(['/elsewhere/.git'])
    expect(exec).not.toHaveBeenCalled()
  })
})

test('readBranch runs no git in the reviews folder, where a PR session can write', async () => {
  const exec = vi.fn().mockResolvedValue({ code: 0, stderr: '', stdout: 'main\n' })
  const root = '/h/.bifrost/reviews/repos'
  for (const cwd of [root, `${root}/acme/api`, `${root}/acme/api/.bifrost-worktrees/9`]) {
    expect(await readBranch(exec, cwd, root)).toBeNull()
  }
  expect(exec).not.toHaveBeenCalled()
  // A folder next to the reviews folder is a normal folder.
  expect(await readBranch(exec, '/h/.bifrost/reviews/repos-old', root)).toBe('main')
  expect(await readBranch(exec, '/p', root)).toBe('main')
  expect(exec).toHaveBeenCalledTimes(2)
})

test('readBranch also compares the real paths of the folders', async () => {
  const dir = realpathSync(mkdtempSync(join(tmpdir(), 'bifrost-git-branch-')))
  try {
    const root = join(dir, 'repos')
    mkdirSync(join(root, 'acme', 'api'), { recursive: true })
    symlinkSync(root, join(dir, 'link'))
    const exec = vi.fn().mockResolvedValue({ code: 0, stderr: '', stdout: 'main\n' })
    // The session reports the real path, and the settings give the path through the link.
    expect(await readBranch(exec, join(root, 'acme', 'api'), join(dir, 'link'))).toBeNull()
    expect(await readBranch(exec, join(dir, 'link', 'acme', 'api'), root)).toBeNull()
    expect(exec).not.toHaveBeenCalled()
  } finally {
    rmSync(dir, { force: true, recursive: true })
  }
})
