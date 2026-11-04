import { spawn } from 'node:child_process'
import { mkdtemp, rm, writeFile } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'

// Run script text with sh. Give it stdin and BIFROST_HOME.
export async function runSh(
  text: string,
  stdin: string,
  bifrostHome: string,
): Promise<{ code: number | null; stdout: string }> {
  const dir = await mkdtemp(join(tmpdir(), 'bifrost-run-sh-'))
  try {
    const file = join(dir, 'script.sh')
    await writeFile(file, text)
    return await new Promise((resolve, reject) => {
      const child = spawn('sh', [file], { env: { ...process.env, BIFROST_HOME: bifrostHome } })
      let stdout = ''
      child.stdout.on('data', chunk => {
        stdout += chunk
      })
      child.on('error', reject)
      child.on('close', code => resolve({ code, stdout }))
      child.stdin.on('error', () => {})
      child.stdin.end(stdin)
    })
  } finally {
    await rm(dir, { force: true, recursive: true })
  }
}
