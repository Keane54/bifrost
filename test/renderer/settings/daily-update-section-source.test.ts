import { readFileSync } from 'node:fs'
import { join } from 'node:path'
import { describe, expect, it } from 'vitest'
import { DAILY_ROWS } from '../../../src/renderer/src/settings/daily-update-rows'

// The repository has no DOM test. So this test reads the source text of the section.
const SETTINGS = join(__dirname, '../../../src/renderer/src/settings')
const SECTION = readFileSync(join(SETTINGS, 'DailyUpdateSection.tsx'), 'utf8')
const PANEL = readFileSync(join(SETTINGS, 'SettingsPanel.tsx'), 'utf8')

describe('Settings > Daily update', () => {
  it('uses each row label from DAILY_ROWS', () => {
    const used = new Set([...SECTION.matchAll(/DAILY_ROWS\.(\w+)/g)].map(m => m[1]))
    expect(used).toEqual(new Set(Object.keys(DAILY_ROWS)))
  })

  it('starts the inventory only from the Find servers button', () => {
    expect(SECTION.match(/dailyUpdate\.inventory\(/g)).toHaveLength(1)
    expect(SECTION).toMatch(/onClick=\{[^}]*findServers[\s\S]*?Find servers/)
    expect(SECTION).not.toMatch(/useEffect\([^)]*inventory/)
  })

  it('shows the busy text and the hints of the brief', () => {
    for (const text of [
      'Looking for your MCP servers…',
      'No ticket source',
      'An MCP server from your Claude Code setup.',
      "Bifrost ticks the tools that only read. The run can't use any other tool.",
      'The second reminder comes 10 minutes before.',
      'Up to 3. Claude copies their voice.',
      'Takes all other work',
      'Which work goes here',
      'Add work area',
      'Add example',
    ]) {
      expect(SECTION, text).toContain(text)
    }
  })

  it('checks the value with checkDailyUpdate before it saves', () => {
    expect(SECTION).toContain('checkDailyUpdate(')
  })

  it('is in the panel and the tabs', () => {
    expect(PANEL).toContain('<DailyUpdateSection')
    expect(PANEL).toContain("'daily-update'")
  })

  it('gives a label to each useRowSave call', () => {
    const calls = [...SECTION.matchAll(/useRowSave\(([^)]*)\)/g)].map(m => m[1])
    expect(calls.length).toBeGreaterThan(0)
    for (const arg of calls) expect(arg).toMatch(/^(?:DAILY_ROWS\.\w+|props\.label)$/)
  })

  it('keeps the typed text after a refused save, and reverts on Escape', () => {
    const ROWS = readFileSync(join(SETTINGS, 'rows.tsx'), 'utf8')
    expect(ROWS).toContain('keepOnRefusal')
    expect(SECTION.match(/keepOnRefusal/g)?.length).toBeGreaterThanOrEqual(3)
    const area = SECTION.slice(
      SECTION.indexOf('function DraftArea'),
      SECTION.indexOf('function BlockRow'),
    )
    expect(area).toContain("e.key === 'Escape'")
    expect(area).toContain('e.metaKey')
    expect(area).not.toMatch(/if \(!ok\) setDraft/)
  })

  it('disables Add work area at the limit', () => {
    expect(SECTION).toContain('canAddArea(saved.length + drafts.length)')
  })

  it('shows the note of each tool, and a write tool cannot be ticked', () => {
    const tools = SECTION.slice(SECTION.indexOf('tools.map(tool'), SECTION.indexOf('</BlockRow>'))
    expect(tools).toContain('toolNote(tool)')
    expect(tools).toContain('disabled={tool.write}')
  })

  it('has no line over 100 characters', () => {
    for (const name of ['DailyUpdateSection.tsx', 'daily-update-rows.ts']) {
      const text = readFileSync(join(SETTINGS, name), 'utf8')
      const long = text.split('\n').filter(line => line.length > 100)
      expect(long, name).toEqual([])
    }
  })
})
