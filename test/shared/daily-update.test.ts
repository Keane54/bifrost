import { describe, expect, test } from 'vitest'
import {
  checkDailyUpdate,
  DEFAULT_DAILY_UPDATE,
  DEFAULT_TEMPLATE,
  hasReadWord,
  hasWriteWord,
  parseDailyUpdate,
  proposeReadTools,
  toolPrefix,
  type WorkArea,
} from '../../src/shared/daily-update'

const area = (id: string, over: Partial<WorkArea> = {}): WorkArea => ({
  channel: '#team',
  description: 'Work of the team.',
  id,
  name: `Area ${id}`,
  on: true,
  takesRest: false,
  ...over,
})

const base = () => structuredClone(DEFAULT_DAILY_UPDATE)

function reasonOf(value: unknown): string {
  const result = checkDailyUpdate(value)
  return result.ok ? 'ok' : result.reason
}

describe('toolPrefix', () => {
  test('toolPrefix changes each character that is not a letter, digit, _ or -', () => {
    expect(toolPrefix('claude.ai Claude Docs')).toBe('mcp__claude_ai_Claude_Docs__')
    expect(toolPrefix('plugin:slack:slack')).toBe('mcp__plugin_slack_slack__')
    expect(toolPrefix('n8n-mcp')).toBe('mcp__n8n-mcp__')
  })
})

describe('proposeReadTools', () => {
  test('proposeReadTools keeps read tools and drops write tools', () => {
    const prefix = 'mcp__board__'
    const tools = [
      'work_items_list',
      'work_items_get',
      'item_search_list',
      'work_items_mark_comment_read',
      'work_items_update',
      'batch_execute',
    ].map(name => prefix + name)
    tools.push('mcp__other__other_list')
    expect(proposeReadTools(prefix, tools)).toEqual([
      'mcp__board__work_items_list',
      'mcp__board__work_items_get',
      'mcp__board__item_search_list',
    ])
  })

  test('proposeReadTools splits camelCase and kebab-case names', () => {
    const prefix = 'mcp__git-hub__'
    const tools = [
      'getIssue',
      'updateIssue',
      'list-repos',
      'create-repo',
      'searchCode',
      'get_settings',
      'getHTTPResponse',
      'mergePullRequest',
      'describe-thing',
    ].map(name => prefix + name)
    expect(proposeReadTools(prefix, tools)).toEqual([
      'mcp__git-hub__getIssue',
      'mcp__git-hub__list-repos',
      'mcp__git-hub__searchCode',
      'mcp__git-hub__get_settings',
      'mcp__git-hub__getHTTPResponse',
    ])
  })
})

describe('hasWriteWord and hasReadWord', () => {
  test('find a whole word after the prefix, in lower case', () => {
    const prefix = 'mcp__board__'
    expect(hasWriteWord(prefix, 'mcp__board__updateIssue')).toBe(true)
    expect(hasWriteWord(prefix, 'mcp__board__Update-Issue')).toBe(true)
    expect(hasWriteWord(prefix, 'mcp__board__items_DELETE')).toBe(true)
    expect(hasWriteWord(prefix, 'mcp__board__getIssue')).toBe(false)
    expect(hasWriteWord(prefix, 'mcp__board__get_settings')).toBe(false)
    expect(hasReadWord(prefix, 'mcp__board__getIssue')).toBe(true)
    expect(hasReadWord(prefix, 'mcp__board__ListItems')).toBe(true)
    expect(hasReadWord(prefix, 'mcp__board__widget')).toBe(false)
  })

  test('ignore a word of the server name in the prefix', () => {
    const prefix = 'mcp__sync-board__'
    expect(hasWriteWord(prefix, 'mcp__sync-board__items_list')).toBe(false)
    expect(hasReadWord('mcp__list__', 'mcp__list__widget')).toBe(false)
  })
})

describe('parseDailyUpdate', () => {
  test('parseDailyUpdate gives the defaults for undefined, null and a string', () => {
    for (const bad of [undefined, null, 'x']) {
      expect(parseDailyUpdate(bad)).toEqual(DEFAULT_DAILY_UPDATE)
    }
    expect(DEFAULT_DAILY_UPDATE.format.template).toBe(DEFAULT_TEMPLATE)
    expect(DEFAULT_DAILY_UPDATE.draftTime).toBe('09:30')
    expect(DEFAULT_DAILY_UPDATE.deadline).toBe('10:00')
    expect(DEFAULT_DAILY_UPDATE.days).toEqual([1, 2, 3, 4, 5])
  })

  test('parseDailyUpdate keeps good parts and drops bad ones', () => {
    const result = parseDailyUpdate({
      areas: [area('a'), area('b')],
      draftTime: '25:99',
      you: 'Sam',
    })
    expect(result.draftTime).toBe('09:30')
    expect(result.you).toBe('Sam')
    expect(result.areas).toEqual([area('a'), area('b')])
  })

  test('parseDailyUpdate keeps only the first takesRest', () => {
    const result = parseDailyUpdate({
      areas: [area('a'), area('b', { takesRest: true }), area('c', { takesRest: true })],
    })
    expect(result.areas.map(a => a.takesRest)).toEqual([false, true, false])
  })

  test('parseDailyUpdate drops the tools when the server is null', () => {
    const result = parseDailyUpdate({ source: { server: null, tools: ['mcp__a__b'] } })
    expect(result.source).toEqual({ server: null, tools: [] })
  })
})

describe('checkDailyUpdate', () => {
  test('checkDailyUpdate accepts the defaults', () => {
    expect(checkDailyUpdate(base())).toEqual({ ok: true, value: DEFAULT_DAILY_UPDATE })
  })

  test('checkDailyUpdate accepts a full good value', () => {
    const value = base()
    value.source = { server: 'n8n-mcp', tools: ['mcp__n8n-mcp__get_x'] }
    value.areas = [area('a'), area('b', { takesRest: true })]
    expect(checkDailyUpdate(value).ok).toBe(true)
  })

  test('checkDailyUpdate refuses a deadline 5 minutes after the draft time', () => {
    expect(reasonOf({ ...base(), deadline: '09:35' })).not.toBe('ok')
    expect(reasonOf({ ...base(), deadline: '09:40' })).toBe('ok')
  })

  test('checkDailyUpdate refuses empty days', () => {
    expect(reasonOf({ ...base(), days: [] })).not.toBe('ok')
  })

  test('checkDailyUpdate refuses two takesRest areas', () => {
    const areas = [area('a', { takesRest: true }), area('b', { takesRest: true })]
    expect(reasonOf({ ...base(), areas })).not.toBe('ok')
  })

  test('checkDailyUpdate refuses a tool of another server', () => {
    const source = { server: 'n8n-mcp', tools: ['mcp__other__get_x'] }
    expect(reasonOf({ ...base(), source })).not.toBe('ok')
  })

  test('checkDailyUpdate refuses tools when the server is null', () => {
    const source = { server: null, tools: ['mcp__other__get_x'] }
    expect(reasonOf({ ...base(), source })).not.toBe('ok')
  })

  test('checkDailyUpdate refuses an 11th area', () => {
    const areas = Array.from({ length: 11 }, (_, i) => area(`a${i}`))
    expect(reasonOf({ ...base(), areas })).not.toBe('ok')
  })

  test('checkDailyUpdate refuses duplicate area IDs', () => {
    expect(reasonOf({ ...base(), areas: [area('a'), area('a')] })).not.toBe('ok')
  })

  test('checkDailyUpdate refuses a 4th example', () => {
    const format = { examples: ['a', 'b', 'c', 'd'], template: 'T' }
    expect(reasonOf({ ...base(), format })).not.toBe('ok')
  })

  test('checkDailyUpdate refuses bad types and limits', () => {
    expect(reasonOf(null)).not.toBe('ok')
    expect(reasonOf({ ...base(), draftTime: '9:30' })).not.toBe('ok')
    expect(reasonOf({ ...base(), you: 'x'.repeat(201) })).not.toBe('ok')
    expect(reasonOf({ ...base(), areas: [area('a', { name: '' })] })).not.toBe('ok')
    expect(reasonOf({ ...base(), days: [7] })).not.toBe('ok')
    expect(reasonOf({ ...base(), format: { examples: [], template: '' } })).not.toBe('ok')
  })

  test('checkDailyUpdate gives a friendly reason that says the limit', () => {
    expect(reasonOf({ ...base(), areas: [area('a', { name: 'x'.repeat(61) })] })).toBe(
      'A name can have up to 60 characters.',
    )
    expect(reasonOf({ ...base(), areas: [area('a', { name: '' })] })).toBe(
      'Each work area needs a name.',
    )
    expect(reasonOf({ ...base(), areas: [area('a', { channel: 'x'.repeat(81) })] })).toBe(
      'A channel can have up to 80 characters.',
    )
    expect(reasonOf({ ...base(), you: 'x'.repeat(201) })).toBe(
      'Your name, email or ID can have up to 200 characters.',
    )
    const format = { examples: ['a', 'b', 'c', 'd'], template: 'T' }
    expect(reasonOf({ ...base(), format })).toBe(
      'You can add up to 3 examples, each up to 4,000 characters.',
    )
    const areas = Array.from({ length: 11 }, (_, i) => area(`a${i}`))
    expect(reasonOf({ ...base(), areas })).toBe('You can have up to 10 work areas.')
  })

  test('checkDailyUpdate never gives a short code as the reason', () => {
    const bad: unknown[] = [
      null,
      { ...base(), source: 'x' },
      { ...base(), source: { server: '', tools: [] } },
      { ...base(), source: { server: 'board', tools: ['mcp__other__get_x'] } },
      { ...base(), you: 7 },
      { ...base(), mergedPrs: 'yes' },
      { ...base(), draftTime: '9:30' },
      { ...base(), days: [] },
      { ...base(), days: [1, 1] },
      { ...base(), model: 'nope' },
      { ...base(), format: { examples: [], template: '' } },
      { ...base(), format: { examples: ['x'.repeat(4001)], template: 'T' } },
      { ...base(), areas: 'x' },
      { ...base(), areas: [7] },
      { ...base(), areas: [area('a', { description: 'x'.repeat(501) })] },
      { ...base(), areas: [area('a'), area('a')] },
      { ...base(), areas: [area('a', { takesRest: true }), area('b', { takesRest: true })] },
    ]
    for (const value of bad) {
      const reason = reasonOf(value)
      expect(reason).not.toBe('ok')
      expect(reason, reason).not.toMatch(/^Bad /)
      expect(reason, reason).toMatch(/^[A-Z"].{10,90}\.$/)
    }
  })
})
