// The texts of the status icon in the name line of the Selected Item panel (spec 8.4).

export interface StatusTexts {
  // The lines in order: the error, the notice, then the send box line.
  lines: string[]
  // The error kind shows when an actions error or a failed send exists.
  kind: 'error' | 'info' | null
}

export function statusTexts(input: {
  error: string | null
  notice: string | null
  sendLine: string | null
  sendFailed: boolean
}): StatusTexts {
  const lines = [input.error, input.notice, input.sendLine].filter(
    (text): text is string => text !== null && text !== '',
  )
  if (lines.length === 0) return { kind: null, lines }
  const failed = input.sendFailed && input.sendLine !== null && input.sendLine !== ''
  const hasError = (input.error !== null && input.error !== '') || failed
  return { kind: hasError ? 'error' : 'info', lines }
}
