// True for a whole number of columns or rows that a PTY accepts.
// A 5K screen with a small font can pass 500 columns.
export function isTerminalSize(value: unknown): value is number {
  return typeof value === 'number' && Number.isInteger(value) && value >= 1 && value <= 1000
}

export const REFUSED_BAD_SIZE = 'refused: bad terminal size'
