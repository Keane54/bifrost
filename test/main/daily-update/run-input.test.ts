import { mkdtemp, readFile, rm, stat } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterEach, describe, expect, it } from 'vitest'
import {
  type DailyInput,
  INPUT_VERSION,
  RUN_TIMEOUT_MS,
  runPrompt,
  writeDailyInput,
} from '../../../src/main/daily-update/run-input'

let dir = ''
afterEach(async () => {
  if (dir) await rm(dir, { force: true, recursive: true })
})

const input = (): DailyInput => ({
  areas: [{ description: 'd', id: 'a', name: 'A', since: 's', takesRest: false }],
  format: { examples: [], template: 't' },
  now: 'n',
  prs: [],
  source: { server: null, tools: [] },
  timeZone: 'Europe/London',
  version: 1,
  you: 'me',
})

describe('run input', () => {
  it('has mode 600 and the given content', async () => {
    dir = await mkdtemp(join(tmpdir(), 'daily-input-'))
    const file = await writeDailyInput(dir, input())
    expect(file).toBe(join(dir, 'input.json'))
    expect((await stat(file)).mode & 0o777).toBe(0o600)
    expect(JSON.parse(await readFile(file, 'utf8'))).toEqual(input())
  })

  it('has the constants and the prompt', () => {
    expect(INPUT_VERSION).toBe(1)
    expect(RUN_TIMEOUT_MS).toBe(300_000)
    expect(runPrompt('/a/input.json')).toBe('/bifrost-daily-update bifrost-input=/a/input.json')
  })
})
