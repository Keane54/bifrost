// Read a unified diff: the hunks of each file, on each side. Used to check that a comment of
// a review sits on a line that the diff shows.

// Inclusive ranges. A side with no lines has an end below its start.
export interface Hunk {
  leftStart: number
  leftEnd: number
  rightStart: number
  rightEnd: number
}

export interface DiffFile {
  path: string
  binary: boolean
  hunks: Hunk[]
}

const HUNK = /^@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@/
const SIMPLE_ESCAPES: Record<string, number> = {
  '"': 0x22,
  '\\': 0x5c,
  a: 7,
  b: 8,
  f: 12,
  n: 10,
  r: 13,
  t: 9,
  v: 11,
}

// Remove the C style quotes of git. An octal escape is one byte of UTF-8.
function unquote(raw: string): string {
  if (!(raw.length >= 2 && raw.startsWith('"') && raw.endsWith('"'))) return raw
  const inner = raw.slice(1, -1)
  const bytes: number[] = []
  const encoder = new TextEncoder()
  for (let i = 0; i < inner.length; i++) {
    const ch = inner[i] as string
    if (ch !== '\\') {
      bytes.push(...encoder.encode(ch))
      continue
    }
    const next = inner[i + 1] ?? ''
    const octal = /^[0-7]{3}/.exec(inner.slice(i + 1, i + 4))
    if (octal) {
      bytes.push(Number.parseInt(octal[0], 8))
      i += 3
    } else if (next in SIMPLE_ESCAPES) {
      bytes.push(SIMPLE_ESCAPES[next] as number)
      i += 1
    } else {
      bytes.push(...encoder.encode(next))
      i += 1
    }
  }
  return new TextDecoder().decode(Uint8Array.from(bytes))
}

// The path of a "--- " or "+++ " line, or null for /dev/null.
function markerPath(line: string): string | null {
  const raw = line.slice(4).replace(/\t.*$/, '')
  const path = unquote(raw)
  if (path === '/dev/null') return null
  return path.replace(/^[ab]\//, '')
}

// Split the two paths of a "diff --git" line. Used when no marker line follows (binary files).
function headerPath(rest: string): string {
  if (rest.startsWith('"')) {
    const end = rest.indexOf('" ', 1)
    const first = end === -1 ? rest : rest.slice(0, end + 1)
    const second = end === -1 ? rest : rest.slice(end + 2)
    return unquote(second || first).replace(/^b\//, '')
  }
  const at = rest.indexOf(' b/')
  return at === -1 ? rest : unquote(rest.slice(at + 1)).replace(/^b\//, '')
}

export function parseDiff(text: string): DiffFile[] {
  const files: DiffFile[] = []
  let current: DiffFile | null = null
  let inHunk = false
  for (const line of text.split('\n')) {
    if (line.startsWith('diff --git ')) {
      current = { binary: false, hunks: [], path: headerPath(line.slice(11)) }
      files.push(current)
      inHunk = false
      continue
    }
    if (current === null) continue
    const hunk = HUNK.exec(line)
    if (hunk) {
      const leftStart = Number(hunk[1])
      const leftCount = hunk[2] === undefined ? 1 : Number(hunk[2])
      const rightStart = Number(hunk[3])
      const rightCount = hunk[4] === undefined ? 1 : Number(hunk[4])
      current.hunks.push({
        leftEnd: leftStart + leftCount - 1,
        leftStart,
        rightEnd: rightStart + rightCount - 1,
        rightStart,
      })
      inHunk = true
      continue
    }
    if (inHunk) continue
    if (line.startsWith('Binary files ') || line === 'GIT binary patch') current.binary = true
    else if (line.startsWith('+++ ')) {
      // A deleted file has /dev/null as the new path. It keeps the old path.
      const path = markerPath(line)
      if (path !== null) current.path = path
    }
  }
  return files
}

// True when the line, and the start line if any, are in one hunk of the file on that side.
export function lineInDiff(
  files: readonly DiffFile[],
  path: string,
  side: 'LEFT' | 'RIGHT',
  line: number,
  startLine?: number,
): boolean {
  const file = files.find(f => f.path === path)
  if (!file) return false
  const lo = startLine === undefined ? line : Math.min(startLine, line)
  const hi = startLine === undefined ? line : Math.max(startLine, line)
  return file.hunks.some(h => {
    const start = side === 'LEFT' ? h.leftStart : h.rightStart
    const end = side === 'LEFT' ? h.leftEnd : h.rightEnd
    return lo >= start && hi <= end
  })
}
