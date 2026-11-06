import { readFileSync } from 'node:fs'
import { join } from 'node:path'
import { describe, expect, it } from 'vitest'

// The repository has no DOM test. So this test reads the source text of the panel.
const PANEL = readFileSync(
  join(__dirname, '../../src/renderer/src/panels/SelectedItemPanel.tsx'),
  'utf8',
)

describe('SelectedItemPanel source', () => {
  it('shows no dash for a missing priority', () => {
    expect(PANEL).not.toContain("priority ?? '-'")
  })

  it('uses the three context bar fill classes', () => {
    for (const cls of ['bg-ctx-low', 'bg-ctx-mid', 'bg-ctx-high']) expect(PANEL).toContain(cls)
  })
})

describe('SelectedItemPanel name tooltip', () => {
  it('gives the name a title from aliasTip', () => {
    expect(PANEL).toContain('title={aliasTip(row)}')
  })
})

// The send of the send box and of Run slash command (ruling of 2026-11-06).
const ACTIONS = readFileSync(
  join(__dirname, '../../src/renderer/src/actions/actions-context.tsx'),
  'utf8',
)

describe('ActionsProvider send source', () => {
  it('clears the local name when afterSend says so', () => {
    expect(ACTIONS).toContain('const after = afterSend(text)')
    expect(ACTIONS).toContain(
      'if (after.clearAlias) window.bifrost.registry.setAlias(sessionId, null)',
    )
  })
})

describe('ActionsProvider Take control source (spec 6.1, 9.2)', () => {
  it('keys the loader and the chat window by the row ID, which a /clear does not change', () => {
    expect(ACTIONS).toContain('const sessionId = row.sessionId')
    expect(ACTIONS).toContain('chats.startLoader(sessionId)')
    expect(ACTIONS).toContain("dispatch({ panelId: chatPanelId(sessionId), type: 'open' })")
    expect(ACTIONS).toContain('chats.finishLoader(sessionId)')
    // The result of Take control is the same row ID, so the provider does not use it.
    expect(ACTIONS).not.toContain('resultId')
  })
})
