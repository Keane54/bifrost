// The text of a field with a draft to save (Settings > General). The text is trimmed, so the
// saved value and the field have no spaces at the start or the end.
// Null means that the trimmed text is the saved value. Then the field shows the saved value again.
export function draftToSave(draft: string, saved: string): string | null {
  const text = draft.trim()
  return text === saved ? null : text
}
