// The repository has no DOM test. So this test reads the source text of the renderer.
import { readFileSync } from 'node:fs'
import { join } from 'node:path'
import { describe, expect, it } from 'vitest'

const SRC = join(__dirname, '../../../src/renderer/src')
const CONTEXT = readFileSync(join(SRC, 'actions/actions-context.tsx'), 'utf8')
const BUTTON = readFileSync(join(SRC, 'actions/ActionButton.tsx'), 'utf8')

describe('hand over in the actions provider', () => {
  it('calls handOver, replaces the chat panel, selects, then stops the old session', () => {
    const call = CONTEXT.indexOf('api.sessions.handOver(sessionId)')
    const replace = CONTEXT.indexOf("type: 'replace'")
    const select = CONTEXT.indexOf('select(result.sessionId)')
    const stop = CONTEXT.indexOf('api.sessions.stop(sessionId)', select)
    expect(call).toBeGreaterThan(-1)
    expect(replace).toBeGreaterThan(call)
    expect(select).toBeGreaterThan(replace)
    expect(stop).toBeGreaterThan(select)
    expect(CONTEXT).toContain('panelId: chatPanelId(sessionId)')
    expect(CONTEXT).toContain('withId: chatPanelId(result.sessionId)')
  })

  it('uses the verbatim notices', () => {
    expect(CONTEXT).toContain("'Writing the hand-over note...'")
    expect(CONTEXT).toMatch(/Handed over to \$\{result\.name\}\./)
    expect(CONTEXT).toMatch(/The new session started, but Bifrost couldn't park the old one\./)
  })

  it('contextOf uses folderSharer and needs a short ID', () => {
    expect(CONTEXT).toContain('folderSharer(')
    expect(CONTEXT).toContain('row?.shortId !== undefined')
  })
})

describe('hand over in the action button', () => {
  it('maps hand-over to ArrowRightLeft and holds the warning colour', () => {
    expect(BUTTON).toContain("'hand-over': ArrowRightLeft")
    expect(BUTTON).toContain('text-ctx-mid')
    expect(BUTTON).toContain('handOverWarning(')
  })
})
