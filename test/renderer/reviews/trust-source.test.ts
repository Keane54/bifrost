import { readFileSync } from 'node:fs'
import { join } from 'node:path'
import { describe, expect, it } from 'vitest'
import { waitingText } from '../../../src/renderer/src/reviews/trust-text'

// The repository has no DOM test. So this test reads the source text of the components.
const dir = join(__dirname, '../../../src/renderer/src/reviews')
const STRIP = readFileSync(join(dir, 'TrustStrip.tsx'), 'utf8')
const TRUST_PANEL = readFileSync(join(dir, 'TrustPanel.tsx'), 'utf8')
const REVIEWS = readFileSync(join(dir, 'ReviewsPanel.tsx'), 'utf8')

describe('waitingText', () => {
  it('uses the singular and the plural form', () => {
    expect(waitingText(1)).toBe('1 pull request waiting')
    expect(waitingText(2)).toBe('2 pull requests waiting')
    expect(waitingText(0)).toBe('0 pull requests waiting')
  })
})

describe('TrustStrip source', () => {
  it('calls reviews.trust and opens the trust panel', () => {
    expect(STRIP).toContain('reviews.trust(')
    expect(STRIP).toMatch(
      /panelId: 'trust'[\s\S]{0,40}type: 'open'|type: 'open'[\s\S]{0,40}'trust'/,
    )
  })

  it('keeps the repository in the store and shows the texts', () => {
    expect(STRIP).toContain('setTrustRepo(')
    expect(STRIP).toContain('Trust needed')
    expect(STRIP).toContain('waitingText(')
    expect(STRIP).toContain(
      "Opens Claude Code in Bifrost's copy of this repository, so you can accept the trust prompt.",
    )
  })

  it('shows on the panel above the tab body', () => {
    expect(REVIEWS).toContain('<TrustStrip')
  })
})

describe('TrustPanel source', () => {
  it('subscribes to the data and the end and closes the trust window', () => {
    expect(TRUST_PANEL).toContain('onTrustData(')
    expect(TRUST_PANEL).toContain('onTrustEnd(')
    expect(TRUST_PANEL).toContain('trustClose()')
    expect(TRUST_PANEL).toContain('trustWrite(')
    expect(TRUST_PANEL).toContain('trustResize(')
  })

  it('marks the terminal and uses no WebGL', () => {
    expect(TRUST_PANEL).toContain('data-trust-terminal')
    expect(TRUST_PANEL).not.toMatch(/webgl/i)
  })

  it('shows the texts, and retries with reviews.trust', () => {
    expect(TRUST_PANEL.replace(/\s+/g, ' ')).toContain(
      "Claude Code asks if you trust this folder. Accept it below. Bifrost then closes this window and starts any review that's waiting.",
    )
    expect(TRUST_PANEL).toContain('Claude Code closed before the folder was trusted.')
    expect(TRUST_PANEL).toContain('Try again')
    expect(TRUST_PANEL).toContain('reviews.trust(')
  })

  it('closes the panel on a trusted end', () => {
    expect(TRUST_PANEL).toMatch(/trusted[\s\S]{0,200}type: 'close'/)
  })
})
