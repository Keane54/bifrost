import { describe, expect, it } from 'vitest'
import {
  canAddArea,
  chooseServer,
  DAILY_ROWS,
  dayChoices,
  newArea,
  serverChoices,
  setTakesRest,
  shownTools,
  statusWords,
  toggleDay,
  toggleTool,
  toolNote,
  toolsForServer,
} from '../../../src/renderer/src/settings/daily-update-rows'
import type { McpInventory, WorkArea } from '../../../src/shared/daily-update'
import { DEFAULT_DAILY_UPDATE } from '../../../src/shared/daily-update'
import { isUuid } from '../../../src/shared/uuid'

const INVENTORY: McpInventory = {
  servers: [
    {
      name: 'board',
      prefix: 'mcp__board__',
      status: 'connected',
      tools: ['mcp__board__list_items', 'mcp__board__update_item', 'mcp__board__get_item'],
    },
    { name: 'other', prefix: 'mcp__other__', status: 'needs-auth', tools: [] },
  ],
}

function area(id: string, takesRest: boolean): WorkArea {
  return { channel: '', description: '', id, name: id, on: true, takesRest }
}

describe('setTakesRest', () => {
  it('keeps one area', () => {
    const next = setTakesRest([area('a', true), area('b', false), area('c', false)], 'c')
    expect(next.map(a => a.takesRest)).toEqual([false, false, true])
  })
})

describe('toolsForServer', () => {
  it('marks the proposed tools', () => {
    expect(toolsForServer(INVENTORY, 'board')).toEqual([
      { name: 'mcp__board__list_items', proposed: true, write: false },
      { name: 'mcp__board__update_item', proposed: false, write: true },
      { name: 'mcp__board__get_item', proposed: true, write: false },
    ])
  })
  it('marks camelCase and kebab-case names', () => {
    const tools = ['getIssue', 'updateIssue', 'close-issue', 'widget'].map(t => `mcp__gh__${t}`)
    const inv: McpInventory = {
      servers: [{ name: 'gh', prefix: 'mcp__gh__', status: 'connected', tools }],
    }
    expect(toolsForServer(inv, 'gh').map(t => [t.proposed, t.write])).toEqual([
      [true, false],
      [false, true],
      [false, true],
      [false, false],
    ])
  })
  it('gives no tools for an unknown server', () => {
    expect(toolsForServer(INVENTORY, 'nope')).toEqual([])
  })
})

describe('chooseServer', () => {
  it('ticks the proposed tools', () => {
    const next = chooseServer(DEFAULT_DAILY_UPDATE, INVENTORY, 'board')
    expect(next.source).toEqual({
      server: 'board',
      tools: ['mcp__board__list_items', 'mcp__board__get_item'],
    })
  })
  it('clears the tools for no source', () => {
    const had = chooseServer(DEFAULT_DAILY_UPDATE, INVENTORY, 'board')
    expect(chooseServer(had, INVENTORY, null).source).toEqual({ server: null, tools: [] })
  })
  it('keeps the other settings', () => {
    const next = chooseServer({ ...DEFAULT_DAILY_UPDATE, you: 'me' }, INVENTORY, 'board')
    expect(next.you).toBe('me')
  })
})

describe('newArea', () => {
  it('is on and empty', () => {
    const made = newArea()
    expect(isUuid(made.id)).toBe(true)
    expect(made).toMatchObject({
      channel: '',
      description: '',
      name: '',
      on: true,
      takesRest: false,
    })
    expect(newArea().id).not.toBe(made.id)
  })
})

describe('serverChoices', () => {
  it('lets only a connected server be chosen, and says the status in plain words', () => {
    expect(serverChoices(INVENTORY)).toEqual([
      { disabled: false, label: 'board', name: 'board' },
      { disabled: true, label: 'other (needs sign-in)', name: 'other' },
    ])
  })
  it('has plain words for the known statuses', () => {
    expect(statusWords('needs-auth')).toBe('needs sign-in')
    expect(statusWords('failed')).toBe('could not connect')
    expect(statusWords('pending')).toBe('still connecting')
    expect(statusWords('disabled')).toBe('turned off')
    expect(statusWords('odd')).toBe('odd')
  })
})

describe('shownTools', () => {
  it('lists the tools of the server and ticks the chosen ones', () => {
    const rows = shownTools(INVENTORY, { server: 'board', tools: ['mcp__board__get_item'] })
    expect(rows.map(r => [r.name, r.on])).toEqual([
      ['mcp__board__list_items', false],
      ['mcp__board__update_item', false],
      ['mcp__board__get_item', true],
    ])
  })
  it('lists the saved tools when there is no inventory', () => {
    const rows = shownTools(null, { server: 'board', tools: ['mcp__board__get_item'] })
    expect(rows).toEqual([{ name: 'mcp__board__get_item', on: true, proposed: true, write: false }])
  })
  it('never shows a write tool as ticked, also when the saved list has it', () => {
    const source = { server: 'board', tools: ['mcp__board__update_item', 'mcp__board__setThing'] }
    expect(shownTools(INVENTORY, source).map(r => [r.name, r.on, r.write])).toEqual([
      ['mcp__board__list_items', false, false],
      ['mcp__board__update_item', false, true],
      ['mcp__board__get_item', false, false],
      ['mcp__board__setThing', false, true],
    ])
  })
})

describe('toolNote', () => {
  it('marks each tool that Bifrost does not propose', () => {
    expect(toolNote({ name: 'a', proposed: true, write: false })).toBeNull()
    expect(toolNote({ name: 'a', proposed: false, write: false })).toBe('May change things')
    expect(toolNote({ name: 'a', proposed: false, write: true })).toBe(
      'Bifrost never lets the run use this tool',
    )
  })
})

describe('toggleTool and toggleDay', () => {
  it('adds and removes a tool', () => {
    expect(toggleTool(['a'], 'b', true)).toEqual(['a', 'b'])
    expect(toggleTool(['a', 'b'], 'a', false)).toEqual(['b'])
  })
  it('adds and removes a day, in order', () => {
    expect(toggleDay([1, 3], 2)).toEqual([1, 2, 3])
    expect(toggleDay([1, 2, 3], 2)).toEqual([1, 3])
  })
  it('shows the days from Monday to Sunday', () => {
    expect(dayChoices().map(d => [d.label, d.day])).toEqual([
      ['Mon', 1],
      ['Tue', 2],
      ['Wed', 3],
      ['Thu', 4],
      ['Fri', 5],
      ['Sat', 6],
      ['Sun', 0],
    ])
  })
})

describe('DAILY_ROWS', () => {
  it('has the labels of the brief', () => {
    expect(DAILY_ROWS).toEqual({
      areas: 'Work areas',
      days: 'Days',
      deadline: 'Deadline',
      draftTime: 'Draft and first reminder',
      examples: 'Examples of your updates',
      format: 'Format',
      mergedPrs: 'Use merged PRs',
      model: 'Model',
      source: 'Ticket source',
      tools: 'Tools the run can use',
      you: 'You on the board',
    })
  })
})

describe('the work area rules on the page', () => {
  it('keeps one takes-all area across saved areas and new ones', () => {
    const saved = [area('a', true)]
    const drafts = [area('b', false), area('c', true)]
    const all = setTakesRest([...saved, ...drafts], 'b')
    expect(all.map(a => a.takesRest)).toEqual([false, true, false])
  })
  it('allows an area only below 10', () => {
    expect(canAddArea(9)).toBe(true)
    expect(canAddArea(10)).toBe(false)
  })
})
