import { beforeEach, describe, expect, it } from 'vitest'
import {
  createDeleteNotices,
  type DeleteNotices,
} from '../../../src/renderer/src/actions/delete-notice'

const DELETING = 'Deleting the session...'

// A notice line with the rules of useTimedMessage: a new text replaces the last one, and hide
// removes the text only when it is still the text of that ID.
class Line {
  text: string | null = null
  untilHidden = false
  private id = 0
  show = (text: string, opts: { untilHidden?: boolean } = {}): number => {
    this.id += 1
    this.text = text
    this.untilHidden = opts.untilHidden === true
    return this.id
  }
  hide = (id: number): void => {
    if (id === this.id) this.text = null
  }
}

let line: Line
let notices: DeleteNotices

beforeEach(() => {
  line = new Line()
  notices = createDeleteNotices(line, DELETING)
})

describe('the notices while a Delete runs (Task 18 M5)', () => {
  it('shows a notice at once when no Delete runs', () => {
    notices.notify('Resumed 1 session.')
    expect(line.text).toBe('Resumed 1 session.')
    expect(line.untilHidden).toBe(false)
  })

  it('keeps the Delete notice until the Delete ends', () => {
    notices.startDelete()
    expect(line.text).toBe(DELETING)
    expect(line.untilHidden).toBe(true)
    notices.endDelete()
    expect(line.text).toBeNull()
  })

  it('shows another notice only after the Delete ends', () => {
    notices.startDelete()
    notices.notify('Another dialog is open. Finish that one first.')
    expect(line.text).toBe(DELETING)
    notices.notify('Resumed 2 sessions.')
    expect(line.text).toBe(DELETING)
    notices.endDelete()
    // The last notice shows, for the normal time.
    expect(line.text).toBe('Resumed 2 sessions.')
    expect(line.untilHidden).toBe(false)
  })

  it('keeps the Delete notice until the last of two Deletes ends', () => {
    notices.startDelete()
    notices.startDelete()
    notices.notify('Resumed 1 session.')
    notices.endDelete()
    expect(line.text).toBe(DELETING)
    notices.endDelete()
    expect(line.text).toBe('Resumed 1 session.')
  })

  it('shows a notice until hide only when no Delete runs', () => {
    const checking = notices.showUntilHidden('Checking for unmerged work...')
    expect(line.text).toBe('Checking for unmerged work...')
    notices.hide(checking)
    expect(line.text).toBeNull()
    notices.startDelete()
    const hidden = notices.showUntilHidden('Checking for unmerged work...')
    expect(hidden).toBeNull()
    expect(line.text).toBe(DELETING)
    notices.hide(hidden)
    expect(line.text).toBe(DELETING)
    // A notice until hide does not wait. It does not show after the Delete either.
    notices.endDelete()
    expect(line.text).toBeNull()
  })

  it('a Delete that starts during a check replaces the check notice', () => {
    const checking = notices.showUntilHidden('Checking for unmerged work...')
    notices.startDelete()
    notices.hide(checking)
    expect(line.text).toBe(DELETING)
  })

  it('an extra end does nothing', () => {
    notices.endDelete()
    notices.notify('Resumed 1 session.')
    expect(line.text).toBe('Resumed 1 session.')
    // The count stays at 0. So the next Delete still keeps its notice until it ends.
    notices.startDelete()
    notices.notify('Resumed 2 sessions.')
    expect(line.text).toBe(DELETING)
    notices.endDelete()
    expect(line.text).toBe('Resumed 2 sessions.')
  })
})
