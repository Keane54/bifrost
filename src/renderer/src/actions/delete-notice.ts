// The notices of the actions while a Delete runs. A Delete can take some minutes (Task 17). While
// one runs, its notice stays. A new notice does not replace it. The last new notice shows after
// the last Delete ends (Task 18 fix round 1, M5).

// The notice line: show gives an ID, and hide removes the text only when it is still the text of
// that ID.
export interface NoticeLine {
  show(text: string, opts?: { untilHidden?: boolean }): number
  hide(id: number): void
}

export interface DeleteNotices {
  // Show a notice for the normal time. While a Delete runs, the notice waits.
  notify(text: string): void
  // Show a notice until hide. While a Delete runs, it does not show, and the result is null.
  showUntilHidden(text: string): number | null
  // Remove a notice of showUntilHidden. null does nothing.
  hide(id: number | null): void
  // Call startDelete when a Delete starts to run, and endDelete when it ends.
  startDelete(): void
  endDelete(): void
}

export function createDeleteNotices(line: NoticeLine, deletingText: string): DeleteNotices {
  // The count of the Deletes that run.
  let deletes = 0
  // The ID of the Delete notice.
  let deletingId = 0
  // The last notice that came while a Delete ran.
  let waiting: string | null = null

  return {
    endDelete() {
      if (deletes === 0) return
      deletes -= 1
      if (deletes > 0) return
      line.hide(deletingId)
      const text = waiting
      waiting = null
      if (text !== null) line.show(text)
    },
    hide(id) {
      if (id !== null) line.hide(id)
    },
    notify(text) {
      if (deletes > 0) waiting = text
      else line.show(text)
    },
    showUntilHidden(text) {
      if (deletes > 0) return null
      return line.show(text, { untilHidden: true })
    },
    startDelete() {
      deletes += 1
      deletingId = line.show(deletingText, { untilHidden: true })
    },
  }
}
