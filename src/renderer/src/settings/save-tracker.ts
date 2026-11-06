// The saves that the Save button of the Settings panel waits for (spec 12).
// Each change of Settings still saves at once. The tracker follows these saves, so that Save can
// wait for the saves that run and keep Settings open while a row has a failed save.

// Save a draft that saves only on demand, for example a new slash command that the user typed.
// null means that the draft has nothing to save.
export type DraftSave = () => Promise<boolean> | null

// The tracker keeps the state of each row (review Important 1). A row is any object that stays
// the same for the row. The last save that a row started gives the state of the row. A failed row
// stays failed until a good save of the row, a close of its error (forget) or its unmount (remove).
export class SaveTracker {
  private readonly pending = new Set<Promise<void>>()
  private readonly drafts = new Set<DraftSave>()
  private readonly failed = new Set<object>()
  // The number of the last save that each row started.
  private readonly latest = new Map<object, number>()
  private count = 0

  // Follow one save of a row. A save that resolves false or rejects is a failure.
  track(row: object, save: Promise<boolean>): void {
    this.count += 1
    const n = this.count
    this.latest.set(row, n)
    const entry = save
      .then(
        ok => ok,
        () => false,
      )
      .then(ok => {
        // A later save of the row, or a remove, replaces this result.
        if (this.latest.get(row) !== n) return
        if (ok) this.failed.delete(row)
        else this.failed.add(row)
      })
    this.pending.add(entry)
    void entry.then(() => this.pending.delete(entry))
  }

  // The user closed the error of the row. A save of the row that still runs still counts.
  forget(row: object): void {
    this.failed.delete(row)
  }

  // The row unmounted. Its failure goes away, and the saves of the row that still run do not
  // count, because nothing can show or close their error.
  remove(row: object): void {
    this.failed.delete(row)
    this.latest.delete(row)
  }

  // Add a draft that each settle saves. The result removes the draft.
  addDraft(save: DraftSave): () => void {
    this.drafts.add(save)
    return () => {
      this.drafts.delete(save)
      this.remove(save)
    }
  }

  // Save each draft, then wait for all saves, also for a save that starts during the wait.
  // The result is true when no row has a failed save. A draft with nothing to save has no state.
  async settle(): Promise<boolean> {
    for (const save of this.drafts) {
      const running = save()
      if (running === null) this.remove(save)
      else this.track(save, running)
    }
    while (this.pending.size > 0) await Promise.all(this.pending)
    return this.failed.size === 0
  }
}
