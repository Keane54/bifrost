// The parts of a draft for the panel. The draft text comes from a Claude run, so the panel makes
// React elements from these parts and never uses the text as HTML.

export interface DraftPart {
  bold: boolean
  text: string
}

// A bold part is **text** on one line, with one or more characters between the pairs.
const BOLD = /\*\*(.+?)\*\*/g

function lineParts(line: string): DraftPart[] {
  const parts: DraftPart[] = []
  let from = 0
  for (const match of line.matchAll(BOLD)) {
    if (match.index > from) parts.push({ bold: false, text: line.slice(from, match.index) })
    parts.push({ bold: true, text: match[1] ?? '' })
    from = match.index + match[0].length
  }
  if (from < line.length) parts.push({ bold: false, text: line.slice(from) })
  return parts
}

// Give one array of parts for each line. An empty line gives an empty array. All text that is
// not in a bold pair, also a single *, is plain text.
export function draftParts(draft: string): DraftPart[][] {
  return draft.split(/\r?\n/).map(lineParts)
}
