// The text format of the release notes. Only **bold** and `code` have a format. Each other
// character shows as plain text. The view gives each part to React as text, so no part is ever
// HTML.

export interface InlinePart {
  kind: 'text' | 'bold' | 'code'
  text: string
}

// The pair of markers at index, or null. The content of a pair is not empty.
function pairAt(text: string, index: number): { part: InlinePart; end: number } | null {
  const marker = text.startsWith('**', index) ? '**' : text[index] === '`' ? '`' : null
  if (marker === null) return null
  const start = index + marker.length
  const close = text.indexOf(marker, start)
  if (close <= start) return null
  const kind = marker === '`' ? 'code' : 'bold'
  return { end: close + marker.length, part: { kind, text: text.slice(start, close) } }
}

// The parts of a text, in order. A marker with no end stays as text.
export function inlineParts(text: string): InlinePart[] {
  const parts: InlinePart[] = []
  let plain = ''
  let index = 0
  while (index < text.length) {
    const pair = pairAt(text, index)
    if (pair === null) {
      // Skip a full "**" or "``", so its second character cannot start a pair.
      const step = text.startsWith('**', index) || text.startsWith('``', index) ? 2 : 1
      plain += text.slice(index, index + step)
      index += step
      continue
    }
    if (plain !== '') parts.push({ kind: 'text', text: plain })
    plain = ''
    parts.push(pair.part)
    index = pair.end
  }
  if (plain !== '') parts.push({ kind: 'text', text: plain })
  return parts
}
