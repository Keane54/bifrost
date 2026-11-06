import { describe, expect, it } from 'vitest'
import { groupTitle, slotLabel } from '../../../src/renderer/src/keys/key-labels'
import { KEY_SLOTS, slotById } from '../../../src/shared/keys'

function label(id: string, labels: 'plain' | 'space'): string {
  const slot = slotById(id)
  if (!slot) throw new Error(`no slot ${id}`)
  return slotLabel(slot, labels)
}

describe('slotLabel', () => {
  it('gives the action label and the argument', () => {
    expect(label('set-priority.3:mod', 'plain')).toBe('Set priority 3')
    expect(label('set-priority.3:mod', 'space')).toBe('Set threat level 3')
    expect(label('set-priority.0:key', 'plain')).toBe('Clear the priority')
    expect(label('open-project:mod', 'plain')).toBe('Open project in the default app')
    expect(label('open-project:mod', 'space')).toBe('Open cargo hold in the default app')
    expect(label('select-row.4:mod', 'plain')).toBe('Select row 4')
    expect(label('load-layout.2:mod', 'plain')).toBe('Load layout 2')
    expect(label('escape:key', 'plain')).toBe('Clear the selection, or leave the send box')
  })

  it('has no trailing dots', () => {
    expect(label('send-message:mod', 'plain')).toBe('Send message')
    expect(label('stop:key', 'plain')).toBe('Stop session')
  })

  it('each slot has a label', () => {
    for (const slot of KEY_SLOTS) {
      expect(slotLabel(slot, 'plain'), slot.id).not.toBe('')
      expect(slotLabel(slot, 'space'), slot.id).not.toBe('')
      expect(slotLabel(slot, 'plain'), slot.id).not.toMatch(/\.\.\.$/)
    }
  })
})

describe('groupTitle', () => {
  it('gives the title of each group', () => {
    expect(groupTitle('always')).toBe('Shortcuts that work at all times')
    expect(groupTitle('single')).toBe('Single keys (not in a chat window or a text box)')
    expect(groupTitle('hold')).toBe('Hold a key and click a row')
  })
})
