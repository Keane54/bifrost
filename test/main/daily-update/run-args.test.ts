import { describe, expect, it } from 'vitest'
import type { McpInventory } from '../../../src/main/daily-update/mcp-inventory'
import { allowedNow, denyList, runArgs } from '../../../src/main/daily-update/run-args'

const inv: McpInventory = {
  servers: [
    {
      name: 'board',
      prefix: 'mcp__board__',
      status: 'connected',
      tools: ['mcp__board__a_list', 'mcp__board__a_update'],
    },
    { name: 'other', prefix: 'mcp__other__', status: 'connected', tools: ['mcp__other__x_list'] },
    {
      name: 'team.example Board',
      prefix: 'mcp__team_example_Board__',
      status: 'connected',
      tools: ['mcp__team_example_Board__read'],
    },
  ],
}

const base = {
  allowed: ['mcp__board__a_list'],
  deny: ['mcp__board__a_update'],
  ioDir: '/real/io',
  model: '' as const,
  pluginDir: '/real/plugin',
  prompt: 'PROMPT',
}

describe('allowedNow and denyList', () => {
  it('allow no tool of another server', () => {
    const chosen = ['mcp__board__a_list', 'mcp__other__x_list', 'mcp__board__gone']
    const allowed = allowedNow(inv, 'board', chosen)
    expect(allowed).toEqual(['mcp__board__a_list'])
    expect(denyList(inv, 'board', allowed)).toEqual([
      'mcp__board__a_update',
      'mcp__other',
      'mcp__team_example_Board',
    ])
  })

  it('give nothing allowed and every server denied with no server', () => {
    expect(allowedNow(inv, 'missing', ['mcp__board__a_list'])).toEqual([])
    expect(allowedNow(inv, null, ['mcp__board__a_list'])).toEqual([])
    expect(denyList(inv, null, [])).toEqual(['mcp__board', 'mcp__other', 'mcp__team_example_Board'])
  })

  it('put a ticked write tool in the deny list and not in the allowed list', () => {
    const camel: McpInventory = {
      servers: [
        {
          name: 'board',
          prefix: 'mcp__board__',
          status: 'connected',
          tools: ['mcp__board__getIssue', 'mcp__board__updateIssue', 'mcp__board__close-issue'],
        },
      ],
    }
    const chosen = ['mcp__board__getIssue', 'mcp__board__updateIssue', 'mcp__board__close-issue']
    const allowed = allowedNow(camel, 'board', chosen)
    expect(allowed).toEqual(['mcp__board__getIssue'])
    expect(denyList(camel, 'board', allowed)).toEqual([
      'mcp__board__updateIssue',
      'mcp__board__close-issue',
    ])
    // A caller that gives a write tool as allowed still gets it in the deny list.
    expect(denyList(camel, 'board', chosen)).toEqual([
      'mcp__board__updateIssue',
      'mcp__board__close-issue',
    ])
  })
})

describe('runArgs', () => {
  it('uses the exact order', () => {
    expect(runArgs(base)).toEqual([
      '-p',
      '--output-format',
      'json',
      '--tools',
      'Read,Skill',
      '--permission-mode',
      'dontAsk',
      '--plugin-dir',
      '/real/plugin',
      '--add-dir',
      '/real/io',
      '--allowedTools',
      'mcp__board__a_list',
      'Skill',
      'Read(//real/io/**)',
      'Read(//real/plugin/**)',
      '--disallowedTools',
      'mcp__board__a_update',
      '--settings',
      '{"disableAllHooks":true}',
      'PROMPT',
    ])
  })

  it('puts the prompt last and no list flag right before it', () => {
    const a = runArgs({ ...base, deny: [], model: 'opus' })
    expect(a.at(-1)).toBe('PROMPT')
    expect(a.at(-3)).toBe('--model')
    expect(a).not.toContain('--disallowedTools')
  })

  it('keeps the exact order with a model and a deny list', () => {
    const a = runArgs({ ...base, model: 'opus' })
    expect(a.slice(-7)).toEqual([
      '--disallowedTools',
      'mcp__board__a_update',
      '--settings',
      '{"disableAllHooks":true}',
      '--model',
      'opus',
      'PROMPT',
    ])
  })

  it('leaves out --model for the default model', () => {
    expect(runArgs(base)).not.toContain('--model')
    const a = runArgs({ ...base, model: 'haiku' })
    expect(a[a.indexOf('--model') + 1]).toBe('haiku')
  })

  it('uses the double-slash form for the path rules', () => {
    const rules = runArgs(base).filter(x => x.includes('(//'))
    expect(rules).toEqual(['Read(//real/io/**)', 'Read(//real/plugin/**)'])
  })
})
