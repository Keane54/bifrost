// The input file of one draft run.

import { chmod, writeFile } from 'node:fs/promises'
import { join } from 'node:path'
import type { DailyFormat } from '../../shared/daily-update'
import type { DailyPr } from './merged-prs'

export const INPUT_VERSION = 1
// The run ends after this time.
export const RUN_TIMEOUT_MS = 300_000

export interface DailyInput {
  version: 1
  now: string
  timeZone: string
  you: string
  areas: {
    id: string
    name: string
    description: string
    takesRest: boolean
    since: string
  }[]
  format: DailyFormat
  prs: DailyPr[]
  source: { server: string | null; tools: string[] }
}

// Write input.json in the folder. Only the user can read it. Give its path.
export async function writeDailyInput(dir: string, input: DailyInput): Promise<string> {
  const file = join(dir, 'input.json')
  await writeFile(file, `${JSON.stringify(input, null, 2)}\n`, { mode: 0o600 })
  await chmod(file, 0o600)
  return file
}

export function runPrompt(inputFile: string): string {
  return `/bifrost-daily-update bifrost-input=${inputFile}`
}
