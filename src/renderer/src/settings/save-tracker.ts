// The saves that the Save button of the Settings panel waits for (spec 12).
// Each change of Settings still saves at once. The tracker follows these saves, so that Save can
// wait for the saves that run and keep Settings open after a failure.

// Save a draft that saves only on demand, for example a new slash command that the user typed.
// null means that the draft has nothing to save.
export type DraftSave = () => Promise<boolean> | null

export class SaveTracker {
  private readonly pending = new Set<Promise<boolean>>()
  private readonly drafts = new Set<DraftSave>()
  // True after a save failed. A settle or a reset forgets it.
  private failed = false

  // Follow one save. A save that resolves false or rejects is a failure.
  track(save: Promise<boolean>): void {
    const entry = save.then(
      ok => {
        if (!ok) this.failed = true
        return ok
      },
      () => {
        this.failed = true
        return false
      },
    )
    this.pending.add(entry)
    void entry.then(() => this.pending.delete(entry))
  }

  // Add a draft that the next settle saves. The result removes the draft.
  addDraft(save: DraftSave): () => void {
    this.drafts.add(save)
    return () => {
      this.drafts.delete(save)
    }
  }

  // Forget the failures that ended. A save that still runs can still fail.
  reset(): void {
    this.failed = false
  }

  // Save each draft, then wait for all saves, also for a save that starts during the wait.
  // The result is true when no save failed since the last settle or reset.
  async settle(): Promise<boolean> {
    for (const save of this.drafts) {
      const running = save()
      if (running !== null) this.track(running)
    }
    while (this.pending.size > 0) await Promise.all(this.pending)
    const ok = !this.failed
    this.failed = false
    return ok
  }
}
